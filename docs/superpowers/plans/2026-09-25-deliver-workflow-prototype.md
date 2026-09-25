# deliver ワークフロー試作 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** plan を受け取り、実装、レビュー修正ループ、動作確認、draft PR と報告までを自律実行する `deliver`(入口 skill と Workflow スクリプト)の最小実装を、前提2点の実測込みで作る。

**Architecture:** ループ・判定・報告の組み立ては `dot_claude/workflows/deliver.js`(Claude Code Workflows のスクリプト)がコードで行い、実作業はすべて `agent()` に任せる。人間への質問は Workflow の中ではできないので、入口 skill `dot_claude/skills/deliver/SKILL.md` が引数を集めてから Workflow を起動する。スクリプトの判定ロジックは、`agent()` を stub にした node:test で決定的にテストする。

**Tech Stack:** Claude Code Workflows(プレーン JS、ファイル・シェル・`Date.now()` は使えない)、node:test(Node 24、`.node-version`)、just、GitHub Actions、chezmoi。

**Spec:** `docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`(方式選定は `docs/adr/0007-deliver-workflow-enforces-review-loop-in-code.md`、用語は `CONTEXT.md` の「Autonomous delivery」節)

## Global Constraints

- 入力は plan だけ。plan 化はワークフローの範囲外。
- feature ブランチ上でだけ動く。`main` / `master` / `development`、または detached HEAD であれば、入口 skill が中止する。
- 修正必須: ecc の `CRITICAL`/`HIGH`、built-in の `CONFIRMED`、requesting の `Critical`/`Important`。
- 修正ラウンドの上限 `maxReviewRounds` は既定 3、動作確認の再挑戦の上限 `maxVerifyRetries` は既定 2。
- Deferred Finding は、実装の経緯を渡さない新しい検証エージェントが同意した場合だけ認める。
- 前ラウンドと同じ key の修正必須指摘は Unresolved Finding にし、以後の修正対象から外す。
- Plan Concern は修正しない。`planBreaking` の指摘があれば即停止する。
- 報告の順序: Unresolved Finding → Plan Concern → 動作確認の結果(失敗時は先頭へ)→ Deferred Finding → 参考指摘 → Observations → 統計。
- 外部(Notion、GitHub Issue)への起票はしない。push は force なし。PR は draft。
- ledger は `$(git rev-parse --git-dir)/deliver/ledger.json`(Task 1 の実測で書けなければ `~/.local/state/deliver/`)。
- workflow スクリプトの中で `Date.now()` / `Math.random()` / 引数なしの `new Date()` を使わない(使うと throw する)。
- 全コミットのメッセージ末尾に `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>` を付ける。
- ルート `CLAUDE.md`(生成物)は 40,000 文字未満に保つ(2026-09-24 の `/doctor` で 39,656 文字まで削った。大容量警告の閾値)。
- 新規ドキュメント・コメント・コミットメッセージは日本語。`CLAUDE.md` / `AGENTS.md` は生成物なので `harness/modules/` を編集して `just harness-sync` で再生成する。

## Review Focus

- **merge エージェントが存在しない member id を返す** — その id は無視し、クラッシュしない。member が1つも有効でない cluster は捨て、`log()` で知らせる(Task 2 の「未知の member id」テスト)。
- **Unresolved にした指摘が、次のラウンドでまた出る** — 二重に計上せず、修正対象にも戻さない(Task 2 の「再出現後の再々出現」テスト)。
- **3本のレビュアーが全員 null を返す** — 「指摘ゼロ」と誤判定して成功扱いにせず、停止理由を付けて報告する(Task 2 の「レビュアー全滅」テスト)。
- **動作確認に失敗し続ける** — 再挑戦の上限で止め、報告の先頭に失敗を出す(Task 2 の「動作確認失敗」テスト)。
- **必須の引数が欠けたまま Workflow が直接起動される** — 最初の agent を呼ぶ前に throw する(Task 2 の「引数検証」テスト)。

---

### Task 1: 前提2点の実測

Workflow のエージェントから Skill を読み込めるか、`.git` 配下に書き込めるかを実測し、spec の表に記録する。以降のタスクのプロンプト方式と ledger の置き場所は、この結果で決まる。

**Files:**
- Modify: `docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`(「試作で実測すること」の表)

**Interfaces:**
- Produces: 実測結果。`SKILL_MODE`(`skill` = Skill ツールで読み込める / `read` = 読み込めない)と `LEDGER_DIR`(`git-dir` / `state`)。

- [ ] **Step 1: Skill の読み込みと書き込みを試す Workflow を実行する**

**この Task は main セッションで実行する**(サブエージェントからは Workflow を呼べるか未確認で、opt-in も伝わらない)。実行前に、ユーザーから「この spike の Workflow を実行してよい」という明示的な依頼を得る(plan の承認は Workflow の opt-in にならない)。得たら、Workflow ツールに次のスクリプトを inline で渡して実行する。`args` は `{ selfRepo: "<この worktree の絶対パス>", workRepo: "<仕事リポジトリの worktree の絶対パス>" }` の形のオブジェクトで渡す(例: `~/ghq/github.com/<work-org>/` 配下の、ma_store などの worktree)。

