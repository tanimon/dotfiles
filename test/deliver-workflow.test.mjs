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
  planPath: "/repo/docs/plans/p.md",
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
  planBreaking: false,
  members,
  ...extra,
});

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
    if (label.startsWith("fix-verify:")) return { fixed: true, summary: "fixed", observations: [] };
    if (label === "publish") return { pushed: true, prUrl: "https://example.invalid/pr/1" };
    throw new Error(`unexpected agent label: ${label}`);
  };
}

async function runWorkflow({ args = {}, respond = scenario() } = {}) {
  const calls = [];
  const agent = async (prompt, opts = {}) => {
    calls.push({ label: opts.label, prompt });
    return respond(opts.label, calls);
  };
  const parallel = (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)));
  const pipeline = async () => {
    throw new Error("deliver does not use pipeline()");
  };
  const budget = { total: null, spent: () => 1234, remaining: () => Infinity };
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

test("修正必須でない指摘は修正せず、参考指摘として報告する", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")], requesting: [finding("Minor")] }],
      merges: [[cluster("a.js::style", ["ecc#0", "requesting#0"])]],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 0);
  assert.match(section(result.report, "参考指摘(修正必須ではない)"), /issue a.js::style/);
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

test("Plan Concern は修正せずに報告し、planBreaking なら動作確認をせずに停止する", async () => {
  const concern = await runWorkflow({
    respond: scenario({
      reviews: [{ requesting: [finding("Important", { target: "plan" })] }],
      merges: [[cluster("plan::ambiguous", ["requesting#0"], { target: "plan" })]],
    }),
  });
  assert.equal(concern.labels.filter((l) => l.startsWith("fix:")).length, 0);
  assert.match(section(concern.result.report, "Plan Concern"), /issue plan::ambiguous/);
  assert.equal(concern.result.stopReason, null);

  const breaking = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("CRITICAL", { target: "plan", planBreaking: true })] }],
      merges: [[cluster("plan::broken", ["ecc#0"], { target: "plan", planBreaking: true })]],
    }),
  });
  assert.equal(breaking.result.stopReason, "plan-breaking");
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
      fixes: [{ results: [], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.equal(result.stopReason, null);
});

test("必須の引数が欠けていれば agent を呼ぶ前に throw する", async () => {
  await assert.rejects(runWorkflow({ args: { planPath: "" } }), /planPath/);
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

test("merge が code の修正必須指摘を plan の cluster に入れても、code 側は修正に回す", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")], requesting: [finding("Minor", { target: "plan" })] }, {}],
      merges: [[cluster("a.js::mixed", ["ecc#0", "requesting#0"], { target: "plan" })]],
      fixes: [{ results: [{ key: "a.js::mixed", action: "fixed", reason: "" }], observations: [] }],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 1);
  assert.match(section(result.report, "Plan Concern"), /issue a.js::mixed/);
});

test("merge の planBreaking 申告だけでは停止しない(元の指摘が planBreaking のときだけ止まる)", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ requesting: [finding("Minor", { target: "plan" })] }],
      merges: [[cluster("plan::x", ["requesting#0"], { target: "plan", planBreaking: true })]],
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

test("planBreaking で停止したラウンドの code 側の修正必須指摘も Unresolved に残す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [
        {
          ecc: [
            finding("CRITICAL", { target: "plan", planBreaking: true }),
            finding("HIGH", { file: "b.js" }),
          ],
        },
      ],
      merges: [
        [
          cluster("plan::broken", ["ecc#0"], { target: "plan", planBreaking: true }),
          cluster("b.js::bug", ["ecc#1"], { file: "b.js" }),
        ],
      ],
    }),
  });
  assert.equal(result.stopReason, "plan-breaking");
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
