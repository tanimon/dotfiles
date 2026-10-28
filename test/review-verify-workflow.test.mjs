// review-verify.js を、agent() などの Workflow のフックを stub にして実行し、
// ループの判定と報告の組み立てを決定的に検証する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SCRIPT = readFileSync(
  fileURLToPath(new URL("../dot_claude/workflows/review-verify.js", import.meta.url)),
  "utf8",
);
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;

// 1 周のレビューで呼ばれるレビュアーのラベル(REVIEWERS の並び順)。
const REVIEW_LABELS = [
  "review:mattpocock-standards",
  "review:mattpocock-spec",
  "review:ecc",
  "review:silent-failure",
];

const BASE_ARGS = {
  requirementsPath: "/repo/docs/plans/p.md",
  baseRef: "origin/main",
  checkCommands: ["just lint"],
  verifySkill: "web-verify",
};

const finding = (severity, extra = {}) => ({
  file: "a.js",
  line: 1,
  summary: "bug",
  severity,
  target: "code",
  ...extra,
});

const cluster = (key, members, extra = {}) => ({
  key,
  file: "a.js",
  line: 1,
  summary: `issue ${key}`,
  target: "code",
  requirementsBreaking: false,
  members,
  ...extra,
});

// reviews[i] / merges[i] は i 番目のレビューラウンド、fixes[i] は i 番目の修正ラウンドへの応答。
function scenario({
  checks = () => ({ passed: true, details: "" }),
  reviews = [],
  merges = [],
  fixes = [],
  verdicts = {},
  verifies = [{ passed: true, summary: "ok" }],
  fixVerify = () => ({ fixed: true, summary: "fixed", changes: [], observations: [] }),
  skillMissing = [],
} = {}) {
  let mergeIndex = 0;
  let fixIndex = 0;
  let verifyIndex = 0;
  return (label, calls) => {
    if (label.startsWith("checks:")) return checks(Number(label.split(":")[1]));
    if (label.startsWith("review:")) {
      const id = label.split(":")[1];
      // 各周回は checks:N から始まるので、レビュアーの並び順に依らずに周回を数えられる。
      const round = calls.filter((c) => c.label.startsWith("checks:")).length - 1;
      const result = reviews[round]?.[id];
      if (result === null) return null;
      return { findings: result ?? [], observations: [], skillLoaded: !skillMissing.includes(id) };
    }
    if (label === "merge") return { clusters: merges[mergeIndex++] ?? [] };
    if (label.startsWith("fix:")) return fixes[fixIndex++];
    if (label.startsWith("defer-verify:")) return verdicts[label.slice("defer-verify:".length)];
    if (label.startsWith("verify:")) {
      const v = verifies[Math.min(verifyIndex, verifies.length - 1)];
      verifyIndex++;
      return v;
    }
    if (label.startsWith("fix-verify:")) return fixVerify(Number(label.split(":")[1]));
    throw new Error(`unexpected agent label: ${label}`);
  };
}

async function runWorkflow({
  args = {},
  respond = scenario(),
  budget = { total: null, spent: () => 1234, remaining: () => Infinity },
} = {}) {
  const calls = [];
  const agent = async (prompt, opts = {}) => {
    calls.push({ label: opts.label, prompt, opts });
    return respond(opts.label, calls);
  };
  const parallel = (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)));
  const pipeline = async () => {
    throw new Error("review-verify does not use pipeline()");
  };
  const body = SCRIPT.replace(/^export const meta/m, "const meta");
  const run = new AsyncFunction(
    "agent",
    "parallel",
    "pipeline",
    "phase",
    "log",
    "args",
    "budget",
    body,
  );
  const result = await run(
    agent,
    parallel,
    pipeline,
    () => {},
    () => {},
    { ...BASE_ARGS, ...args },
    budget,
  );
  return { result, labels: calls.map((c) => c.label), calls };
}

function section(report, title) {
  const start = report.indexOf(`## ${title}\n`);
  assert.notEqual(start, -1, `section "${title}" is missing`);
  const rest = report.slice(start + title.length + 4);
  const end = rest.indexOf("\n## ");
  return end === -1 ? rest : rest.slice(0, end);
}

test("指摘ゼロなら修正せずに動作確認まで進み、push も PR の作成もしない(ADR 0022)", async () => {
  const { result, labels } = await runWorkflow();
  assert.deepEqual(labels, ["checks:1", ...REVIEW_LABELS, "verify:1"]);
  assert.equal(result.stopReason, null);
  // 返り値は ledger / report / stats / stopReason だけで、公開の結果を含まない(ADR 0022)。
  assert.deepEqual(Object.keys(result).sort(), ["ledger", "report", "stats", "stopReason"]);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("修正必須の指摘を直したら再レビューし、ゼロになれば終える", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.equal(labels.filter((l) => l === "review:ecc").length, 2);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("修正必須が無くても参考指摘を修正に回し、その後に checks とレビューをもう1回通す", async () => {
  const { result, labels, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")], "mattpocock-standards": [finding("judgement")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0", "mattpocock-standards#0"])]],
      fixes: [
        {
          results: [{ key: "a.js::style", action: "fixed" }],
          changes: [{ file: "a.js", summary: "命名を直す" }],
          observations: [],
        },
      ],
    }),
  });
  assert.deepEqual(labels, [
    "checks:1",
    ...REVIEW_LABELS,
    "merge",
    "fix:1",
    "checks:2",
    ...REVIEW_LABELS,
    "verify:1",
  ]);
  assert.match(calls.find((c) => c.label === "fix:1").prompt, /a\.js::style/);
  assert.equal(result.stopReason, null);
  assert.match(
    section(result.report, "修正した指摘"),
    /\[参考\] `a\.js:1` issue a\.js::style \[ecc:MEDIUM, mattpocock-standards:judgement\]/,
  );
  assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
  assert.match(result.report, /参考 1\(修正に回した 1: 修正 1 \/ 見送り 0、報告のみ 0\)/);
  const ledger = JSON.parse(result.ledger);
  assert.deepEqual(ledger.advisoryClosedKeys, ["a.js::style"]);
  assert.deepEqual(ledger.fixChanges, [{ label: "fix:1", file: "a.js", summary: "命名を直す" }]);
});

test("ラウンド 2 以降に出た参考指摘は修正に回さず、修正必須が無ければ収束して報告に載せる(ADR 0016)", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("LOW", { summary: "naming" })] }],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::naming", ["ecc#0"])]],
      fixes: [
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.equal(labels.filter((l) => l === "review:ecc").length, 2);
  assert.equal(result.stopReason, null);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a\.js::naming/);
  assert.match(result.stats, /実行 1: 収束した\(ラウンド 1〜2\)/);
});

test("ラウンド 2 以降に修正必須と参考指摘が同時に出たら、修正には修正必須だけを回す(ADR 0016)", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [
        { ecc: [finding("MEDIUM")] },
        {
          ecc: [finding("HIGH", { summary: "regression" }), finding("LOW", { summary: "naming" })],
        },
        {},
      ],
      merges: [
        [cluster("a.js::style", ["ecc#0"])],
        [cluster("a.js::regression", ["ecc#0"]), cluster("a.js::naming", ["ecc#1"])],
      ],
      fixes: [
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
        { results: [{ key: "a.js::regression", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  const prompt = calls.filter((c) => c.label.startsWith("fix:"))[1].prompt;
  assert.match(prompt, /a\.js::regression/);
  assert.doesNotMatch(prompt, /a\.js::naming/);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a\.js::naming/);
  assert.match(
    result.stats,
    /ラウンド 2: 修正必須 1 .*参考 1\(修正に回した 0: 修正 0 \/ 見送り 0、報告のみ 1\)/,
  );
});

test("動作確認の失敗で再入した後のパスの最初のラウンドでも、参考指摘は修正に回さない(ADR 0016)", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{}, { ecc: [finding("MEDIUM")] }],
      merges: [[cluster("a.js::style", ["ecc#0"])]],
      verifies: [
        { passed: false, summary: "画面が崩れる" },
        { passed: true, summary: "ok" },
      ],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 0);
  assert.equal(result.stopReason, null);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a\.js::style/);
  assert.match(result.stats, /実行 2: 収束した\(ラウンド 2〜2\)/);
});