```js
export const meta = {
  name: "deliver-spike",
  description: "Workflow エージェント内で Skill を読み込めるか、git-dir に書き込めるかを実測する",
  phases: [{ title: "Probe" }],
};

const SKILL_PROBE = {
  type: "object",
  properties: {
    skillToolAvailable: { type: "boolean" },
    results: {
      type: "array",
      items: {
        type: "object",
        properties: {
          skill: { type: "string" },
          loaded: { type: "boolean" },
          firstLine: { type: "string" },
          error: { type: "string" },
        },
        required: ["skill", "loaded"],
      },
    },
  },
  required: ["skillToolAvailable", "results"],
};

const WRITE_PROBE = {
  type: "object",
  properties: {
    gitDir: { type: "string" },
    writable: { type: "boolean" },
    error: { type: "string" },
  },
  required: ["gitDir", "writable"],
};

const skills = await agent(
  "あなたのツール一覧に Skill ツールがあるか確認し、あれば次の3つをそれぞれ Skill ツールで読み込め: 「ecc-code-review」「code-review」「superpowers:requesting-code-review」。読み込むだけで、手順は実行しない。各 skill について、読み込めたか、読み込んだ本文の最初の1行、エラーがあればその全文を返せ。",
  { label: "probe:skill", phase: "Probe", schema: SKILL_PROBE },
);

const writePrompt = (dir) =>
  `ディレクトリ ${dir} で「git rev-parse --absolute-git-dir」を実行し、その出力を D とする。「mkdir -p D/deliver && printf ok > D/deliver/probe && cat D/deliver/probe && rm D/deliver/probe && rmdir D/deliver」を実行し、成功したかを返せ。失敗したらエラー出力の全文を error に入れよ。dangerouslyDisableSandbox は使わない。`;

const writes = await parallel(
  [args.selfRepo, args.workRepo].map(
    (dir, i) => () =>
      agent(writePrompt(dir), { label: `probe:write:${i}`, phase: "Probe", schema: WRITE_PROBE }),
  ),
);

return { skills, writes };
```

期待: 返り値に `skills.results` の3件と `writes` の2件が入っている。

- [ ] **Step 2: 結果を判定する**

- `SKILL_MODE`: 3件すべてが `loaded: true` なら `skill`。1件でも false なら `read`(Task 2 の Step 3 で、`REVIEWERS` の `instruction` を「定義ファイルを Read せよ」という形に差し替える。built-in の `code-review` は定義ファイルが無いので、`read` モードでは `REVIEWERS` から外し、spec にその旨を書く)。
- `LEDGER_DIR`: 2件とも `writable: true` なら `git-dir`。どちらかが false なら `state`(Task 2 の `publishPrompt` の保存先を `~/.local/state/deliver/<repo名>/<branch名>/` に差し替える)。

- [ ] **Step 3: spec の表に記録する**

`docs/superpowers/specs/2026-09-25-deliver-workflow-design.md` の「試作で実測すること」の表で、「(試作 Task 1 で記入)」の2か所を実測結果に置き換える。書くのは日付(2026-09-25)、各 skill の `loaded` と `error`、各リポジトリの `writable` と `error`、判定(`SKILL_MODE` / `LEDGER_DIR`)。

- [ ] **Step 4: ADR の status を更新する**

`SKILL_MODE` が `skill` であれば、`docs/adr/0007-deliver-workflow-enforces-review-loop-in-code.md` の frontmatter の `status: proposed` を `status: accepted` に変え、Consequences の「サブエージェント内で Skill … 未確認」の項目を実測結果の1文に書き換える。`read` であれば status は `proposed` のまま残し、その項目に「読み込めなかった。定義ファイルを Read させる方式に切り替えた」と書く。

- [ ] **Step 5: コミットする**

```bash
git add CONTEXT.md docs/adr/0007-deliver-workflow-enforces-review-loop-in-code.md docs/superpowers/specs/2026-09-25-deliver-workflow-design.md docs/superpowers/plans/2026-09-25-deliver-workflow-prototype.md
git commit -m "docs(deliver): 自律実装フローの設計・ADR・用語と前提の実測結果を記録する"
```

---

### Task 2: Workflow スクリプトと判定ロジックのテスト

**Files:**
- Create: `test/deliver-workflow.test.mjs`
- Create: `dot_claude/workflows/deliver.js`
- Modify: `justfile`(`test-deliver` レシピを追加し、`lint` の依存に加える)
- Modify: `.github/workflows/lint.yml`(`test-deliver` ジョブを追加する)

**Interfaces:**
- Consumes: Task 1 の `SKILL_MODE` / `LEDGER_DIR`
- Produces: Workflow の `args` の契約(入口 skill が組み立てる)

```
{
  planPath: string,            // 必須。plan ファイルの絶対パス
  baseRef: string,             // 必須。差分の基点(例: "origin/main")
  checkCommands: string[],     // 必須。1件以上
  verifySkill: string,         // 必須。skill 名、または "none"
  maxReviewRounds?: number,    // 既定 3
  maxVerifyRetries?: number,   // 既定 2
  prBase?: string,             // 既定は baseRef から "origin/" を除いたもの
}
```

返り値: `{ prUrl: string|null, published: boolean, stopReason: string|null, report: string }`

agent の label(テストはこれで応答を切り替える): `plan`、`implement:<n>`、`checks:<round>`、`review:ecc` / `review:builtin` / `review:requesting`、`merge`、`fix:<round>`、`defer-verify:<key>`、`verify:<n>`、`fix-verify:<n>`、`publish`

- [ ] **Step 1: 失敗するテストを書く**

`test/deliver-workflow.test.mjs`:

```js
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
  const run = new AsyncFunction("agent", "parallel", "pipeline", "phase", "log", "args", "budget", body);
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
    "review:builtin",
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
      reviews: [{ ecc: [finding("MEDIUM")], builtin: [finding("PLAUSIBLE")] }],
      merges: [[cluster("a.js::style", ["ecc#0", "builtin#0"])]],
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
      fixes: keys.map((k) => ({ results: [{ key: k, action: "fixed", reason: "" }], observations: [] })),
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
      merges: [[cluster("a.js::scope", ["requesting#0"])], [cluster("a.js::scope", ["requesting#0"])]],
      fixes: [
        { results: [{ key: "a.js::scope", action: "propose-defer", reason: "plan の範囲外" }], observations: [] },
      ],
      verdicts: { "a.js::scope": { agree: true, reason: "plan のタスク外" } },
    }),
  });
  assert.ok(labels.includes("defer-verify:a.js::scope"));
  assert.match(section(result.report, "Deferred Finding"), /plan の範囲外.*plan のタスク外/);
  assert.match(section(result.report, "Unresolved Finding"), /なし/);
});

test("検証者が同意しなかった見送りは修正必須に戻り、再出現で Unresolved になる", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      reviews: [{ builtin: [finding("CONFIRMED")] }, { builtin: [finding("CONFIRMED")] }],
      merges: [[cluster("a.js::bug", ["builtin#0"])], [cluster("a.js::bug", ["builtin#0"])]],
      fixes: [{ results: [{ key: "a.js::bug", action: "propose-defer", reason: "面倒" }], observations: [] }],
      verdicts: { "a.js::bug": { agree: false, reason: "実バグ" } },
    }),
  });
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
    respond: scenario({ reviews: [{ ecc: null, builtin: null, requesting: null }] }),
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

test("merge が未知の member id を返してもクラッシュせず、その cluster を捨てる", async () => {
  const { result, labels } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("HIGH")] }],
      merges: [[cluster("ghost", ["nope#9"])]],
    }),
  });
  assert.equal(labels.filter((l) => l.startsWith("fix:")).length, 0);
  assert.equal(result.stopReason, null);
});

test("必須の引数が欠けていれば agent を呼ぶ前に throw する", async () => {
  await assert.rejects(runWorkflow({ args: { planPath: "" } }), /planPath/);
  await assert.rejects(runWorkflow({ args: { checkCommands: [] } }), /checkCommands/);
});

test("observations を報告にまとめる", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      implement: () => ({ status: "done", commit: "abc", observations: ["README が古い"] }),
    }),
  });
  assert.match(section(result.report, "Observations"), /implement:1: README が古い/);
});
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `node --test test/deliver-workflow.test.mjs`
Expected: FAIL(`ENOENT: no such file or directory ... dot_claude/workflows/deliver.js`)

- [ ] **Step 3: スクリプトを実装する**

`dot_claude/workflows/deliver.js`(Task 1 で `SKILL_MODE` が `read` だった場合は、`REVIEWERS` と `reviewPrompt` を Task 1 Step 2 のとおりに差し替える。`LEDGER_DIR` が `state` だった場合は、`publishPrompt` の保存先を差し替える):

```js
export const meta = {
  name: "deliver",
  description: "plan を実装し、レビュー修正ループと動作確認を経て draft PR と人間への報告を作る",
  whenToUse: "入口 skill /deliver から起動する。直接起動しない",
  phases: [
    { title: "Plan" },
    { title: "Implement" },
    { title: "Review" },
    { title: "Verify" },
    { title: "Publish" },
  ],
};

// 判定はここに置いたコードで行い、agent にはさせない(ADR 0007)。
const DEFAULTS = { maxReviewRounds: 3, maxVerifyRetries: 2 };
const BUDGET_FLOOR = 100000;

const REVIEWERS = [
  {
    id: "ecc",
    skill: "ecc-code-review",
    severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW"],
    blocking: ["CRITICAL", "HIGH"],
  },
  {
    id: "builtin",
    skill: "code-review",
    skillArgs: "high",
    severities: ["CONFIRMED", "PLAUSIBLE"],
    blocking: ["CONFIRMED"],
  },
  {
    id: "requesting",
    skill: "superpowers:requesting-code-review",
    severities: ["Critical", "Important", "Minor"],
    blocking: ["Critical", "Important"],
  },
];

const STOP_REASONS = {
  "plan-unreadable": "plan からタスクを抽出できなかった",
  "implement-blocked": "実装タスクが続行不能になった",
  "checks-failing": "テスト/lint が通らないままになった",
  "reviewers-failed": "レビュアーが全員結果を返さなかった",
  "merge-failed": "指摘の統合に失敗した",
  "fixer-failed": "修正エージェントが結果を返さなかった",
  "plan-breaking": "plan どおりに作ると壊れる Plan Concern が出た",
  budget: "トークン予算の残りが少ないため、次のラウンドに入らなかった",
};

const STRINGS = { type: "array", items: { type: "string" } };

const PLAN_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    tasks: {
      type: "array",
      items: {
        type: "object",
        properties: { title: { type: "string" }, summary: { type: "string" } },
        required: ["title", "summary"],
      },
    },
  },
  required: ["title", "tasks"],
};

const IMPLEMENT_SCHEMA = {
  type: "object",
  properties: {
    status: { type: "string", enum: ["done", "blocked"] },
    reason: { type: "string" },
    commit: { type: "string" },
    observations: STRINGS,
  },
  required: ["status"],
};

const CHECKS_SCHEMA = {
  type: "object",
  properties: { passed: { type: "boolean" }, details: { type: "string" }, observations: STRINGS },
  required: ["passed"],
};

const reviewSchema = (reviewer) => ({
  type: "object",
  properties: {
    findings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          file: { type: "string" },
          line: { type: "integer" },
          summary: { type: "string" },
          severity: { type: "string", enum: reviewer.severities },
          target: { type: "string", enum: ["code", "plan"] },
          planBreaking: { type: "boolean" },
        },
        required: ["file", "summary", "severity", "target"],
      },
    },
    observations: STRINGS,
  },
  required: ["findings"],
});

const MERGE_SCHEMA = {
  type: "object",
  properties: {
    clusters: {
      type: "array",
      items: {
        type: "object",
        properties: {
          key: { type: "string" },
          file: { type: "string" },
          line: { type: "integer" },
          summary: { type: "string" },
          target: { type: "string", enum: ["code", "plan"] },
          planBreaking: { type: "boolean" },
          members: STRINGS,
        },
        required: ["key", "file", "summary", "target", "members"],
      },
    },
  },
  required: ["clusters"],
};

