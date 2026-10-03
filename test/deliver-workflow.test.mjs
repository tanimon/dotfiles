// deliver.js を、agent() などの Workflow のフックを stub にして実行し、
// ループの判定と報告の組み立てを決定的に検証する。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const SCRIPT = readFileSync(
  fileURLToPath(new URL("../dot_claude/workflows/deliver.js", import.meta.url)),
  "utf8",
);
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;

const BASE_ARGS = {
  mode: "deliver",
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

// publish-write に渡した本文を、書き写しに成功した場合の行数・バイト数で返す。
function between(prompt, name) {
  const start = prompt.indexOf(`<<<${name}\n`) + name.length + 4;
  return `${prompt}\n`.slice(start, `${prompt}\n`.indexOf(`\n${name}\n`, start));
}
function faithfulWrite(prompt) {
  const count = (text) => ({ lines: text.split("\n").length, bytes: Buffer.byteLength(text) });
  const body = count(between(prompt, "REPORT"));
  const ledger = count(between(prompt, "LEDGER"));
  return {
    dir: "/repo/.git/deliver",
    bodyLines: body.lines,
    bodyBytes: body.bytes,
    ledgerLines: ledger.lines,
    ledgerBytes: ledger.bytes + 1,
  };
}

// reviews[i] / merges[i] は i 番目のレビューラウンド、fixes[i] は i 番目の修正ラウンドへの応答。
function scenario({
  tasks = [{ title: "t1", summary: "s1" }],
  implement = () => ({ status: "done", commit: "abc", observations: [] }),
  checks = () => ({ passed: true, details: "" }),
  reviews = [],
  merges = [],
  fixes = [],
  verdicts = {},
  verifies = [{ passed: true, summary: "ok" }],
  fixVerify = () => ({ fixed: true, summary: "fixed", changes: [], observations: [] }),
} = {}) {
  let mergeIndex = 0;
  let fixIndex = 0;
  let verifyIndex = 0;
  return (label, calls) => {
    if (label === "plan") return { title: "T", tasks };
    if (label.startsWith("implement:")) return implement(Number(label.split(":")[1]));
    if (label.startsWith("checks:")) return checks(Number(label.split(":")[1]));
    if (label.startsWith("review:")) {
      const id = label.split(":")[1];
      const round = calls.filter((c) => c.label === "review:ecc").length - 1;
      const result = reviews[round]?.[id];
      if (result === null) return null;
      return { findings: result ?? [], observations: [] };
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
    if (label.startsWith("publish-write:")) return faithfulWrite(calls[calls.length - 1].prompt);
    if (label === "publish") return { pushed: true, prUrl: "https://example.invalid/pr/1" };
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
    calls.push({ label: opts.label, prompt });
    return respond(opts.label, calls);
  };
  const parallel = (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)));
  const pipeline = async () => {
    throw new Error("deliver does not use pipeline()");
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

test("指摘ゼロなら修正せずに動作確認と公開まで進む", async () => {
  const { result, labels } = await runWorkflow();
  assert.deepEqual(labels, [
    "plan",
    "implement:1",
    "checks:1",
    "review:ecc",
    "review:requesting",
    "verify:1",
    "publish-write:1",
    "publish",
  ]);
  assert.equal(result.published, true);
  assert.equal(result.stopReason, null);
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
      reviews: [{ ecc: [finding("MEDIUM")], requesting: [finding("Minor")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0", "requesting#0"])]],
      fixes: [
        {
          results: [{ key: "a.js::style", action: "fixed" }],
          changes: [{ file: "a.js", summary: "命名を直す" }],
          observations: [],
        },
      ],
    }),
  });
  assert.deepEqual(labels.slice(2, 10), [
    "checks:1",
    "review:ecc",
    "review:requesting",
    "merge",
    "fix:1",
    "checks:2",
    "review:ecc",
    "review:requesting",
  ]);
  assert.match(calls.find((c) => c.label === "fix:1").prompt, /a\.js::style/);
  assert.equal(result.stopReason, null);
  assert.match(
    section(result.report, "修正した指摘"),
    /\[参考\] `a\.js:1` issue a\.js::style \[ecc:MEDIUM, requesting:Minor\]/,
  );
  assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
  assert.match(result.report, /参考 1\(修正 1 \/ 見送り 0\)/);
  const ledger = JSON.parse(result.ledger);
  assert.deepEqual(ledger.advisoryClosedKeys, ["a.js::style"]);
  assert.deepEqual(ledger.fixChanges, [{ label: "fix:1", file: "a.js", summary: "命名を直す" }]);
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
    assert.equal(section(result.report, "参考指摘(修正必須ではない)").trim(), "なし");
    if (action === "propose-defer") {
      assert.match(
        section(result.report, "見送った参考指摘"),
        /issue a\.js::style.*見送り理由: 意図的な命名/,
      );
      assert.equal(section(result.report, "修正した指摘").trim(), "なし");
    } else {
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
  const { labels } = await runWorkflow({
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
  assert.deepEqual(
    labels.filter((l) => l.startsWith("defer-verify:")),
    ["defer-verify:a.js::bug"],
  );
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
      reviews: [{ requesting: [finding("Important")] }, { requesting: [finding("Important")] }],
      merges: [
        [cluster("a.js::scope", ["requesting#0"])],
        [cluster("a.js::scope", ["requesting#0"])],
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
      reviews: [{ requesting: [finding("Important", { target: "requirements" })] }],
      merges: [[cluster("requirements::ambiguous", ["requesting#0"], { target: "requirements" })]],
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
  assert.ok(breaking.labels.includes("publish"));
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

test("実装タスクが blocked ならレビューに進まずに停止して公開する", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      tasks: [
        { title: "t1", summary: "s1" },
        { title: "t2", summary: "s2" },
      ],
      implement: (n) =>
        n === 1
          ? { status: "blocked", reason: "plan の前提が崩れている", observations: [] }
          : { status: "done", commit: "abc", observations: [] },
    }),
  });
  assert.equal(result.stopReason, "implement-blocked");
  assert.ok(!labels.includes("implement:2"));
  assert.ok(!labels.some((l) => l.startsWith("review:")));
  assert.match(result.report, /plan の前提が崩れている/);
});

test("レビュアーが全員 null なら指摘ゼロとみなさずに停止する", async () => {
  const { result } = await runWorkflow({
    respond: scenario({ reviews: [{ ecc: null, requesting: null }] }),
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

test("observations を報告にまとめる", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      implement: () => ({ status: "done", commit: "abc", observations: ["README が古い"] }),
    }),
  });
  assert.match(section(result.report, "Observations"), /implement:1: README が古い/);
});

test("merge が code の修正必須指摘を requirements の cluster に入れても、code 側は修正に回す", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [
        { ecc: [finding("HIGH")], requesting: [finding("Minor", { target: "requirements" })] },
        {},
      ],
      merges: [[cluster("a.js::mixed", ["ecc#0", "requesting#0"], { target: "requirements" })]],
      fixes: [{ results: [{ key: "a.js::mixed", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.match(section(result.report, "Requirements Concern"), /issue a.js::mixed/);
});

test("merge の requirementsBreaking 申告だけでは停止しない(元の指摘が requirementsBreaking のときだけ止まる)", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ requesting: [finding("Minor", { target: "requirements" })] }],
      merges: [
        [
          cluster("requirements::x", ["requesting#0"], {
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
        { requesting: [finding("Important")] },
        { requesting: [finding("Important")], ecc: [finding("CRITICAL", { summary: "new sqli" })] },
      ],
      merges: [
        [cluster("a.js::scope", ["requesting#0"])],
        [cluster("a.js::scope", ["requesting#0", "ecc#0"])],
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

test("途中で agent が throw しても、報告を組み立てて公開を試みる", async () => {
  const base = scenario();
  const { result, labels } = await runWorkflow({
    respond: (label, calls) => {
      if (label === "verify:1") throw new Error("budget exhausted");
      return base(label, calls);
    },
  });
  assert.equal(result.stopReason, "error");
  assert.match(result.report, /budget exhausted/);
  assert.ok(labels.includes("publish"));
});

test("公開の agent が throw しても、報告は返す", async () => {
  const base = scenario();
  const { result } = await runWorkflow({
    respond: (label, calls) => {
      if (label === "publish") throw new Error("push failed");
      return base(label, calls);
    },
  });
  assert.equal(result.published, false);
  assert.match(result.report, /## Unresolved Finding/);
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

test("ecc の機械的な品質ヒューリスティックは MEDIUM 以下で報告させる", async () => {
  const { calls } = await runWorkflow();
  const ecc = calls.find((c) => c.label === "review:ecc").prompt;
  const requesting = calls.find((c) => c.label === "review:requesting").prompt;
  assert.match(ecc, /MEDIUM 以下/);
  assert.doesNotMatch(requesting, /MEDIUM 以下/);
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
    [{ ecc: [finding("HIGH")] }, { requesting: [finding("Minor", { file: "c.js" })] }, {}],
    [
      [cluster("a.js::bug", ["ecc#0"])],
      [cluster("a.js::bug", ["bogus#1"]), cluster("c.js::nit", ["requesting#0"], { file: "c.js" })],
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
      { requesting: [finding("Minor", { target: "requirements" })] },
      {},
    ],
    [[cluster("a.js::bug", ["ecc#0"])], [cluster("a.js::bug", ["requesting#0"])]],
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

test("書き出したファイルの行数・バイト数が本文と合わなければ1回だけ書き直させる", async () => {
  const base = scenario();
  const { result, labels } = await runWorkflow({
    respond: (label, calls) =>
      label === "publish-write:1"
        ? { dir: "/repo/.git/deliver", bodyLines: 1, bodyBytes: 1, ledgerLines: 1, ledgerBytes: 1 }
        : base(label, calls),
  });
  assert.deepEqual(
    labels.filter((l) => l.startsWith("publish")),
    ["publish-write:1", "publish-write:2", "publish"],
  );
  assert.equal(result.published, true);
});

test("書き直しても本文と合わなければ PR を作らずに published=false で返す", async () => {
  const base = scenario();
  const { result, labels } = await runWorkflow({
    respond: (label, calls) =>
      label.startsWith("publish-write:")
        ? { dir: "/repo/.git/deliver", bodyLines: 1, bodyBytes: 1, ledgerLines: 1, ledgerBytes: 1 }
        : base(label, calls),
  });
  assert.ok(!labels.includes("publish"));
  assert.equal(result.published, false);
  assert.match(result.publishError, /pr-body\.md/);
  assert.match(result.report, /## Unresolved Finding/);
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

test("実装タスクの途中で予算が下限を割ったら、次のタスクに進まず budget で止める", async () => {
  const { budget, wrap } = budgetLowAfter("implement:1");
  const { result, labels } = await runWorkflow({
    budget,
    respond: wrap(
      scenario({
        tasks: [
          { title: "t1", summary: "s1" },
          { title: "t2", summary: "s2" },
        ],
      }),
    ),
  });
  assert.ok(!labels.includes("implement:2"));
  assert.equal(result.stopReason, "budget");
});

test("動作確認の再試行の前に予算が下限を割ったら、budget で止める", async () => {
  const { budget, wrap } = budgetLowAfter("verify:1");
  const { result, labels } = await runWorkflow({
    budget,
    respond: wrap(scenario({ verifies: [{ passed: false, summary: "画面が真っ白" }] })),
  });
  assert.ok(!labels.includes("fix-verify:1"));
  assert.equal(result.stopReason, "budget");
});

test("レビューの収束後に予算が下限を割ったら、1回目の動作確認にも入らず budget で止める", async () => {
  const { budget, wrap } = budgetLowAfter("review:requesting");
  const { result, labels } = await runWorkflow({ budget, respond: wrap(scenario()) });
  assert.ok(!labels.includes("verify:1"));
  assert.equal(result.stopReason, "budget");
});

test("budget で止まったとき、どこの前で止まったかを報告に出す", async () => {
  const { budget, wrap } = budgetLowAfter("implement:1");
  const { result } = await runWorkflow({
    budget,
    respond: wrap(
      scenario({
        tasks: [
          { title: "t1", summary: "s1" },
          { title: "t2", summary: "s2" },
        ],
      }),
    ),
  });
  assert.doesNotMatch(result.report, /次のラウンドに入らなかった/);
  assert.match(result.report, /タスク 2\/2「t2」の前/);
});

test("公開できなくても、入口 skill が書き出せるよう ledger を返す", async () => {
  const base = scenario();
  const { result } = await runWorkflow({
    respond: (label, calls) => {
      if (label.startsWith("publish-write:")) throw new Error("budget exhausted");
      return base(label, calls);
    },
  });
  assert.equal(result.published, false);
  assert.equal(JSON.parse(result.ledger).config.requirementsPath, BASE_ARGS.requirementsPath);
});

test("途中のラウンドでレビュアーが欠けていても、報告の先頭で警告する", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: null, requesting: [finding("Important")] }, {}],
      merges: [[cluster("a.js::bug", ["requesting#0"])], []],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.ok(result.report.startsWith("> **注意**"));
  assert.match(result.report.split("\n")[0], /ラウンド 1.*ecc/);
});

test("base との差分コミットが無ければ PR を作らないよう公開エージェントに指示する", async () => {
  const { calls } = await runWorkflow();
  const prompt = calls.find((c) => c.label === "publish").prompt;
  assert.match(prompt, /git rev-list --count origin\/main\.\.HEAD/);
});

test("PR の base は、指定が無ければ baseRef から origin/ を除いて導き、指定があればそれを使う", async () => {
  const derived = await runWorkflow();
  assert.match(
    derived.calls.find((c) => c.label === "publish").prompt,
    /gh pr create --draft --base main /,
  );

  const explicit = await runWorkflow({ args: { prBase: "release" } });
  assert.match(
    explicit.calls.find((c) => c.label === "publish").prompt,
    /gh pr create --draft --base release /,
  );
});

test("review-verify では実装も公開もせず、レビュー修正ループと動作確認だけを行う", async () => {
  const { result, labels } = await runWorkflow({
    args: { mode: "review-verify" },
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::bug", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed" }], observations: [] }],
    }),
  });
  assert.deepEqual(labels, [
    "checks:1",
    "review:ecc",
    "review:requesting",
    "merge",
    "fix:1",
    "checks:2",
    "review:ecc",
    "review:requesting",
    "verify:1",
  ]);
  assert.equal(result.published, false);
  assert.equal(result.publishError, null);
  assert.equal(result.prUrl, null);
  assert.equal(result.stopReason, null);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("review-verify の報告は先頭で mode を示し、PR 向けの末尾行を付けない", async () => {
  const { result } = await runWorkflow({ args: { mode: "review-verify" } });
  assert.match(result.report.split("\n")[0], /Review-Verify/);
  assert.doesNotMatch(result.report, /Generated with/);

  const deliver = await runWorkflow();
  assert.doesNotMatch(deliver.result.report.split("\n")[0], /Review-Verify/);
  assert.match(deliver.result.report, /Generated with/);
});

test("未知の mode は agent を呼ぶ前に throw する", async () => {
  // agent が先に呼ばれると、その throw は stopReason=error として捕まって resolve するので、rejects が落ちる。
  const respond = (label) => {
    throw new Error(`agent が呼ばれた: ${label}`);
  };
  await assert.rejects(runWorkflow({ args: { mode: "review" }, respond }), /mode/);
});

test("mode が無ければ、既定の deliver として走らず agent を呼ぶ前に throw する", async () => {
  const respond = (label) => {
    throw new Error(`agent が呼ばれた: ${label}`);
  };
  await assert.rejects(runWorkflow({ args: { mode: undefined }, respond }), /mode/);
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
  assert.equal(labels[0], "plan");
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 3);
  assert.ok(labels.includes("publish"));
});

test("review-verify でテスト/lint が通らなければ、レビューも動作確認もせずに停止し、公開しない", async () => {
  const { result, labels } = await runWorkflow({
    args: { mode: "review-verify" },
    respond: scenario({ checks: () => ({ passed: false, details: "lint 失敗" }) }),
  });
  assert.deepEqual(labels, ["checks:1"]);
  assert.equal(result.stopReason, "checks-failing");
  assert.equal(result.published, false);
  assert.equal(result.publishError, null);
  assert.match(section(result.report, "Unresolved Finding"), /未レビュー/);
});

test("review-verify で requirementsBreaking により停止しても、動作確認も公開もしない", async () => {
  const { result, labels } = await runWorkflow({
    args: { mode: "review-verify" },
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
  assert.ok(!labels.includes("publish"));
  assert.equal(result.published, false);
});

test("review-verify で動作確認が失敗したら、直した後にレビューし直してから再確認する", async () => {
  const { labels } = await runWorkflow({
    args: { mode: "review-verify" },
    respond: scenario({
      verifies: [
        { passed: false, summary: "画面が真っ白" },
        { passed: true, summary: "ok" },
      ],
    }),
  });
  assert.deepEqual(labels, [
    "checks:1",
    "review:ecc",
    "review:requesting",
    "verify:1",
    "fix-verify:1",
    "checks:2",
    "review:ecc",
    "review:requesting",
    "verify:2",
  ]);
});

test("review-verify では、要件文書のうちブランチが着手していない項目を実装させないよう、テスト/lint・レビュー・修正・動作確認の prompt で範囲を限る", async () => {
  const respond = () =>
    scenario({
      reviews: [{ requesting: [finding("Important")] }, {}],
      merges: [[cluster("a.js::scope", ["requesting#0"])]],
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

  const reviewVerify = await runWorkflow({ args: { mode: "review-verify" }, respond: respond() });
  for (const prompt of promptsOf(reviewVerify.calls)) {
    assert.match(prompt, /まだ着手していない/);
    // 範囲の制約を口実に、ブランチ自身の変更の不具合を見送らせない。
    assert.match(prompt, /不具合.*範囲外にしない/);
  }
  const call = (label) => reviewVerify.calls.find((c) => c.label.startsWith(label)).prompt;
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

  const deliver = await runWorkflow({ respond: respond() });
  for (const prompt of promptsOf(deliver.calls)) assert.doesNotMatch(prompt, /まだ着手していない/);
});

test("コードを編集する checks・fix・fix-verify の prompt は、どの mode でも要件文書の変更を禁じる", async () => {
  const respond = () =>
    scenario({
      reviews: [{ requesting: [finding("Important")] }, {}],
      merges: [[cluster("a.js::bug", ["requesting#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "fixed" }], observations: [] }],
      verifies: [
        { passed: false, summary: "画面が真っ白" },
        { passed: true, summary: "ok" },
      ],
    });
  for (const mode of ["deliver", "review-verify"]) {
    const { calls } = await runWorkflow({ args: { mode }, respond: respond() });
    for (const prefix of ["checks:", "fix:", "fix-verify:"]) {
      const call = calls.find((c) => c.label.startsWith(prefix));
      assert.ok(call, `${mode}: ${prefix} が呼ばれていない`);
      assert.ok(
        call.prompt.includes(`要件文書 ${BASE_ARGS.requirementsPath} は変更しない`),
        `${mode}: ${prefix} が要件文書の変更を禁じていない`,
      );
    }
  }
});

test("テスト/lint を通すために checks がコードを変えたら、通った場合も報告に残す", async () => {
  const { result } = await runWorkflow({
    args: { mode: "review-verify" },
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
    args: { mode: "review-verify" },
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

test("review-verify では、未着手の項目を範囲外とする規則が要件文書とのずれを直す指示より優先すると明示する", async () => {
  const { calls } = await runWorkflow({
    args: { mode: "review-verify" },
    respond: scenario({
      reviews: [{ requesting: [finding("Important")] }, {}],
      merges: [[cluster("a.js::bug", ["requesting#0"])]],
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
    args: { mode: "review-verify" },
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

test("mode と他の必須引数が同時に欠けていれば、1回の throw で両方を挙げる", async () => {
  await assert.rejects(
    runWorkflow({ args: { mode: undefined, requirementsPath: "" } }),
    /必須の引数がありません: requirementsPath, mode/,
  );
});