test("ラウンド 1 で結果の返らなかった参考指摘がラウンド 2 で再出現しても再送せず、「報告のみ」に数える(ADR 0016)", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("MEDIUM")] }],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::style", ["ecc#0"])]],
      fixes: [{ results: [], changes: [], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.equal(result.stopReason, null);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a\.js::style/);
  assert.match(
    result.stats,
    /ラウンド 2: .*参考 1\(修正に回した 0: 修正 0 \/ 見送り 0、報告のみ 1\)/,
  );
});

test("ラウンド 2 以降で上限に達したとき、未回答の参考指摘は「報告のみ」に数える", async () => {
  const { result } = await runWorkflow({
    args: { maxReviewRounds: 1 },
    respond: scenario({
      reviews: [
        { ecc: [finding("HIGH")] },
        {
          ecc: [finding("HIGH", { summary: "regression" }), finding("LOW", { summary: "naming" })],
        },
      ],
      merges: [
        [cluster("a.js::bug", ["ecc#0"])],
        [cluster("a.js::regression", ["ecc#0"]), cluster("a.js::naming", ["ecc#1"])],
      ],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed" }], changes: [], observations: [] }],
    }),
  });
  assert.match(result.stats, /実行 1: 修正ラウンドの上限に達した/);
  assert.match(section(result.report, "Unresolved Finding"), /issue a\.js::regression/);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a\.js::naming/);
  assert.match(
    result.stats,
    /ラウンド 2: 修正必須 1 .*参考 1\(修正に回した 0: 修正 0 \/ 見送り 0、報告のみ 1\)/,
  );
});

test("修正ラウンドの上限に達したら、残った参考指摘は Unresolved にせず参考指摘として報告する", async () => {
  const { result, labels } = await runWorkflow({
    args: { maxReviewRounds: 0 },
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }],
      merges: [[cluster("a.js::style", ["ecc#0"])]],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 0);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a\.js::style/);
  assert.equal(section(result.report, "Unresolved Finding").trim(), "なし");
  assert.equal(result.stopReason, null);
  assert.match(
    result.stats,
    /ラウンド 1: .*参考 1\(修正に回した 0: 修正 0 \/ 見送り 0、報告のみ 1\)/,
  );
});

for (const action of ["fixed", "propose-defer"]) {
  test(`${action} を返した参考指摘は閉じ、再出現しても修正に回さない(見送りに検証者を付けない)`, async () => {
    const { result, labels } = await runWorkflow({
      respond: scenario({
        reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("MEDIUM")] }],
        merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::style", ["ecc#0"])]],
        fixes: [
          {
            results: [{ key: "a.js::style", action, reason: "意図的な命名" }],
            changes: [],
            observations: [],
          },
        ],
      }),
    });
    assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
    assert.equal(labels.filter((l) => l === "review:ecc").length, 2);
    assert.equal(labels.filter((l) => l.startsWith("defer-verify:")).length, 0);
    assert.equal(section(result.report, "修正した指摘").trim(), "なし");
    assert.match(
      result.report,
      /ラウンド 2: .*参考 1\(修正に回した 0: 修正 0 \/ 見送り 0、報告のみ 0\)/,
    );
    if (action === "propose-defer") {
      assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
      assert.match(
        section(result.report, "見送った参考指摘"),
        /issue a\.js::style.*見送り理由: 意図的な命名/,
      );
    } else {
      // 直したと回答した後に再指摘されたので、直ったとは報告せず、参考指摘として残す。
      assert.match(
        section(result.report, "参考指摘(修正必須ではない)"),
        /issue a\.js::style.*直したと回答した後、再レビューで再指摘された/,
      );
      assert.equal(section(result.report, "見送った参考指摘").trim(), "なし");
    }
  });
}

test("参考指摘の修正の後に出た新しい修正必須指摘は、通常どおり修正に回す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [
        { ecc: [finding("MEDIUM")] },
        { ecc: [finding("HIGH", { summary: "regression" })] },
        {},
      ],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::regression", ["ecc#0"])]],
      fixes: [
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
        { results: [{ key: "a.js::regression", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /a\.js::regression/);
  assert.equal(section(result.report, "Unresolved Finding").trim(), "なし");
});

test("閉じた参考指摘の key が修正必須の重大度で出直したら、修正必須として扱う", async () => {
  const { calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::style", ["ecc#0"])]],
      fixes: [
        {
          results: [{ key: "a.js::style", action: "propose-defer", reason: "nit" }],
          changes: [],
          observations: [],
        },
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /a\.js::style/);
});

test("見送った参考指摘が修正必須で出直して直されたら、見送った参考指摘には出さず修正必須として修正した指摘に出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::style", ["ecc#0"])]],
      fixes: [
        {
          results: [{ key: "a.js::style", action: "propose-defer", reason: "nit" }],
          changes: [],
          observations: [],
        },
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  assert.equal(section(result.report, "見送った参考指摘").trim(), "なし");
  assert.match(section(result.report, "修正した指摘"), /issue a\.js::style \[ecc:HIGH\]/);
  assert.deepEqual(JSON.parse(result.ledger).advisoryEscalatedKeys, ["a.js::style"]);
});

test("直したと回答した参考指摘が修正必須で出直して見送られたら、修正した指摘には出さず Deferred にだけ出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::style", ["ecc#0"])]],
      fixes: [
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
        {
          results: [{ key: "a.js::style", action: "propose-defer", reason: "範囲外" }],
          changes: [],
          observations: [],
        },
      ],
      verdicts: { "a.js::style": { agree: true, reason: "plan のタスク外" } },
    }),
  });
  assert.match(section(result.report, "Deferred Finding"), /issue a\.js::style/);
  assert.equal(section(result.report, "修正した指摘").trim(), "なし");
  assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
  assert.deepEqual(JSON.parse(result.ledger).advisoryEscalatedKeys, ["a.js::style"]);
});

test("直したと回答した参考指摘が修正必須で出直して直し直されたら、修正必須として修正した指摘に出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::style", ["ecc#0"])]],
      fixes: [
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  const fixed = section(result.report, "修正した指摘");
  assert.match(fixed, /issue a\.js::style \[ecc:HIGH\]/);
  assert.doesNotMatch(fixed, /\[参考\]/);
  assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
});

test("対応結果の無い参考指摘は閉じず、参考指摘として報告に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0"])]],
      fixes: [{ results: [], changes: [], observations: [] }],
    }),
  });
  assert.equal(result.stopReason, null);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a\.js::style/);
  assert.deepEqual(JSON.parse(result.ledger).advisoryClosedKeys, []);
});

test("参考指摘だけの修正で修正エージェントが結果を返さなければ止め、再レビューされていない参考指摘として出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }],
      merges: [[cluster("a.js::style", ["ecc#0"])]],
      fixes: [null],
    }),
  });
  assert.equal(result.stopReason, "fixer-failed");
  assert.match(
    section(result.report, "修正に回した後、再レビューされていない参考指摘"),
    /issue a\.js::style/,
  );
  assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
});

test("修正必須と参考指摘は1回の修正にまとめ、見送りの検証者は修正必須にだけ付ける", async () => {
  const { result, labels, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH"), finding("MEDIUM", { summary: "style" })] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"]), cluster("a.js::style", ["ecc#1"])]],
      fixes: [
        {
          results: [
            { key: "a.js::bug", action: "propose-defer", reason: "偽陽性" },
            { key: "a.js::style", action: "propose-defer", reason: "nit" },
          ],
          changes: [],
          observations: [],
        },
      ],
      verdicts: { "a.js::bug": { agree: true, reason: "偽陽性" } },
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  const prompt = calls.find((c) => c.label === "fix:1").prompt;
  assert.match(prompt.slice(prompt.indexOf("参考指摘(JSON):")), /a\.js::style/);
  assert.deepEqual(
    labels.filter((l) => l.startsWith("defer-verify:")),
    ["defer-verify:a.js::bug"],
  );
  assert.match(
    section(result.report, "見送った参考指摘"),
    /issue a\.js::style .* — 見送り理由: nit/,
  );
});