const FIX_SCHEMA = {
  type: "object",
  properties: {
    results: {
      type: "array",
      items: {
        type: "object",
        properties: {
          key: { type: "string" },
          action: { type: "string", enum: ["fixed", "propose-defer"] },
          reason: { type: "string" },
        },
        required: ["key", "action"],
      },
    },
    observations: STRINGS,
  },
  required: ["results"],
};

const VERDICT_SCHEMA = {
  type: "object",
  properties: { agree: { type: "boolean" }, reason: { type: "string" } },
  required: ["agree", "reason"],
};

const VERIFY_SCHEMA = {
  type: "object",
  properties: { passed: { type: "boolean" }, summary: { type: "string" }, observations: STRINGS },
  required: ["passed", "summary"],
};

const FIX_VERIFY_SCHEMA = {
  type: "object",
  properties: { fixed: { type: "boolean" }, summary: { type: "string" }, observations: STRINGS },
  required: ["fixed", "summary"],
};

const PUBLISH_SCHEMA = {
  type: "object",
  properties: {
    pushed: { type: "boolean" },
    prUrl: { type: "string" },
    ledgerPath: { type: "string" },
    error: { type: "string" },
  },
  required: ["pushed"],
};

function validateArgs(input) {
  const a = input || {};
  const missing = [];
  if (typeof a.planPath !== "string" || a.planPath === "") missing.push("planPath");
  if (typeof a.baseRef !== "string" || a.baseRef === "") missing.push("baseRef");
  if (!Array.isArray(a.checkCommands) || a.checkCommands.length === 0) missing.push("checkCommands");
  if (typeof a.verifySkill !== "string" || a.verifySkill === "") missing.push("verifySkill");
  if (missing.length > 0) {
    throw new Error(`deliver: 必須の引数がありません: ${missing.join(", ")}(入口 skill /deliver から起動してください)`);
  }
  const config = { ...DEFAULTS, ...a };
  if (!config.prBase) config.prBase = config.baseRef.replace(/^origin\//, "");
  return config;
}

function newState(config) {
  return {
    config,
    title: "",
    rounds: [],
    unresolved: [],
    unresolvedKeys: new Set(),
    deferred: [],
    deferredKeys: new Set(),
    planConcerns: [],
    advisory: [],
    knownClusters: [],
    verification: [],
    observations: [],
    reviewerFailures: [],
    stopReason: null,
    stopDetail: "",
    outputTokens: 0,
  };
}

function collectObservations(state, source, result) {
  if (!result || !Array.isArray(result.observations)) return;
  for (const o of result.observations) state.observations.push(`${source}: ${o}`);
}

function isBlocking(finding) {
  const reviewer = REVIEWERS.find((r) => r.id === finding.reviewer);
  return Boolean(reviewer && reviewer.blocking.includes(finding.severity));
}

// closedKeys(Deferred / Unresolved 済み)の cluster は、再び出ても扱わない。
function classifyRound(clusters, findingsById, previousBlockingKeys, closedKeys) {
  const out = { blocking: [], repeated: [], planConcerns: [], planBreaking: [], advisory: [], dropped: [] };
  for (const c of clusters) {
    const members = c.members.map((id) => findingsById[id]).filter(Boolean);
    if (members.length === 0) {
      out.dropped.push(c.key);
      continue;
    }
    if (closedKeys.has(c.key)) continue;
    const item = {
      key: c.key,
      file: c.file,
      line: c.line,
      summary: c.summary,
      severities: members.map((m) => `${m.reviewer}:${m.severity}`),
    };
    if (c.target === "plan") {
      out.planConcerns.push(item);
      if (c.planBreaking || members.some((m) => m.planBreaking)) out.planBreaking.push(item);
      continue;
    }
    if (!members.some(isBlocking)) out.advisory.push(item);
    else if (previousBlockingKeys.has(c.key)) out.repeated.push(item);
    else out.blocking.push(item);
  }
  return out;
}

function uniqueByKey(items) {
  const seen = new Set();
  return items.filter((i) => (seen.has(i.key) ? false : (seen.add(i.key), true)));
}

function markUnresolved(state, items) {
  for (const item of items) {
    if (state.unresolvedKeys.has(item.key)) continue;
    state.unresolvedKeys.add(item.key);
    state.unresolved.push(item);
  }
}

const commands = (config) => config.checkCommands.map((c) => `「${c}」`).join("、");

function planPrompt(config) {
  return `plan ファイル ${config.planPath} を読み、実装タスクの一覧を抽出せよ。
- plan の順序どおりに、plan の1タスクを1要素とする。独自に分割・統合しない。
- title は、この plan 全体を表す PR タイトルとして使える短い日本語にする。
- plan が実装計画でない(タスク分解が無い)なら、tasks を空配列で返す。`;
}

function implementPrompt(task, index, total, config) {
  return `plan ${config.planPath} のタスク ${index + 1}/${total}「${task.title}」を実装せよ。plan を読み、このタスクの範囲だけを実装する。
- TDD で進める。失敗するテストを先に書き、失敗を確認してから実装する。
- 完了する前に、次のコマンドを全て実行して全て成功させる: ${commands(config)}
- 完了したら変更をコミットする(push はしない)。コミットメッセージはリポジトリの既存の規約に従う。
- plan どおりに進められない(前提が崩れている、plan が矛盾している)場合は、推測で埋めずに status="blocked" と理由を返す。
- タスクの範囲外で気づいた問題は observations に書く(直さない)。`;
}

function checksPrompt(config) {
  return `次のコマンドを全て実行せよ: ${commands(config)}
- 失敗があれば原因を直してコミットし(push はしない)、全て成功するまで繰り返す。
- テストを消す・スキップする・lint を無効化するなど、検査そのものを弱める変更はしない。
- 3回試しても直らなければ、passed=false と失敗内容を返す。`;
}

function reviewPrompt(reviewer, config) {
  const skillArgs = reviewer.skillArgs ? `(引数「${reviewer.skillArgs}」)` : "";
  return `Skill ツールで「${reviewer.skill}」${skillArgs}を読み込み、その手順に従って「${config.baseRef}...HEAD」の差分をレビューせよ。
- 要件は plan ${config.planPath}。plan とのずれも指摘の対象にする。
- ファイルの修正、コミット、PR へのコメント投稿、ReportFindings ツールの呼び出しはしない。結果は StructuredOutput だけで返す。
- severity には skill 自身の尺度をそのまま使う: ${reviewer.severities.join(" / ")}
- 指摘が実装ではなく plan そのものに向く場合は target="plan" とし、plan どおりに作ると壊れる場合だけ planBreaking=true にする。
- レビューの範囲外で気づいた問題は observations に書く。`;
}

function mergePrompt(findings, knownClusters) {
  return `複数のレビュアーの指摘を統合せよ。指摘(JSON): ${JSON.stringify(findings)}
- 同じ問題を指す指摘は1つの cluster にまとめ、members に元の id を全て入れる。どの指摘も必ずちょうど1つの cluster に入れる。
- key は「ファイルパス::問題の種類を表す英小文字の短いスラッグ」とする(例: src/a.ts::missing-null-check)。
- 過去のラウンドに同じ問題があれば、その key をそのまま使う。過去の cluster(JSON): ${JSON.stringify(knownClusters)}
- target は、members のいずれかが "plan" なら "plan"、それ以外は "code"。planBreaking は、members のいずれかが true なら true。
- summary は日本語の1文で書く。`;
}

function fixPrompt(items, config) {
  return `次の修正必須の指摘に対応せよ。plan は ${config.planPath}、対象の差分は「${config.baseRef}...HEAD」。
指摘(JSON): ${JSON.stringify(items)}
- 指摘ごとに、修正したら action="fixed"、修正すべきでない(偽陽性、または plan の範囲外)と判断したら action="propose-defer" と具体的な理由を返す。直すのが大変だという理由では見送らない。
- 修正した後、次のコマンドを全て成功させる: ${commands(config)}
- 修正をまとめて1コミットにする(push はしない)。
- 指摘の範囲外で気づいた問題は observations に書く。`;
}

function deferPrompt(item, reason, config) {
  return `あなたは独立した検証者である。実装者は、次の指摘を修正せずに見送ることを提案している。
指摘(JSON): ${JSON.stringify(item)}
実装者の理由: ${reason}
plan は ${config.planPath}、差分は「${config.baseRef}...HEAD」。コードと plan を自分で読み、見送りが妥当か判断せよ。妥当なのは、指摘が偽陽性であるか、plan の範囲外である場合だけ。判断に迷うなら agree=false とする。`;
}

function verifyPrompt(config) {
  return `Skill ツールで「${config.verifySkill}」を読み込み、その手順に従って、plan ${config.planPath} の変更が意図どおりに動くことを確認せよ。
- 確認した操作と観察した結果を summary に書き、意図どおりに動けば passed=true にする。
- コードは修正しない。範囲外で気づいた問題は observations に書く。`;
}

function fixVerifyPrompt(result, config) {
  return `動作確認が失敗した。結果(JSON): ${JSON.stringify(result)}
plan は ${config.planPath}。原因を調べて直し、次のコマンドを全て成功させてから1コミットにせよ(push はしない): ${commands(config)}`;
}

function ledgerJson(state) {
  return JSON.stringify(
    { ...state, unresolvedKeys: [...state.unresolvedKeys], deferredKeys: [...state.deferredKeys] },
    null,
    2,
  );
}

function publishPrompt(state, report) {
  return `次の手順で公開せよ。
1. 「git rev-parse --absolute-git-dir」の出力を D とする。D/deliver/ を作り、下の REPORT を D/deliver/pr-body.md に、下の LEDGER を D/deliver/ledger.json に、そのまま書き出す。
2. 現在のブランチを push する(force push はしない)。
3. このブランチの PR が無ければ「gh pr create --draft --base ${state.config.prBase} --title <TITLE> --body-file D/deliver/pr-body.md」で作る。既にあれば「gh pr edit --body-file D/deliver/pr-body.md」で本文を更新する。
4. PR の URL と ledger の絶対パスを返す。どこかで失敗したら pushed=false と error を返す。

TITLE: ${state.title || "deliver"}

REPORT:
<<<REPORT
${report}
REPORT

LEDGER:
<<<LEDGER
${ledgerJson(state)}
LEDGER`;
}

function formatItem(item) {
  const location = item.line ? `${item.file}:${item.line}` : item.file;
  return `\`${location}\` ${item.summary} [${item.severities.join(", ")}]`;
}

function renderReport(state) {
  const lines = [];
  const pushSection = (title, items, format) => {
    lines.push(`## ${title}`, "");
    if (items.length === 0) lines.push("なし");
    else for (const item of items) lines.push(`- ${format(item)}`);
    lines.push("");
  };
  const pushVerification = () => {
    lines.push("## 動作確認", "");
    if (state.config.verifySkill === "none") lines.push("指定なし(テスト/lint のみ)");
    else if (state.verification.length === 0) lines.push("未実施(停止したため)");
    else
      state.verification.forEach((v, i) =>
        lines.push(`- 試行 ${i + 1}: ${v.passed ? "成功" : "失敗"} — ${v.summary}`),
      );
    lines.push("");
  };
  const last = state.verification[state.verification.length - 1];
  const verificationFailed = Boolean(last && !last.passed);

  if (state.stopReason) {
    const detail = state.stopDetail ? `(${state.stopDetail})` : "";
    lines.push(`> **停止**: ${STOP_REASONS[state.stopReason]}${detail}`, "");
  }
  if (verificationFailed) pushVerification();
  pushSection("Unresolved Finding", uniqueByKey(state.unresolved), formatItem);
  pushSection("Plan Concern", uniqueByKey(state.planConcerns), formatItem);
  if (!verificationFailed) pushVerification();
  pushSection(
    "Deferred Finding",
    state.deferred,
    (d) => `${formatItem(d)} — 見送り理由: ${d.reason} / 検証者: ${d.verifierReason}`,
  );
  pushSection("参考指摘(修正必須ではない)", uniqueByKey(state.advisory), formatItem);
  pushSection("Observations", state.observations, (o) => o);

  lines.push("## 統計", "");
  lines.push(`- レビューラウンド: ${state.rounds.length}`);
  for (const r of state.rounds) {
    lines.push(`  - ラウンド ${r.round}: 修正必須 ${r.blocking} / 再出現 ${r.repeated} / 参考 ${r.advisory}`);
  }
  if (state.reviewerFailures.length > 0) lines.push(`- 結果を返さなかったレビュアー: ${state.reviewerFailures.join(", ")}`);
  lines.push(`- 出力トークン: ${state.outputTokens}`, "");
  lines.push("🤖 Generated with [Claude Code](https://claude.com/claude-code)");
  return lines.join("\n");
}

async function implement(state) {
  const { config } = state;
  phase("Plan");
  const parsed = await agent(planPrompt(config), { label: "plan", phase: "Plan", schema: PLAN_SCHEMA });
  if (!parsed || parsed.tasks.length === 0) {
    state.stopReason = "plan-unreadable";
    return;
  }
  state.title = parsed.title;
  phase("Implement");
  for (let i = 0; i < parsed.tasks.length; i++) {
    const task = parsed.tasks[i];
    const label = `implement:${i + 1}`;
    const result = await agent(implementPrompt(task, i, parsed.tasks.length, config), {
      label,
      phase: "Implement",
      schema: IMPLEMENT_SCHEMA,
    });
    collectObservations(state, label, result);
    if (!result || result.status !== "done") {
      state.stopReason = "implement-blocked";
      state.stopDetail = `タスク ${i + 1}「${task.title}」: ${result ? result.reason || "理由なし" : "エージェントが結果を返さなかった"}`;
      return;
    }
  }
}

async function runChecks(state, roundNo) {
  const label = `checks:${roundNo}`;
  const result = await agent(checksPrompt(state.config), { label, phase: "Review", schema: CHECKS_SCHEMA });
  collectObservations(state, label, result);
  if (result && result.passed) return true;
  state.stopReason = "checks-failing";
  state.stopDetail = result ? result.details || "" : "エージェントが結果を返さなかった";
  return false;
}

async function runReviewers(state, roundNo) {
  const results = await parallel(
    REVIEWERS.map(
      (r) => () =>
        agent(reviewPrompt(r, state.config), { label: `review:${r.id}`, phase: "Review", schema: reviewSchema(r) }),
    ),
  );
  const findings = [];
  results.forEach((result, i) => {
    const reviewer = REVIEWERS[i];
    if (!result) {
      state.reviewerFailures.push(`${reviewer.id}(ラウンド ${roundNo})`);
      return;
    }
    collectObservations(state, `review:${reviewer.id}`, result);
    result.findings.forEach((f, j) => findings.push({ ...f, reviewer: reviewer.id, id: `${reviewer.id}#${j}` }));
  });
  if (results.every((r) => !r)) {
    state.stopReason = "reviewers-failed";
    return null;
  }
  return findings;
}

async function mergeFindings(state, findings) {
  if (findings.length === 0) return [];
  const result = await agent(mergePrompt(findings, state.knownClusters), {
    label: "merge",
    phase: "Review",
    schema: MERGE_SCHEMA,
  });
  if (!result) {
    state.stopReason = "merge-failed";
    return null;
  }
  for (const c of result.clusters) {
    if (!state.knownClusters.some((k) => k.key === c.key)) state.knownClusters.push({ key: c.key, summary: c.summary });
  }
  return result.clusters;
}

async function runFix(state, roundNo, blocking) {
  const label = `fix:${roundNo}`;
  const fix = await agent(fixPrompt(blocking, state.config), { label, phase: "Review", schema: FIX_SCHEMA });
  if (!fix) {
    markUnresolved(state, blocking);
    state.stopReason = "fixer-failed";
    return;
  }
  collectObservations(state, label, fix);
  const byKey = Object.fromEntries(blocking.map((b) => [b.key, b]));
  const proposals = fix.results.filter((r) => r.action === "propose-defer" && byKey[r.key]);
  const verdicts = await parallel(
    proposals.map(
      (p) => () =>
        agent(deferPrompt(byKey[p.key], p.reason || "", state.config), {
          label: `defer-verify:${p.key}`,
          phase: "Review",
          schema: VERDICT_SCHEMA,
        }).then((verdict) => ({ proposal: p, verdict })),
    ),
  );
  for (const v of verdicts) {
    if (!v || !v.verdict || !v.verdict.agree) continue;
    state.deferred.push({ ...byKey[v.proposal.key], reason: v.proposal.reason || "", verifierReason: v.verdict.reason });
    state.deferredKeys.add(v.proposal.key);
  }
}

async function reviewLoop(state) {
  let previousBlockingKeys = new Set();
  for (let fixRound = 0; ; fixRound++) {
    if (budget.total && budget.remaining() < BUDGET_FLOOR) {
      state.stopReason = "budget";
      return;
    }
    const roundNo = state.rounds.length + 1;
    phase("Review");
    if (!(await runChecks(state, roundNo))) return;
    const findings = await runReviewers(state, roundNo);
    if (findings === null) return;
    const clusters = await mergeFindings(state, findings);
    if (clusters === null) return;
    const byId = Object.fromEntries(findings.map((f) => [f.id, f]));
    const closedKeys = new Set([...state.deferredKeys, ...state.unresolvedKeys]);
    const result = classifyRound(clusters, byId, previousBlockingKeys, closedKeys);
    if (result.dropped.length > 0) log(`有効な指摘を含まない cluster を捨てた: ${result.dropped.join(", ")}`);
    state.rounds.push({
      round: roundNo,
      blocking: result.blocking.length,
      repeated: result.repeated.length,
      advisory: result.advisory.length,
    });
    markUnresolved(state, result.repeated);
    state.advisory.push(...result.advisory);
    state.planConcerns.push(...result.planConcerns);
    if (result.planBreaking.length > 0) {
      state.stopReason = "plan-breaking";
      return;
    }
    if (result.blocking.length === 0) return;
    if (fixRound >= state.config.maxReviewRounds) {
      log(`修正ラウンドの上限 ${state.config.maxReviewRounds} に達した。残り ${result.blocking.length} 件を Unresolved にする`);
      markUnresolved(state, result.blocking);
      return;
    }
    await runFix(state, roundNo, result.blocking);
    if (state.stopReason) return;
    previousBlockingKeys = new Set(result.blocking.map((b) => b.key));
  }
}

async function verify(state) {
  const { config } = state;
  if (config.verifySkill === "none") return;
  for (let attempt = 1; ; attempt++) {
    phase("Verify");
    const label = `verify:${attempt}`;
    const result = await agent(verifyPrompt(config), { label, phase: "Verify", schema: VERIFY_SCHEMA });
    collectObservations(state, label, result);
    state.verification.push(result || { passed: false, summary: "動作確認エージェントが結果を返さなかった" });
    if (result && result.passed) return;
    if (attempt > config.maxVerifyRetries) return;
    const fixLabel = `fix-verify:${attempt}`;
    const fix = await agent(fixVerifyPrompt(result, config), { label: fixLabel, phase: "Verify", schema: FIX_VERIFY_SCHEMA });
    collectObservations(state, fixLabel, fix);
    await reviewLoop(state);
    if (state.stopReason) return;
  }
}

async function publish(state, report) {
  phase("Publish");
  return agent(publishPrompt(state, report), { label: "publish", phase: "Publish", schema: PUBLISH_SCHEMA });
}

const config = validateArgs(args);
const state = newState(config);
await implement(state);
if (!state.stopReason) await reviewLoop(state);
if (!state.stopReason) await verify(state);
state.outputTokens = budget.spent();
const report = renderReport(state);
const published = await publish(state, report);
return {
  prUrl: published && published.prUrl ? published.prUrl : null,
  published: Boolean(published && published.pushed),
  stopReason: state.stopReason,
  report,
};
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `node --test test/deliver-workflow.test.mjs`
Expected: PASS(18 tests, 0 fail)

失敗したテストがあれば、テストではなくスクリプトの側を直す。どちらが spec(`docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`)に沿っているかで判断する。

- [ ] **Step 5: just のレシピと CI のジョブを追加する**

`justfile` の `lint:` 行の末尾に ` test-deliver` を足し、`@test-pr-context:` レシピの直後に次を追加する:

```just
# deliver ワークフローの判定ロジックを、agent を stub にして検証する
@test-deliver:
    node --test test/deliver-workflow.test.mjs
```

`.github/workflows/lint.yml` の `test-pr-context:` ジョブの直後に次を追加する(アクションの SHA は既存ジョブと同じものを使う):

```yaml
  test-deliver:
    name: deliver workflow tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just test-deliver
```

- [ ] **Step 6: 整形して lint を通す**

Run: `pnpm exec oxfmt dot_claude/workflows/deliver.js test/deliver-workflow.test.mjs && just test-deliver oxlint oxfmt actionlint zizmor`
Expected: すべて成功する。oxfmt が行を折り返した後も、テストが PASS のままであること。

- [ ] **Step 7: chezmoi の配置先を確認する**

Run: `chezmoi managed --source "$(pwd)" | grep -E 'workflows/deliver.js|skills/deliver'`
Expected: `.claude/workflows/deliver.js` が出力される(`skills/deliver` は Task 3 の後に出る)。出なければ `.chezmoiignore` を確認する。

- [ ] **Step 8: コミットする**

```bash
git add dot_claude/workflows/deliver.js test/deliver-workflow.test.mjs justfile .github/workflows/lint.yml
git commit -m "feat(deliver): レビュー修正ループと報告をコードで判定する Workflow スクリプトを追加する"
```

---

### Task 3: 入口 skill

**Files:**
- Create: `dot_claude/skills/deliver/SKILL.md`

**Interfaces:**
- Consumes: Task 2 の `args` の契約。配置先 `~/.claude/workflows/deliver.js`
- Produces: `/deliver <plan-path> [verify=<skill|none>] [rounds=<n>] [base=<ref>]`

- [ ] **Step 1: SKILL.md を書く**

`dot_claude/skills/deliver/SKILL.md`:

````markdown
---
name: deliver
description: 実装計画(plan)を受け取り、実装 → レビュー修正ループ(上限付き)→ 動作確認 → draft PR と人間への報告までを自律実行する。「この plan を実装して PR まで」「plan を渡すので自律で仕上げて」「/deliver」など、分解済みの plan を人手を挟まずに PR まで持っていきたいときに使う。spec や PRD しか無い(タスク分解の無い)入力、main などの保護ブランチ上での作業、一歩ずつ人間がレビューしたい作業には使わない。
---

# deliver

`~/.claude/workflows/deliver.js` を起動する前に、Workflow の中ではできない確認と質問をすべて済ませる。Workflow は実行中に質問できないので、ここで欠けた引数は後から補えない。設計は chezmoi リポジトリの `docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`。

## 手順

1. **ブランチを検査する。** `git rev-parse --abbrev-ref HEAD` が `main` / `master` / `development` / `HEAD`(detached)であれば、理由を伝えて**中止する**。worktree やブランチは作らない。`git status --porcelain` が空でなければ、未コミットの変更があることを伝えて中止する(実装エージェントのコミットに混ざるため)。
2. **plan を確認する。** 引数の plan パスを絶対パスにし、ファイルが存在してタスク分解(見出しやチェックボックスで区切られたタスク)を含むことを確認する。spec や PRD しか無い場合は中止し、先に plan を作るよう伝える(`superpowers:writing-plans` など)。
3. **差分の基点を決める。** 引数 `base=` があればそれを使う。無ければ `origin/HEAD` が指すブランチ(`git symbolic-ref --short refs/remotes/origin/HEAD`。`origin/main` の形で出る)を使う。プロジェクトの規約で別のブランチと比較するもの(例: hotfix 以外は `development` と比較する)があれば、その規約に従う。
4. **テスト/lint のコマンドを決める。** プロジェクトの CLAUDE.md が示す検証コマンド(例: `just lint`、`bash scripts/lint/git-diff-lint.sh`、`npm test`)を列挙する。特定できない、または候補が複数あって選べない場合は、`AskUserQuestion` で選んでもらう。1件以上が必要。
5. **動作確認 skill を決める。** 引数 `verify=` があればそれを使う。無ければ `AskUserQuestion` で聞く。選択肢は、そのリポジトリ専用の検証 skill(あれば先頭に置く)、`web-verify`、`run`、`none`(テスト/lint のみ)とする。
6. **上限回数を決める。** 引数 `rounds=` があれば `maxReviewRounds` に使い、無ければ省略する(既定は 3)。
7. **起動する。** Workflow ツールを次の形で呼ぶ。`args` は JSON の値として渡し、文字列化しない。

   ```
   Workflow({
     scriptPath: "<ホームディレクトリの絶対パス>/.claude/workflows/deliver.js",
     args: {
       planPath: "<絶対パス>",
       baseRef: "<手順3>",
       checkCommands: ["<手順4>", ...],
       verifySkill: "<手順5>",
       maxReviewRounds: <手順6。指定があるときだけ>
     }
   })
   ```

8. **結果を伝える。** Workflow の返り値の `report` を、そのままユーザーに示す。`prUrl` があれば添え、`published` が false であれば公開に失敗したことを先頭に書く。`stopReason` があれば、何が原因で止まったかを1文で添える。報告の中身を要約して丸めない(Unresolved Finding と Plan Concern は人間の判断材料なので、省略しない)。
````

- [ ] **Step 2: chezmoi の配置先を確認する**

Run: `chezmoi managed --source "$(pwd)" | grep -E 'skills/deliver|workflows/deliver'`
Expected: `.claude/skills/deliver`、`.claude/skills/deliver/SKILL.md`、`.claude/workflows/deliver.js` の3行が出る。

- [ ] **Step 3: 機密情報のスキャンを通す**

Run: `just scan-sensitive`
Expected: `No sensitive information found`

- [ ] **Step 4: コミットする**

```bash
git add dot_claude/skills/deliver/SKILL.md
git commit -m "feat(deliver): 引数を集めてから deliver Workflow を起動する入口 skill を追加する"
```

---

### Task 4: リポジトリの指示への記載と全体の検証

**Files:**
- Modify: `harness/modules/project/35-key-patterns.md`(末尾に1段落を足す)
- Regenerate: `CLAUDE.md`、`AGENTS.md`、`.cursor/rules/dotfiles.mdc`(`just harness-sync`)

- [ ] **Step 1: key patterns に1行ポインタを足す**

ルート `CLAUDE.md` は 40,000 文字の閾値まで残り約 340 文字しかないので、詳細は書かず1行にとどめる(詳細は spec と ADR にある)。`harness/modules/project/35-key-patterns.md` の末尾に次を追加する:

```markdown
**Autonomous delivery (`deliver`)** — 入口 skill `dot_claude/skills/deliver/` と Workflow `dot_claude/workflows/deliver.js` の組。ループの判定はコードで行う(ADR 0007、`just test-deliver`)。設計は `docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`。
```

- [ ] **Step 2: 生成物を再生成する**

Run: `just harness-sync && just check-instructions && python3 -c "print(len(open('CLAUDE.md').read()))"`
Expected: drift なし。文字数が 40000 未満(超えたら追加した行を短くする)

- [ ] **Step 3: 全体の lint を通す**

Run: `just lint`
Expected: すべて成功する(`test-deliver` を含む)。

- [ ] **Step 4: コミットする**

```bash
git add harness/modules/project/35-key-patterns.md CLAUDE.md AGENTS.md .cursor/rules/dotfiles.mdc
git commit -m "docs(deliver): リポジトリの指示に deliver の構成と判定の置き場所を記載する"
```

- [ ] **Step 5: 実機での試運転は、マージと `chezmoi apply` の後に人間が行う**

`chezmoi apply` は `main` から配置するため、このブランチのままでは `~/.claude/workflows/deliver.js` は配置されない。マージ後に小さな plan で `/deliver` を1回実行し、統計のトークン数を spec の「コスト」節に追記して、`budget` の既定値を決める。この PR の範囲には含めない。