test("同じ key が同じラウンドで修正必須と参考の両方に出たら、修正必須としてだけ扱う", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH"), finding("MEDIUM", { summary: "style" })] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"]), cluster("a.js::bug", ["ecc#1"])]],
      fixes: [
        {
          results: [{ key: "a.js::bug", action: "propose-defer", reason: "偽陽性" }],
          changes: [],
          observations: [],
        },
      ],
      verdicts: { "a.js::bug": { agree: true, reason: "偽陽性" } },
    }),
  });
  const prompt = calls.find((c) => c.label === "fix:1").prompt;
  assert.doesNotMatch(prompt.slice(prompt.indexOf("参考指摘(JSON):")), /a\.js::bug/);
  assert.equal(section(result.report, "見送った参考指摘").trim(), "なし");
  assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
  assert.match(section(result.report, "Deferred Finding"), /issue a\.js::bug/);
  assert.match(result.report, /ラウンド 1: 修正必須 1 .* 参考 0\(修正に回した 0:/);
});

test("参考指摘を修正に回した後、checks が落ちて止まったら、Unresolved にせず再レビューされていない参考指摘として出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      checks: (round) => ({ passed: round === 1, details: "lint error" }),
      reviews: [{ ecc: [finding("MEDIUM")] }],
      merges: [[cluster("a.js::style", ["ecc#0"])]],
      fixes: [
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  assert.equal(result.stopReason, "checks-failing");
  assert.equal(section(result.report, "Unresolved Finding").trim(), "なし");
  assert.match(
    section(result.report, "修正に回した後、再レビューされていない参考指摘"),
    /issue a\.js::style/,
  );
  assert.equal(section(result.report, "修正した指摘").trim(), "なし");
});

test("同じ key が2ラウンド続けて修正必須なら Unresolved にしてループを終える", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, { ecc: [finding("HIGH")] }],
      merges: [[cluster("a.js::bug", ["ecc#0"])], [cluster("a.js::bug", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.match(section(result.report, "Unresolved Finding"), /issue a.js::bug/);
});

test("Unresolved にした key がさらに後のラウンドで出ても二重計上せず、修正対象にも戻さない", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [
        { ecc: [finding("HIGH")] },
        { ecc: [finding("HIGH"), finding("CRITICAL", { summary: "other" })] },
        { ecc: [finding("HIGH")] },
      ],
      merges: [
        [cluster("a.js::bug", ["ecc#0"])],
        [cluster("a.js::bug", ["ecc#0"]), cluster("a.js::other", ["ecc#1"])],
        [cluster("a.js::bug", ["ecc#0"])],
      ],
      fixes: [
        { results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] },
        { results: [{ key: "a.js::other", action: "fixed", reason: "" }], observations: [] },
      ],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 2);
  const fixPrompts = labels.filter((l) => l.startsWith("fix:"));
  assert.deepEqual(fixPrompts, ["fix:1", "fix:2"]);
  const unresolved = section(result.report, "Unresolved Finding");
  assert.equal(unresolved.match(/issue a.js::bug/g).length, 1);
});

test("修正ラウンドが上限に達したら、残った修正必須指摘を Unresolved にする", async () => {
  const keys = ["k1", "k2", "k3", "k4"];
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: keys.map(() => ({ ecc: [finding("HIGH")] })),
      merges: keys.map((k) => [cluster(k, ["ecc#0"])]),
      fixes: keys.map((k) => ({
        results: [{ key: k, action: "fixed", reason: "" }],
        observations: [],
      })),
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 3);
  assert.equal(labels.filter((l) => l === "review:ecc").length, 4);
  assert.match(section(result.report, "Unresolved Finding"), /issue k4/);
});

test("maxReviewRounds で修正ラウンドの上限を変えられる", async () => {
  const { labels } = await runWorkflow({
    args: { maxReviewRounds: 1 },
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, { ecc: [finding("HIGH")] }],
      merges: [[cluster("k1", ["ecc#0"])], [cluster("k2", ["ecc#0"])]],
      fixes: [{ results: [{ key: "k1", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
});

test("検証者が同意した見送りは Deferred になり、再出現しても Unresolved にしない", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ "silent-failure": [finding("HIGH")] }, { "silent-failure": [finding("HIGH")] }],
      merges: [
        [cluster("a.js::scope", ["silent-failure#0"])],
        [cluster("a.js::scope", ["silent-failure#0"])],
      ],
      fixes: [
        {
          results: [{ key: "a.js::scope", action: "propose-defer", reason: "plan の範囲外" }],
          observations: [],
        },
      ],
      verdicts: { "a.js::scope": { agree: true, reason: "plan のタスク外" } },
    }),
  });
  assert.ok(labels.includes("defer-verify:a.js::scope"));
  assert.match(section(result.report, "Deferred Finding"), /plan の範囲外.*plan のタスク外/);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("検証者が同意しなかった見送りは、却下理由を添えてもう1回だけ修正に回す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, { ecc: [finding("HIGH")] }, { ecc: [finding("HIGH")] }],
      merges: [
        [cluster("a.js::bug", ["ecc#0"])],
        [cluster("a.js::bug", ["ecc#0"])],
        [cluster("a.js::bug", ["ecc#0"])],
      ],
      fixes: [
        {
          results: [{ key: "a.js::bug", action: "propose-defer", reason: "面倒" }],
          observations: [],
        },
        {
          results: [{ key: "a.js::bug", action: "propose-defer", reason: "やはり面倒" }],
          observations: [],
        },
      ],
      verdicts: { "a.js::bug": { agree: false, reason: "実バグ" } },
    }),
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /実バグ/);
  assert.match(section(result.report, "Deferred Finding"), /なし/);
  assert.match(section(result.report, "Unresolved Finding"), /issue a.js::bug/);
});

test("Requirements Concern は修正せずに報告し、requirementsBreaking なら動作確認をせずに停止する", async () => {
  const concern = await runWorkflow({
    respond: scenario({
      reviews: [{ "mattpocock-spec": [finding("hard", { target: "requirements" })] }],
      merges: [
        [cluster("requirements::ambiguous", ["mattpocock-spec#0"], { target: "requirements" })],
      ],
    }),
  });
  assert.equal(concern.labels.filter((l) => l.startsWith("fix:")).length, 0);
  assert.match(
    section(concern.result.report, "Requirements Concern"),
    /issue requirements::ambiguous/,
  );
  assert.equal(concern.result.stopReason, null);

  const breaking = await runWorkflow({
    respond: scenario({
      reviews: [
        { ecc: [finding("CRITICAL", { target: "requirements", requirementsBreaking: true })] },
      ],
      merges: [
        [
          cluster("requirements::broken", ["ecc#0"], {
            target: "requirements",
            requirementsBreaking: true,
          }),
        ],
      ],
    }),
  });
  assert.equal(breaking.result.stopReason, "requirements-breaking");
  assert.ok(!breaking.labels.some((l) => l.startsWith("verify:")));
});

test("動作確認の失敗が上限まで続いたら、失敗を報告の先頭に出す", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({ verifies: [{ passed: false, summary: "画面が真っ白" }] }),
  });
  assert.deepEqual(
    labels.filter((l) => l.startsWith("verify:")),
    ["verify:1", "verify:2", "verify:3"],
  );
  assert.equal(labels.filter((l) => l.startsWith("fix-verify:")).length, 2);
  assert.ok(result.report.indexOf("## 動作確認") < result.report.indexOf("## Unresolved Finding"));
  assert.match(section(result.report, "動作確認"), /画面が真っ白/);
});

test("verifySkill が none なら動作確認をせず、その旨を報告する", async () => {
  const { result, labels } = await runWorkflow({ args: { verifySkill: "none" } });
  assert.ok(!labels.some((l) => l.startsWith("verify:")));
  assert.match(section(result.report, "動作確認"), /指定なし/);
});

test("動作確認がコード外の原因で blocked なら、修正エージェントに回さずに停止して先頭に出す", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      verifies: [{ passed: false, blocked: true, summary: "保存場所が決まっていない" }],
    }),
  });
  assert.deepEqual(
    labels.filter((l) => l.startsWith("verify:")),
    ["verify:1"],
  );
  assert.ok(!labels.some((l) => l.startsWith("fix-verify:")));
  assert.equal(result.stopReason, "verify-blocked");
  assert.ok(result.report.indexOf("## 動作確認") < result.report.indexOf("## Unresolved Finding"));
  assert.match(section(result.report, "動作確認"), /検証できず — 保存場所が決まっていない/);
});

test("verifyArgs は動作確認の prompt に入り、統計には入らない", async () => {
  const { result, calls } = await runWorkflow({
    args: { verifyArgs: "検証資産の保存場所: <home>/verify-someone/app" },
  });
  const prompt = calls.find((c) => c.label === "verify:1").prompt;
  assert.match(prompt, /検証資産の保存場所: <home>\/verify-someone\/app/);
  assert.doesNotMatch(result.stats, /someone/);
});

test("動作確認の prompt は、質問できないことと blocked の範囲を伝える", async () => {
  const { calls } = await runWorkflow();
  const prompt = calls.find((c) => c.label === "verify:1").prompt;
  assert.match(prompt, /質問できない/);
  assert.match(prompt, /blocked=true/);
});

test("動作確認の prompt は、質問できずに確認に進めないときも blocked=true にさせる", async () => {
  const { calls } = await runWorkflow();
  const prompt = calls.find((c) => c.label === "verify:1").prompt;
  assert.match(prompt, /確認に進まず、passed=false・blocked=true/);
});

test("verifyArgs が文字列でなければ拒否する", async () => {
  await assert.rejects(runWorkflow({ args: { verifyArgs: ["x"] } }), /verifyArgs は文字列/);
});

test("レビュアーが全員 null なら指摘ゼロとみなさずに停止する", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          "mattpocock-standards": null,
          "mattpocock-spec": null,
          ecc: null,
          "silent-failure": null,
        },
      ],
    }),
  });
  assert.equal(result.stopReason, "reviewers-failed");
});

test("テスト/lint が通らなければレビューせずに停止する", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({ checks: () => ({ passed: false, details: "lint error" }) }),
  });
  assert.equal(result.stopReason, "checks-failing");
  assert.ok(!labels.some((l) => l.startsWith("review:")));
});

test("merge がどの cluster にも入れなかった指摘は、単独の cluster として判定に残す", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("ghost", ["nope#9"])]],
      fixes: [{ results: [{ key: "a.js::unmerged:bug", action: "fixed" }], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.equal(result.stopReason, null);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("必須の引数が欠けていれば agent を呼ぶ前に throw する", async () => {
  await assert.rejects(runWorkflow({ args: { requirementsPath: "" } }), /requirementsPath/);
  await assert.rejects(runWorkflow({ args: { checkCommands: [] } }), /checkCommands/);
  await assert.rejects(runWorkflow({ args: { maxReviewRounds: "abc" } }), /maxReviewRounds/);
  await assert.rejects(runWorkflow({ args: { maxVerifyRetries: -1 } }), /maxVerifyRetries/);
});

test("知らない引数は agent を呼ぶ前に拒否する(取り除いた prBase を渡されても黙って受け取らない)", async () => {
  const labels = [];
  const respond = (label, calls) => (labels.push(label), scenario()(label, calls));
  await assert.rejects(runWorkflow({ args: { prBase: "main" }, respond }), /知らない引数.*prBase/);
  assert.deepEqual(labels, []);
});

test("observations を報告にまとめる", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      checks: () => ({ passed: true, details: "", changes: [], observations: ["README が古い"] }),
    }),
  });
  assert.match(section(result.report, "Observations"), /checks:1: README が古い/);
});

test("merge が code の修正必須指摘を requirements の cluster に入れても、code 側は修正に回す", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          ecc: [finding("HIGH")],
          "mattpocock-spec": [finding("judgement", { target: "requirements" })],
        },
        {},
      ],
      merges: [
        [cluster("a.js::mixed", ["ecc#0", "mattpocock-spec#0"], { target: "requirements" })],
      ],
      fixes: [{ results: [{ key: "a.js::mixed", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.match(section(result.report, "Requirements Concern"), /issue a.js::mixed/);
});

test("merge の requirementsBreaking 申告だけでは停止しない(元の指摘が requirementsBreaking のときだけ止まる)", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ "mattpocock-spec": [finding("judgement", { target: "requirements" })] }],
      merges: [
        [
          cluster("requirements::x", ["mattpocock-spec#0"], {
            target: "requirements",
            requirementsBreaking: true,
          }),
        ],
      ],
    }),
  });
  assert.equal(result.stopReason, null);
});

test("閉じた key に統合された修正必須指摘は、元の指摘の内容を報告に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [
        { "silent-failure": [finding("HIGH")] },
        {
          "silent-failure": [finding("HIGH")],
          ecc: [finding("CRITICAL", { summary: "new sqli" })],
        },
      ],
      merges: [
        [cluster("a.js::scope", ["silent-failure#0"])],
        [cluster("a.js::scope", ["silent-failure#0", "ecc#0"])],
      ],
      fixes: [
        {
          results: [{ key: "a.js::scope", action: "propose-defer", reason: "plan の範囲外" }],
          observations: [],
        },
      ],
      verdicts: { "a.js::scope": { agree: true, reason: "plan のタスク外" } },
    }),
  });
  assert.match(section(result.report, "閉じた指摘に統合された修正必須指摘"), /new sqli/);
});

test("最終ラウンドでレビュアーが欠けていたら、報告の先頭で警告する", async () => {
  const { result } = await runWorkflow({
    respond: scenario({ reviews: [{ ecc: null }] }),
  });
  assert.ok(result.report.startsWith("> **注意**"));
  assert.match(result.report.split("\n")[0], /ecc/);
});

test("修正後に再レビューされずに止まったら、その指摘を Unresolved に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      checks: (round) => ({ passed: round === 1, details: "lint error" }),
      reviews: [{ ecc: [finding("HIGH")] }],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(result.stopReason, "checks-failing");
  assert.match(
    section(result.report, "Unresolved Finding"),
    /issue a.js::bug.*再レビューされていない/,
  );
});

test("途中で agent が throw しても、報告を組み立てて返す", async () => {
  const base = scenario();
  const { result } = await runWorkflow({
    respond: (label, calls) => {
      if (label === "verify:1") throw new Error("budget exhausted");
      return base(label, calls);
    },
  });
  assert.equal(result.stopReason, "error");
  assert.match(result.report, /budget exhausted/);
});

test("修正エージェントが throw しても、修正に回した指摘を Unresolved に残す", async () => {
  const base = scenario({
    reviews: [{ ecc: [finding("HIGH")] }],
    merges: [[cluster("a.js::bug", ["ecc#0"])]],
  });
  const { result } = await runWorkflow({
    respond: (label, calls) => {
      if (label === "fix:1") throw new Error("budget exhausted");
      return base(label, calls);
    },
  });
  assert.equal(result.stopReason, "error");
  assert.match(
    section(result.report, "Unresolved Finding"),
    /issue a.js::bug.*再レビューされていない/,
  );
});

test("requirementsBreaking で停止したラウンドの code 側の修正必須指摘も Unresolved に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          ecc: [
            finding("CRITICAL", { target: "requirements", requirementsBreaking: true }),
            finding("HIGH", { file: "b.js" }),
          ],
        },
      ],
      merges: [
        [
          cluster("requirements::broken", ["ecc#0"], {
            target: "requirements",
            requirementsBreaking: true,
          }),
          cluster("b.js::bug", ["ecc#1"], { file: "b.js" }),
        ],
      ],
    }),
  });
  assert.equal(result.stopReason, "requirements-breaking");
  assert.match(section(result.report, "Unresolved Finding"), /issue b.js::bug/);
});

test("見送りの検証者が throw したら、同意なしの却下として扱い、修正に戻す", async () => {
  const base = scenario({
    reviews: [{ ecc: [finding("HIGH")] }, { ecc: [finding("HIGH")] }, {}],
    merges: [[cluster("a.js::bug", ["ecc#0"])], [cluster("a.js::bug", ["ecc#0"])]],
    fixes: [
      {
        results: [{ key: "a.js::bug", action: "propose-defer", reason: "面倒" }],
        observations: [],
      },
      { results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] },
    ],
  });
  const { result, calls } = await runWorkflow({
    respond: (label, calls) => {
      if (label.startsWith("defer-verify:")) throw new Error("verifier crashed");
      return base(label, calls);
    },
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /検証者が結果を返さなかった/);
  assert.match(section(result.report, "Deferred Finding"), /なし/);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("レビューの prompt は skill の差分収集手順を base...HEAD で上書きする", async () => {
  const { calls } = await runWorkflow();
  const ecc = calls.find((c) => c.label === "review:ecc").prompt;
  assert.match(ecc, /git diff --name-only origin\/main\.\.\.HEAD/);
  assert.match(ecc, /Nothing to review/);
});

test("レビューは mattpocock の 2 軸・ecc・silent-failure の 4 体で、silent-failure だけをエージェント種別で起動する(ADR 0020)", async () => {
  const { calls } = await runWorkflow();
  const reviews = calls.filter((c) => c.label.startsWith("review:"));
  assert.deepEqual(
    reviews.map((c) => c.label),
    REVIEW_LABELS,
  );
  const agentTypes = Object.fromEntries(reviews.map((c) => [c.label, c.opts.agentType]));
  assert.deepEqual(agentTypes, {
    "review:mattpocock-standards": undefined,
    "review:mattpocock-spec": undefined,
    "review:ecc": undefined,
    "review:silent-failure": "pr-review-toolkit:silent-failure-hunter",
  });
  for (const c of reviews) assert.ok(c.opts.schema, `${c.label} に schema が無い`);
});

test("ecc には正しさとセキュリティだけを見させ、規約とコード品質は Standards 軸に任せる", async () => {
  const { calls } = await runWorkflow();
  const ecc = calls.find((c) => c.label === "review:ecc").prompt;
  assert.match(ecc, /正しさとセキュリティ/);
  assert.match(ecc, /Code Quality/);
});

test("見送りを却下された指摘は、次のラウンドで再指摘されなくても直ったとみなさず修正に戻す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [
        {
          results: [{ key: "a.js::bug", action: "propose-defer", reason: "面倒" }],
          observations: [],
        },
        { results: [{ key: "a.js::bug", action: "fixed" }], observations: [] },
      ],
      verdicts: { "a.js::bug": { agree: false, reason: "実バグ" } },
    }),
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /実バグ/);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("2回目の見送りも却下された指摘は、再指摘されなくても Unresolved に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [
        {
          results: [{ key: "a.js::bug", action: "propose-defer", reason: "面倒" }],
          observations: [],
        },
        {
          results: [{ key: "a.js::bug", action: "propose-defer", reason: "やはり面倒" }],
          observations: [],
        },
      ],
      verdicts: { "a.js::bug": { agree: false, reason: "実バグ" } },
    }),
  });
  assert.match(section(result.report, "Unresolved Finding"), /issue a.js::bug/);
});

// 見送りを却下された指摘は、次のラウンドで修正必須として判定されない限り「報告された」とみなさない。
const rejectedOnce = {
  fixes: [
    {
      results: [{ key: "a.js::bug", action: "propose-defer", reason: "面倒" }],
      observations: [],
    },
    { results: [{ key: "a.js::bug", action: "fixed" }], observations: [] },
  ],
  verdicts: { "a.js::bug": { agree: false, reason: "実バグ" } },
};

async function assertRejectedGoesBackToFix(reviews, merges) {
  const { result, calls } = await runWorkflow({
    respond: scenario({ reviews, merges, ...rejectedOnce }),
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /実バグ/);
  assert.equal(result.stopReason, null);
  return result;
}

test("見送りを却下された key を merge が中身の無い cluster で再申告しても、修正に戻す", async () => {
  await assertRejectedGoesBackToFix(
    [
      { ecc: [finding("HIGH")] },
      { "mattpocock-standards": [finding("judgement", { file: "c.js" })] },
      {},
    ],
    [
      [cluster("a.js::bug", ["ecc#0"])],
      [
        cluster("a.js::bug", ["bogus#1"]),
        cluster("c.js::nit", ["mattpocock-standards#0"], { file: "c.js" }),
      ],
    ],
  );
});

test("見送りを却下された key が修正必須でない重大度で再報告されても、修正に戻す", async () => {
  const result = await assertRejectedGoesBackToFix(
    [{ ecc: [finding("HIGH")] }, { ecc: [finding("MEDIUM")] }, {}],
    [[cluster("a.js::bug", ["ecc#0"])], [cluster("a.js::bug", ["ecc#0"])]],
  );
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /なし/);
});

test("見送りを却下された key が Requirements Document 向けの指摘だけで再報告されても、修正に戻す", async () => {
  await assertRejectedGoesBackToFix(
    [
      { ecc: [finding("HIGH")] },
      { "mattpocock-spec": [finding("judgement", { target: "requirements" })] },
      {},
    ],
    [[cluster("a.js::bug", ["ecc#0"])], [cluster("a.js::bug", ["mattpocock-spec#0"])]],
  );
});

test("修正エージェントが対応結果を返さなかった指摘は、再指摘されなくても修正に戻す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [
        { results: [], observations: [] },
        { results: [{ key: "a.js::bug", action: "fixed" }], observations: [] },
      ],
    }),
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /対応結果が返らなかった/);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("修正エージェントが2回続けて対応結果を返さなかった指摘は Unresolved に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [
        { results: [], observations: [] },
        { results: [], observations: [] },
      ],
    }),
  });
  assert.match(section(result.report, "Unresolved Finding"), /issue a.js::bug/);
});

test("レビューラウンドが1回も完了せずに止まったら、Unresolved を「なし」ではなく未レビューと出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({ checks: () => ({ passed: false, details: "lint error" }) }),
  });
  const unresolved = section(result.report, "Unresolved Finding");
  assert.match(unresolved, /未レビュー/);
  assert.doesNotMatch(unresolved, /なし/);
});

test("動作確認の修正エージェントが直せなかったら、レビューはするが再確認はせずに止める", async () => {
  const base = scenario({ verifies: [{ passed: false, summary: "画面が真っ白" }] });
  const { result, labels } = await runWorkflow({
    respond: (label, calls) =>
      label.startsWith("fix-verify:")
        ? { fixed: false, summary: "原因が分からない" }
        : base(label, calls),
  });
  assert.deepEqual(
    labels.filter((l) => l.startsWith("verify:")),
    ["verify:1"],
  );
  assert.equal(labels.filter((l) => l === "review:ecc").length, 2);
  assert.equal(result.stopReason, "verify-unfixed");
  assert.match(result.report, /原因が分からない/);
});

// 残りが BUDGET_FLOOR を割るのは、指定した label の agent を呼び終えた後から。
function budgetLowAfter(label) {
  let low = false;
  return {
    budget: { total: 1000000, spent: () => 1234, remaining: () => (low ? 1 : 1000000) },
    wrap: (respond) => (l, calls) => {
      const result = respond(l, calls);
      if (l === label) low = true;
      return result;
    },
  };
}

test("動作確認の再試行の前に予算が下限を割ったら、budget で止める", async () => {
  const { budget, wrap } = budgetLowAfter("verify:1");
  const { result, labels } = await runWorkflow({
    budget,
    respond: wrap(scenario({ verifies: [{ passed: false, summary: "画面が真っ白" }] })),
  });
  assert.ok(!labels.includes("fix-verify:1"));
  assert.equal(result.stopReason, "budget");
});

test("レビューの収束後に予算が下限を割ったら、1回目の動作確認にも入らず budget で止め、どこの前で止まったかを報告に出す", async () => {
  const { budget, wrap } = budgetLowAfter("review:silent-failure");
  const { result, labels } = await runWorkflow({ budget, respond: wrap(scenario()) });
  assert.ok(!labels.includes("verify:1"));
  assert.equal(result.stopReason, "budget");
  assert.doesNotMatch(result.report, /次のラウンドに入らなかった/);
  assert.match(result.report, /動作確認 1 回目の前/);
});

test("入口 skill が書き出せるよう ledger を返す", async () => {
  const { result } = await runWorkflow();
  assert.equal(JSON.parse(result.ledger).config.requirementsPath, BASE_ARGS.requirementsPath);
});

test("途中のラウンドでレビュアーが欠けていても、報告の先頭で警告する", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: null, "silent-failure": [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::bug", ["silent-failure#0"])], []],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.ok(result.report.startsWith("> **注意**"));
  assert.match(result.report.split("\n")[0], /ラウンド 1.*ecc/);
});

test("報告の統計の節は上限を示し、mode 行も帰属行も付けない", async () => {
  const { result } = await runWorkflow();
  assert.match(section(result.report, "統計"), /- 上限: maxReviewRounds 3 \/ maxVerifyRetries 2/);
  assert.doesNotMatch(result.report, /- mode:/);
  assert.doesNotMatch(result.report, /Generated with/);
});

test("mode を渡されたら、廃止した Deliver として走らせず、知らない引数として agent を呼ぶ前に拒否する(ADR 0022)", async () => {
  // agent が先に呼ばれると、その throw は stopReason=error として捕まって resolve するので、rejects が落ちる。
  const respond = (label) => {
    throw new Error(`agent が呼ばれた: ${label}`);
  };
  for (const mode of ["deliver", "review-verify"]) {
    await assert.rejects(runWorkflow({ args: { mode }, respond }), /知らない引数.*mode/);
  }
});

test("値が undefined の引数は既定値を消さない(修正ラウンドの上限は 3 のまま)", async () => {
  const keys = ["k1", "k2", "k3", "k4"];
  const { labels } = await runWorkflow({
    args: { maxReviewRounds: undefined },
    respond: scenario({
      reviews: keys.map(() => ({ ecc: [finding("HIGH")] })),
      merges: keys.map((k) => [cluster(k, ["ecc#0"])]),
      fixes: keys.map((k) => ({
        results: [{ key: k, action: "fixed", reason: "" }],
        observations: [],
      })),
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 3);
});

test("テスト/lint が通らなければ、レビューも動作確認もせずに停止する", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({ checks: () => ({ passed: false, details: "lint 失敗" }) }),
  });
  assert.deepEqual(labels, ["checks:1"]);
  assert.equal(result.stopReason, "checks-failing");
  assert.match(section(result.report, "Unresolved Finding"), /未レビュー/);
});

test("requirementsBreaking により停止したら、動作確認をしない", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [
        { ecc: [finding("CRITICAL", { target: "requirements", requirementsBreaking: true })] },
      ],
      merges: [
        [
          cluster("requirements::broken", ["ecc#0"], {
            target: "requirements",
            requirementsBreaking: true,
          }),
        ],
      ],
    }),
  });
  assert.equal(result.stopReason, "requirements-breaking");
  assert.ok(!labels.some((l) => l.startsWith("verify:")));
});

test("動作確認が失敗したら、直した後にレビューし直してから再確認する", async () => {
  const { labels } = await runWorkflow({
    respond: scenario({
      verifies: [
        { passed: false, summary: "画面が真っ白" },
        { passed: true, summary: "ok" },
      ],
    }),
  });
  assert.deepEqual(labels, [
    "checks:1",
    ...REVIEW_LABELS,
    "verify:1",
    "fix-verify:1",
    "checks:2",
    ...REVIEW_LABELS,
    "verify:2",
  ]);
});

test("要件文書のうちブランチが着手していない項目を実装させないよう、テスト/lint・レビュー・修正・動作確認の prompt で範囲を限る", async () => {
  const respond = scenario({
    reviews: [{ "silent-failure": [finding("HIGH")] }, {}],
    merges: [[cluster("a.js::scope", ["silent-failure#0"])]],
    fixes: [
      {
        results: [{ key: "a.js::scope", action: "propose-defer", reason: "未着手の要件" }],
        observations: [],
      },
    ],
    verdicts: { "a.js::scope": { agree: true, reason: "ブランチの範囲外" } },
    verifies: [
      { passed: false, summary: "画面が真っ白" },
      { passed: true, summary: "ok" },
    ],
  });
  const scoped = ["checks:", "review:", "fix:", "defer-verify:", "verify:", "fix-verify:"];
  const promptsOf = (calls) =>
    scoped.map((prefix) => {
      const call = calls.find((c) => c.label.startsWith(prefix));
      assert.ok(call, `${prefix} が呼ばれていない`);
      return call.prompt;
    });

  const { calls } = await runWorkflow({ respond });
  for (const prompt of promptsOf(calls)) {
    assert.match(prompt, /まだ着手していない/);
    // 範囲の制約を口実に、ブランチ自身の変更の不具合を見送らせない。
    assert.match(prompt, /不具合.*範囲外にしない/);
  }
  const call = (label) => calls.find((c) => c.label.startsWith(label)).prompt;
  // checks の prompt は要件文書を他に名指ししないので、範囲の文が指す文書を添える。
  assert.ok(call("checks:").includes(BASE_ARGS.requirementsPath));
  assert.match(call("checks:"), /passed=false/);
  // 未着手の項目だけに向く Requirements Concern で、ブランチのレビューごと止めない。
  assert.match(
    call("review:"),
    /未着手の項目だけに向く Requirements Concern は、requirementsBreaking=false/,
  );
  assert.match(call("defer-verify:"), /自分で確かめ/);
  assert.match(call("fix-verify:"), /fixed=false/);
});

test("コードを編集する checks・fix・fix-verify の prompt は、要件文書の変更を禁じる", async () => {
  const respond = scenario({
    reviews: [{ "silent-failure": [finding("HIGH")] }, {}],
    merges: [[cluster("a.js::bug", ["silent-failure#0"])]],
    fixes: [{ results: [{ key: "a.js::bug", action: "fixed" }], observations: [] }],
    verifies: [
      { passed: false, summary: "画面が真っ白" },
      { passed: true, summary: "ok" },
    ],
  });
  const { calls } = await runWorkflow({ respond });
  for (const prefix of ["checks:", "fix:", "fix-verify:"]) {
    const call = calls.find((c) => c.label.startsWith(prefix));
    assert.ok(call, `${prefix} が呼ばれていない`);
    assert.ok(
      call.prompt.includes(`要件文書 ${BASE_ARGS.requirementsPath} は変更しない`),
      `${prefix} が要件文書の変更を禁じていない`,
    );
  }
});

test("テスト/lint を通すために checks がコードを変えたら、通った場合も報告に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      checks: () => ({
        passed: true,
        details: "",
        changes: [{ file: "src/a.js", summary: "未使用の import を削除" }],
      }),
    }),
  });
  assert.match(
    section(result.report, "テスト/lint を通すための変更"),
    /checks:1: `src\/a\.js` 未使用の import を削除/,
  );
  // 入口 skill が git の差分と照合できるよう、ファイルを ledger に構造のまま残す。
  assert.deepEqual(JSON.parse(result.ledger).checksChanges, [
    { label: "checks:1", file: "src/a.js", summary: "未使用の import を削除" },
  ]);
});

test("checks がコードを変えなければ、その節は「なし」と出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({ checks: () => ({ passed: true, details: "", changes: [] }) }),
  });
  assert.equal(section(result.report, "テスト/lint を通すための変更").trim(), "なし");
});

test("動作確認の修正がコードを変えたら、直った場合も報告と ledger に残す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      verifies: [
        { passed: false, summary: "画面が真っ白" },
        { passed: true, summary: "ok" },
      ],
      fixVerify: () => ({
        fixed: true,
        summary: "初期化の順序を直した",
        changes: [{ file: "src/app.js", summary: "描画前に store を初期化する" }],
      }),
    }),
  });
  assert.match(calls.find((c) => c.label === "fix-verify:1").prompt, /変更したファイルごとに/);
  assert.match(
    section(result.report, "動作確認を通すための変更"),
    /fix-verify:1: `src\/app\.js` 描画前に store を初期化する/,
  );
  // 入口 skill が git の差分と照合できるよう、ファイルを ledger に構造のまま残す。
  assert.deepEqual(JSON.parse(result.ledger).verifyFixChanges, [
    { label: "fix-verify:1", file: "src/app.js", summary: "描画前に store を初期化する" },
  ]);
});

test("未着手の項目を範囲外とする規則が要件文書とのずれを直す指示より優先すると明示する", async () => {
  const { calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ "silent-failure": [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::bug", ["silent-failure#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed" }], observations: [] }],
    }),
  });
  for (const prefix of ["checks:", "fix:"]) {
    const prompt = calls.find((c) => c.label.startsWith(prefix)).prompt;
    assert.match(prompt, /要件文書とのずれを直す指示より優先する/, prefix);
  }
});

test("レビュー指摘を直したら、直した指摘と変えたファイルを報告と ledger に残す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [
        {
          results: [{ key: "a.js::bug", action: "fixed" }],
          changes: [{ file: "a.js", summary: "null を弾く" }],
          observations: [],
        },
      ],
    }),
  });
  assert.match(calls.find((c) => c.label === "fix:1").prompt, /変更したファイルごとに/);
  assert.match(section(result.report, "修正した指摘"), /`a\.js:1` issue a\.js::bug \[ecc:HIGH\]/);
  assert.match(
    section(result.report, "レビュー指摘を直すための変更"),
    /fix:1: `a\.js` null を弾く/,
  );
  // 入口 skill が git の差分と照合できるよう、ファイルを ledger に構造のまま残す。
  assert.deepEqual(JSON.parse(result.ledger).fixChanges, [
    { label: "fix:1", file: "a.js", summary: "null を弾く" },
  ]);
});

test("直したと申告した指摘が Unresolved になったら、修正した指摘には出さない", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, { ecc: [finding("HIGH")] }],
      merges: [[cluster("a.js::bug", ["ecc#0"])], [cluster("a.js::bug", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed" }], changes: [], observations: [] }],
    }),
  });
  assert.match(section(result.report, "Unresolved Finding"), /a\.js::bug/);
  assert.equal(section(result.report, "修正した指摘").trim(), "なし");
});

test("修正の prompt は receiving-code-review で判断させ、非対話の読み替えと、参考指摘を直す側に倒す指示を含む", async () => {
  const { calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH"), finding("MEDIUM", { summary: "style" })] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"]), cluster("a.js::style", ["ecc#1"])]],
      fixes: [
        {
          results: [
            { key: "a.js::bug", action: "fixed" },
            { key: "a.js::style", action: "fixed" },
          ],
          changes: [],
          observations: [],
        },
      ],
    }),
  });
  const prompt = calls.find((c) => c.label === "fix:1").prompt;
  assert.match(prompt, /Skill ツールで「superpowers:receiving-code-review」を読み込み/);
  assert.match(prompt, /人間に質問できない/);
  assert.match(prompt, /action="propose-defer" とし、その旨を reason に書く/);
  assert.match(prompt, /参考指摘は、技術的に正しく要件文書と衝突しないなら直す/);
  assert.match(prompt, /直すのが大変だという理由では見送らない/);
  assert.match(prompt, /修正必須・参考の両方/);
});

test("統計は報告の「統計」節と同じ内容を stats として返し、収束したレビューの実行を数える", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(`## 統計\n${section(result.report, "統計")}`.trim(), result.stats);
  assert.match(result.stats, /- 上限: maxReviewRounds 3 \/ maxVerifyRetries 2/);
  assert.match(result.stats, /- 停止: なし/);
  assert.match(result.stats, /- レビューの実行: 1\(動作確認の失敗による再入 0\)/);
  assert.match(result.stats, /- 実行 1: 収束した\(ラウンド 1〜2\)/);
  assert.match(result.stats, /- 動作確認の試行: 1/);
  assert.doesNotMatch(result.stats, /Generated with/);
});

test("修正ラウンドの上限で抜けたレビューの実行は、統計で上限に達したと数える", async () => {
  const { result } = await runWorkflow({
    args: { maxReviewRounds: 0 },
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }],
      merges: [[cluster("a.js::style", ["ecc#0"])]],
    }),
  });
  assert.match(result.stats, /- 実行 1: 修正ラウンドの上限に達した\(ラウンド 1〜1\)/);
});

test("動作確認の失敗で再入したレビューは、統計で実行を分けて数える", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      verifies: [
        { passed: false, summary: "画面が真っ白" },
        { passed: true, summary: "ok" },
      ],
    }),
  });
  assert.match(result.stats, /- レビューの実行: 2\(動作確認の失敗による再入 1\)/);
  assert.match(result.stats, /- 実行 1: 収束した\(ラウンド 1〜1\)/);
  assert.match(result.stats, /- 実行 2: 収束した\(ラウンド 2〜2\)/);
  assert.match(result.stats, /- 動作確認の試行: 2/);
});

test("予算で止まったレビューの実行は、上限に達したとは数えずに停止として数える", async () => {
  const { budget, wrap } = budgetLowAfter("fix:1");
  const { result } = await runWorkflow({
    budget,
    respond: wrap(
      scenario({
        reviews: [{ ecc: [finding("HIGH")] }],
        merges: [[cluster("a.js::bug", ["ecc#0"])]],
        fixes: [{ results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] }],
      }),
    ),
  });
  assert.equal(result.stopReason, "budget");
  assert.match(result.stats, /- 実行 1: 停止した\(ラウンド 1〜1\)/);
  assert.match(result.stats, /- 停止: トークン予算の残りが下限を割った/);
});

test("統計にはエージェントの自由記述(停止の詳細)を入れない", async () => {
  const base = scenario({ verifies: [{ passed: false, summary: "画面が真っ白" }] });
  const { result } = await runWorkflow({
    respond: (label, calls) =>
      label.startsWith("fix-verify:")
        ? { fixed: false, summary: "原因が分からない" }
        : base(label, calls),
  });
  assert.equal(result.stopReason, "verify-unfixed");
  assert.match(result.report, /原因が分からない/);
  assert.doesNotMatch(result.stats, /原因が分からない|画面が真っ白/);
  assert.match(result.stats, /- 停止: 動作確認の失敗を修正エージェントが直せなかった/);
});

test("mattpocock 系の hard は修正必須、judgement は参考指摘になる(ADR 0020)", async () => {
  const { result, labels, calls } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          "mattpocock-spec": [finding("hard", { summary: "要件とずれる" })],
          "mattpocock-standards": [finding("judgement", { file: "b.js", summary: "命名" })],
        },
        {},
      ],
      merges: [
        [
          cluster("a.js::spec-drift", ["mattpocock-spec#0"]),
          cluster("b.js::naming", ["mattpocock-standards#0"], { file: "b.js" }),
        ],
      ],
      fixes: [
        {
          results: [
            { key: "a.js::spec-drift", action: "fixed" },
            { key: "b.js::naming", action: "fixed" },
          ],
          changes: [],
          observations: [],
        },
      ],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  const fixPrompt = calls.find((c) => c.label === "fix:1").prompt;
  const blockingPart = fixPrompt.slice(0, fixPrompt.indexOf("参考指摘(JSON)"));
  assert.match(blockingPart, /a\.js::spec-drift/);
  assert.doesNotMatch(blockingPart, /b\.js::naming/);
  assert.match(
    section(result.report, "修正した指摘"),
    /\[参考\] `b\.js:1` issue b\.js::naming \[mattpocock-standards:judgement\]/,
  );
});

test("元の指摘がすべて smell の統合指摘は修正に回さず、Smell Finding として報告し、統計には件数だけを出す(ADR 0020)", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          "mattpocock-standards": [
            finding("judgement", {
              summary: "他のモジュールのデータばかり触る",
              smell: "Feature Envy",
            }),
          ],
        },
      ],
      merges: [[cluster("a.js::feature-envy", ["mattpocock-standards#0"])]],
    }),
  });
  assert.deepEqual(labels, ["checks:1", ...REVIEW_LABELS, "merge", "verify:1"]);
  assert.equal(result.stopReason, null);
  assert.match(
    section(result.report, "Smell Finding"),
    /`a\.js:1` issue a\.js::feature-envy \[mattpocock-standards:judgement\]/,
  );
  assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
  assert.match(result.stats, /Smell 1/);
  assert.doesNotMatch(result.stats, /feature-envy|Feature Envy/);
});

test("hard を付けた smell も修正必須にしない", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          "mattpocock-standards": [finding("hard", { summary: "重複", smell: "Duplicated Code" })],
        },
      ],
      merges: [[cluster("a.js::duplicated", ["mattpocock-standards#0"])]],
    }),
  });
  assert.ok(!labels.some((l) => l.startsWith("fix:")));
  assert.match(section(result.report, "Smell Finding"), /a\.js::duplicated/);
});

test("smell と他のレビュアーの修正必須の指摘が統合されたら、修正必須として修正に回す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          "mattpocock-standards": [finding("judgement", { smell: "Duplicated Code" })],
          ecc: [finding("HIGH")],
        },
        {},
      ],
      merges: [[cluster("a.js::dup-bug", ["mattpocock-standards#0", "ecc#0"])]],
      fixes: [
        { results: [{ key: "a.js::dup-bug", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  const fixPrompt = calls.find((c) => c.label === "fix:1").prompt;
  assert.match(fixPrompt.slice(0, fixPrompt.indexOf("参考指摘(JSON)")), /a\.js::dup-bug/);
  assert.equal(section(result.report, "Smell Finding").trim(), "なし");
});

test("mattpocock の code-review は担当する軸だけを実行させ、対話・issue tracker・サブエージェントの手順を上書きする", async () => {
  const { calls } = await runWorkflow();
  const prompt = (id) => calls.find((c) => c.label === `review:${id}`).prompt;
  const standards = prompt("mattpocock-standards");
  const spec = prompt("mattpocock-spec");
  for (const p of [standards, spec]) {
    assert.match(p, /「mattpocock-skills:code-review」/);
    assert.match(p, /サブエージェントの起動/);
    assert.match(p, /setup-matt-pocock-skills/);
    assert.match(p, /語数制限は無視/);
  }
  assert.match(standards, /Standards 軸だけ/);
  assert.match(standards, /\.claude\/rules/);
  assert.match(standards, /smell にその名前/);
  assert.match(spec, /Spec 軸だけ/);
});

test("要件文書に無い振る舞いは Requirements Concern に回させ、要件文書とのずれは Spec 軸にだけ見させる", async () => {
  const { calls } = await runWorkflow();
  const prompt = (id) => calls.find((c) => c.label === `review:${id}`).prompt;
  assert.match(
    prompt("mattpocock-spec"),
    /scope creep.*target="requirements"・requirementsBreaking=false/,
  );
  assert.match(prompt("mattpocock-spec"), /範囲外である/);
  for (const id of ["mattpocock-standards", "ecc", "silent-failure"])
    assert.doesNotMatch(prompt(id), /要件文書とのずれを指摘/);
});

test("動作確認の失敗の修正は diagnosing-bugs で行い、再現できないときは直せなかったとして返させる", async () => {
  const { calls } = await runWorkflow({
    respond: scenario({
      verifies: [
        { passed: false, summary: "画面が真っ白" },
        { passed: true, summary: "ok" },
      ],
    }),
  });
  const prompt = calls.find((c) => c.label === "fix-verify:1").prompt;
  assert.match(prompt, /「mattpocock-skills:diagnosing-bugs」/);
  assert.match(prompt, /再現.*fixed=false/);
  assert.match(prompt, /回帰テスト/);
});

test("Smell Finding だった key が後のラウンドで修正必須になったら、Smell Finding としては報告しない", async () => {
  const fixed = (key) => ({ results: [{ key, action: "fixed" }], changes: [], observations: [] });
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          "mattpocock-standards": [finding("judgement", { smell: "Duplicated Code" })],
          ecc: [finding("HIGH", { file: "b.js" })],
        },
        { ecc: [finding("HIGH")] },
        {},
      ],
      merges: [
        [
          cluster("a.js::duplicated", ["mattpocock-standards#0"]),
          cluster("b.js::bug", ["ecc#0"], { file: "b.js" }),
        ],
        [cluster("a.js::duplicated", ["ecc#0"])],
      ],
      fixes: [fixed("b.js::bug"), fixed("a.js::duplicated")],
    }),
  });
  assert.equal(section(result.report, "Smell Finding").trim(), "なし");
  assert.match(section(result.report, "修正した指摘"), /a\.js::duplicated/);
});

test("同じラウンドで同じ key が smell だけの cluster と修正必須の cluster に分かれたら、Smell Finding に数えない", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          "mattpocock-standards": [finding("judgement", { smell: "Duplicated Code" })],
          ecc: [finding("HIGH")],
        },
        {},
      ],
      merges: [
        [
          cluster("a.js::duplicated", ["mattpocock-standards#0"]),
          cluster("a.js::duplicated", ["ecc#0"]),
        ],
      ],
      fixes: [
        { results: [{ key: "a.js::duplicated", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  assert.equal(section(result.report, "Smell Finding").trim(), "なし");
  assert.match(result.stats, /ラウンド 1: .*Smell 0/);
});

test("Standards 軸にはユーザーのグローバル規約を規約として扱わせず、Spec 軸の欠落の指摘は着手済みの項目に限らせる", async () => {
  const { calls } = await runWorkflow();
  const prompt = (id) => calls.find((c) => c.label === `review:${id}`).prompt;
  assert.match(prompt("mattpocock-standards"), /~\/\.claude.*規約の出所にしない/);
  assert.match(prompt("mattpocock-spec"), /着手した項目/);
});

test("skill を使わないレビュアーには skill の尺度とは言わない", async () => {
  const { calls } = await runWorkflow();
  const prompt = calls.find((c) => c.label === "review:silent-failure").prompt;
  assert.doesNotMatch(prompt, /skill/);
  assert.match(prompt, /CRITICAL \/ HIGH \/ MEDIUM/);
});

test("直したと回答した参考指摘が smell として再指摘されたら、直ったとは報告せず、再指摘として残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [
        { "mattpocock-standards": [finding("judgement", { summary: "命名" })] },
        {
          "mattpocock-standards": [
            finding("judgement", { summary: "命名", smell: "Mysterious Name" }),
          ],
        },
      ],
      merges: [
        [cluster("a.js::naming", ["mattpocock-standards#0"])],
        [cluster("a.js::naming", ["mattpocock-standards#0"])],
      ],
      fixes: [
        { results: [{ key: "a.js::naming", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  assert.doesNotMatch(section(result.report, "修正した指摘"), /a\.js::naming/);
  assert.match(
    section(result.report, "参考指摘(修正必須ではない)"),
    /a\.js::naming.*再レビューで再指摘された/,
  );
  assert.match(section(result.report, "Smell Finding"), /a\.js::naming/);
});

test("silent-failure には、エージェント定義にある別プロジェクトの仕組みを当てはめさせず、修正必須を誤動作に繋がるものに限らせる", async () => {
  const { calls } = await runWorkflow();
  const prompt = calls.find((c) => c.label === "review:silent-failure").prompt;
  assert.match(prompt, /errorIds.*当てはめない/);
  assert.match(prompt, /CRITICAL と HIGH は.*誤動作/);
});

test("skill を読み込めなかったレビュアーは、結果を返さなかったレビュアーとして扱い、その指摘を使わない", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ "mattpocock-spec": [finding("hard")] }],
      merges: [[cluster("a.js::spec", ["mattpocock-spec#0"])]],
      skillMissing: ["mattpocock-spec"],
    }),
  });
  assert.ok(!labels.some((l) => l.startsWith("fix:")));
  assert.match(result.report, /結果を返さなかったレビュアーがいる\(ラウンド 1: mattpocock-spec\)/);
  assert.match(result.stats, /結果を返さなかったレビュアー: mattpocock-spec/);
});

test("skill を使うレビュアーにだけ skill を読み込めたかを必ず返させる", async () => {
  const { calls } = await runWorkflow();
  for (const c of calls.filter((c) => c.label.startsWith("review:"))) {
    const required = c.opts.schema.required;
    if (c.label === "review:silent-failure") assert.ok(!required.includes("skillLoaded"));
    else
      assert.ok(required.includes("skillLoaded"), `${c.label} が skillLoaded を必須にしていない`);
  }
});

test("動作確認の失敗の修正は、diagnosing-bugs を読み込めなければ直さずに返させる", async () => {
  const { calls } = await runWorkflow({
    respond: scenario({
      verifies: [
        { passed: false, summary: "画面が真っ白" },
        { passed: true, summary: "ok" },
      ],
    }),
  });
  const prompt = calls.find((c) => c.label === "fix-verify:1").prompt;
  assert.match(prompt, /読み込めなければ.*fixed=false/);
});

test("skill を読み込めなかったレビュアーのエラーは Observations に残し、統計には固定の文言だけを出す", async () => {
  const base = scenario({ skillMissing: ["mattpocock-spec"] });
  const respond = (label, calls) => {
    const result = base(label, calls);
    if (label === "review:mattpocock-spec")
      return { ...result, observations: ["Unknown skill: mattpocock-skills:code-review"] };
    return result;
  };
  const { result } = await runWorkflow({ respond });
  assert.match(
    section(result.report, "Observations"),
    /review:mattpocock-spec: Unknown skill: mattpocock-skills:code-review/,
  );
  assert.match(result.stats, /mattpocock-spec\(ラウンド 1、skill を読み込めなかった\)/);
  assert.doesNotMatch(result.stats, /Unknown skill/);
});

test("smell を報告する役割でないレビュアーが smell を付けても、修正必須の指摘は修正に回す", async () => {
  const { result, calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH", { smell: "Feature Envy" })] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed" }], changes: [], observations: [] }],
    }),
  });
  const fixPrompt = calls.find((c) => c.label === "fix:1").prompt;
  assert.match(fixPrompt.slice(0, fixPrompt.indexOf("参考指摘(JSON)")), /a\.js::bug/);
  assert.equal(section(result.report, "Smell Finding").trim(), "なし");
});
