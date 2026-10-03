# 参考指摘の修正 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** deliver / review-verify のレビューループで、修正必須でない指摘(Advisory Finding)も修正エージェントに渡し、`superpowers:receiving-code-review` の判断で直させる。

**Architecture:** `dot_claude/workflows/deliver.js` の `reviewRounds` / `runFix` / `fixPrompt` / `renderReport` を変える。修正必須の判定・見送りの検証・収束条件は変えない。結果を参考指摘として扱うかどうかは、その key を参考指摘として渡したかどうかでコードが決める(エージェントの申告では決めない)。

**Tech Stack:** Claude Code Workflows のスクリプト(素の JS)、`node --test`(`just test-deliver`)

**Spec:** `docs/superpowers/specs/2026-10-03-review-advisory-fix-design.md`(決定は `docs/adr/0014-advisory-findings-go-to-the-fixer.md`)

## Global Constraints

- 修正必須の表 `REVIEWERS[].blocking` と ecc の `note` は変えない。
- `FIX_SCHEMA` は変えない(`action: "fixed" | "propose-defer"`)。
- 参考指摘の修正による変更は `fixChanges` に入れる。入口 skill が jq で突き合わせる `checksChanges` / `fixChanges` / `verifyFixChanges` の名前と形は変えない。
- 判定は mode で分けない(deliver と review-verify の両方に効く)。
- 参考指摘だけの修正ラウンドも `maxReviewRounds` を1つ消費する。上限到達時に参考指摘を Unresolved にしない。
- コメントは日本語で、経緯ではなく現在の事実を書く(`~/.claude/rules/common/code-comments.md`)。
- 検証は `just test-deliver` と `just lint`。コマンドを手で組まない。

## Review Focus

1. 一度回答した参考指摘の key が、後のラウンドで修正必須の重大度で出直した場合 → 閉じた参考指摘として無視されず、通常の修正必須として修正に回る(Task 2 のテスト「閉じた参考指摘の key が修正必須の重大度で出直したら、修正必須として扱う」)。
2. 修正エージェントが参考指摘に対応結果を返さなかった場合 → 閉じずに参考指摘として報告に残り、ループは止まらない(Task 2 のテスト「対応結果の無い参考指摘は閉じない」)。
3. 参考指摘だけの修正ラウンドで、修正エージェントが結果を返さない(null)場合 → `fixer-failed` で止まり、渡した参考指摘は「再レビューされていない参考指摘」に出る(コミットが残っている可能性があるため)(Task 2 のテスト「参考指摘だけの修正で修正エージェントが結果を返さなければ…」)。
4. 修正必須と参考指摘が同じラウンドに混在する場合 → 1回の修正にまとめて渡し、修正必須の見送りにだけ検証者が付く(Task 2 のテスト「修正必須と参考指摘は1回の修正にまとめ…」)。
5. ledger を JSON にするとき、`Set` の `advisoryClosedKeys` が `{}` に潰れる → 配列として保存される(Task 2 の T-A1 の ledger の assert)。

---

### Task 1: receiving-code-review が Workflow のエージェントから読み込めることを実測する

**親セッション(人間の同意を得たうえで)が行う。** Workflow ツールはユーザーの明示的な opt-in が要るため、サブエージェントには渡さない。実行前にユーザーへ「1エージェントだけの Workflow を実行してよいか」を確認する。

**Files:**
- Modify: `docs/superpowers/specs/2026-10-03-review-advisory-fix-design.md`(実測結果を「修正エージェントの prompt」節の末尾に1文で追記)

- [ ] **Step 1: 実測用の Workflow を実行する**

```js
export const meta = {
  name: 'probe-receiving-code-review',
  description: 'receiving-code-review が Workflow のエージェントから本文込みで読み込めるかを確かめる',
}
const r = await agent(
  'Skill ツールで「superpowers:receiving-code-review」を読み込め。読み込めたら、その本文に含まれる見出し「## The Response Pattern」の直後のコードブロックの1行目を quoted にそのまま返せ。読み込めなかった、または別エージェントとして起動しただけなら loaded=false とし、何が起きたかを detail に書け。ファイルは変更しない。',
  {
    label: 'probe',
    schema: {
      type: 'object',
      properties: { loaded: { type: 'boolean' }, quoted: { type: 'string' }, detail: { type: 'string' } },
      required: ['loaded', 'detail'],
    },
  },
)
return r
```

Expected: `loaded: true`、`quoted` が `WHEN receiving code review feedback:`。

- [ ] **Step 2: 結果で分岐する**

`loaded: true` なら spec に「2026-10-03 実測。Workflow のエージェントから本文を読み込めた」と追記して Task 2 へ進む。`false` ならここで止め、結果をユーザーに報告する(この計画の前提が崩れるため、Task 2 以降に進まない)。

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-10-03-review-advisory-fix-design.md
git commit -m "docs: receiving-code-review を Workflow から読み込めることの実測結果を記録する"
```

---

### Task 2: 参考指摘を修正に回すループ・振り分け・報告

**Files:**
- Modify: `dot_claude/workflows/deliver.js`(`newState`、`ledgerJson`、`fixPrompt` の引数、`renderReport`、`runFix`、`reviewLoop`、`reviewRounds`)
- Test: `test/deliver-workflow.test.mjs`

**Interfaces:**
- Produces:
  - `state.advisoryClosedKeys: Set<string>` — 回答済み(`fixed` / `propose-defer`)の参考指摘の key
  - `state.advisoryDeclined: Array<Item & { reason: string }>`
  - `state.advisoryUnverified: Array<Item>` — 修正に回した後、再レビューされずに止まった参考指摘
  - `state.fixed` の要素に `advisory: true` が付くことがある
  - `state.rounds[i].advisoryFixed: number` / `advisoryDeclined: number`
  - `runFix(state, roundNo, blocking, advisory)` → `{ firstRejections, rejected, advisoryFixed: Item[] | null }`(修正エージェントが null を返したときだけ `advisoryFixed` が null)
  - `fixPrompt(items, advisory, config)` — Task 3 がこの関数の本文を書き換える

- [ ] **Step 1: 既存テスト「修正必須でない指摘は修正せず、参考指摘として報告する」を、新しい挙動のテストに置き換える**

`test/deliver-workflow.test.mjs` の該当テスト(`test("修正必須でない指摘は修正せず、参考指摘として報告する", …)`)を削除し、同じ位置に次を書く。

```js
// T-A1
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

// T-A2
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

// T-A3 / T-A5
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

// T-A4
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

// Review Focus 1
test("閉じた参考指摘の key が修正必須の重大度で出直したら、修正必須として扱う", async () => {
  const { calls } = await runWorkflow({
    respond: scenario({
      reviews: [{ ecc: [finding("MEDIUM")] }, { ecc: [finding("HIGH")] }, {}],
      merges: [[cluster("a.js::style", ["ecc#0"])], [cluster("a.js::style", ["ecc#0"])]],
      fixes: [
        { results: [{ key: "a.js::style", action: "propose-defer", reason: "nit" }], changes: [], observations: [] },
        { results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] },
      ],
    }),
  });
  const fixCalls = calls.filter((c) => c.label.startsWith("fix:"));
  assert.equal(fixCalls.length, 2);
  assert.match(fixCalls[1].prompt, /a\.js::style/);
});

// Review Focus 2
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

// Review Focus 3
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

// Review Focus 4
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

// T-A6
test("参考指摘を修正に回した後、checks が落ちて止まったら、Unresolved にせず再レビューされていない参考指摘として出す", async () => {
  const { result } = await runWorkflow({
    respond: scenario({
      checks: (round) => ({ passed: round === 1, details: "lint error" }),
      reviews: [{ ecc: [finding("MEDIUM")] }],
      merges: [[cluster("a.js::style", ["ecc#0"])]],
      fixes: [{ results: [{ key: "a.js::style", action: "fixed" }], changes: [], observations: [] }],
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
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `just test-deliver`
Expected: FAIL。上で足したテストが落ちる(例: T-A1 は `fix:1` が呼ばれず `labels.slice(2, 10)` が一致しない)。既存のテストは通ったまま。

- [ ] **Step 3: `newState` と `ledgerJson` に状態を足す**

`newState` の `advisory: [],` の直後に足す。

```js
    advisoryClosedKeys: new Set(),
    advisoryDeclined: [],
    advisoryUnverified: [],
```

`ledgerJson` の `unansweredFixes: [...state.unansweredFixes],` の直後に足す。

```js
      advisoryClosedKeys: [...state.advisoryClosedKeys],
```

- [ ] **Step 4: `fixPrompt` が参考指摘を受け取るようにする(本文の書き換えは Task 3)**

`function fixPrompt(items, config) {` を `function fixPrompt(items, advisory, config) {` に変え、`指摘(JSON): ${JSON.stringify(items)}` の行を次の2行に置き換える。

```js
修正必須の指摘(JSON): ${JSON.stringify(items)}
参考指摘(JSON): ${JSON.stringify(advisory)}
```

- [ ] **Step 5: `runFix` で参考指摘を振り分ける**

シグネチャを `async function runFix(state, roundNo, blocking, advisory)` にし、`fixPrompt(items, state.config)` を `fixPrompt(items, advisory, state.config)` に変える。`if (!fix) { … }` の中の return を次にする。

```js
    return { firstRejections: new Set(), rejected: new Set(), advisoryFixed: null };
```

`const byKey = …` の直後(修正必須の `fixed` を記録するループの前)に足す。

```js
  // 参考指摘かどうかは、エージェントの申告ではなく、その key を参考指摘として渡したかで決める(ADR 0014)。
  // 参考指摘の見送りには検証者を付けない。回答した key は閉じ、再出現しても修正に回さない。
  const advisoryByKey = Object.fromEntries(advisory.map((a) => [a.key, a]));
  const advisoryFixed = [];
  const round = state.rounds[state.rounds.length - 1];
  for (const r of fix.results) {
    const item = advisoryByKey[r.key];
    if (!item || state.advisoryClosedKeys.has(r.key)) continue;
    state.advisoryClosedKeys.add(r.key);
    if (r.action === "fixed") {
      state.fixed.push({ ...item, advisory: true });
      advisoryFixed.push(item);
      round.advisoryFixed++;
    } else {
      state.advisoryDeclined.push({ ...item, reason: r.reason || "" });
      round.advisoryDeclined++;
    }
  }
```

末尾の `return { firstRejections, rejected };` を `return { firstRejections, rejected, advisoryFixed };` にする。

- [ ] **Step 6: `reviewLoop` で、再レビューされずに止まった参考指摘を記録する**

`const tracker = { unverified: [] };` を次にする。

```js
  const tracker = { unverified: [], unverifiedAdvisory: [] };
```

`finally` ブロックの `markUnresolved(…);` の後に足す。

```js
    // 参考指摘は Unresolved にしないが、修正のコミットは残っているので人間に見せる。
    for (const item of tracker.unverifiedAdvisory)
      if (!state.advisoryUnverified.some((u) => u.key === item.key))
        state.advisoryUnverified.push(item);
```

- [ ] **Step 7: `reviewRounds` のループを変える**

`result.advisory = result.advisory.filter((i) => !carried.has(i.key));` の直後に足す。

```js
    const pendingAdvisory = uniqueByKey(result.advisory).filter(
      (i) => !state.advisoryClosedKeys.has(i.key),
    );
```

`tracker.unverified = [];` の直後に `tracker.unverifiedAdvisory = [];` を足す。

`state.rounds.push({ … })` のオブジェクトに `advisoryFixed: 0,` と `advisoryDeclined: 0,` を足す(`advisory: result.advisory.length,` の直後)。

`if (result.blocking.length === 0) return;` を次にする。

```js
    if (result.blocking.length === 0 && pendingAdvisory.length === 0) return;
```

上限到達の分岐(`if (fixRound >= state.config.maxReviewRounds) { … }`)は変えない(`markUnresolved` に渡すのは `result.blocking` だけなので、参考指摘は参考指摘のまま残る)。

`tracker.unverified = result.blocking;` の直後に `tracker.unverifiedAdvisory = pendingAdvisory;` を足し、`runFix` の呼び出しと直後を次にする。

```js
    const { firstRejections, rejected, advisoryFixed } = await runFix(
      state,
      roundNo,
      result.blocking,
      pendingAdvisory,
    );
    // 結果が返らなかった修正は、どの参考指摘を直したか分からないので、渡した全件を未確認として扱う。
    tracker.unverifiedAdvisory = advisoryFixed ?? pendingAdvisory;
    if (state.stopReason) return;
```

(既存の `if (state.stopReason) return;` はこの中に含めたので重複させない。)

- [ ] **Step 8: `renderReport` を変える**

`pushSection("参考指摘(修正必須ではない)", uniqueByKey(state.advisory), formatItem);` から「修正した指摘」の `pushSection(…)` までを次に置き換える。

```js
  const unverifiedAdvisoryKeys = new Set(state.advisoryUnverified.map((i) => i.key));
  if (state.advisoryUnverified.length > 0)
    pushSection("修正に回した後、再レビューされていない参考指摘", state.advisoryUnverified, formatItem);
  pushSection(
    "参考指摘(修正必須ではない)",
    uniqueByKey(state.advisory).filter(
      (i) => !state.advisoryClosedKeys.has(i.key) && !unverifiedAdvisoryKeys.has(i.key),
    ),
    formatItem,
  );
  pushSection(
    "見送った参考指摘",
    state.advisoryDeclined,
    (d) => `${formatItem(d)} — 見送り理由: ${d.reason}`,
  );
  // 修正エージェントは人間が書いたブランチにもコミットを足すので、何を直したかを残す。
  // 直したと申告しても後で Unresolved になった指摘や、再レビューされていない参考指摘は、直ったと確かめていないので出さない。
  pushSection(
    "修正した指摘",
    uniqueByKey(state.fixed).filter(
      (i) => !state.unresolvedKeys.has(i.key) && !unverifiedAdvisoryKeys.has(i.key),
    ),
    (i) => (i.advisory ? `[参考] ${formatItem(i)}` : formatItem(i)),
  );
```

統計の行を次にする。

```js
      `  - ラウンド ${r.round}: 修正必須 ${r.blocking} / 再出現 ${r.repeated} / 参考 ${r.advisory}(修正 ${r.advisoryFixed} / 見送り ${r.advisoryDeclined})`,
```

- [ ] **Step 9: テストを通す**

Run: `just test-deliver`
Expected: PASS(全件)。既存テストが落ちたら、参考指摘が修正に回るようになったことで `fixes[]` の応答が足りなくなっていないか(`fixes[i]` が `undefined` だと `fixer-failed` になる)を最初に疑う。既存テストの意図を変えずに直せない場合は止めて報告する。

- [ ] **Step 10: Commit**

```bash
git add dot_claude/workflows/deliver.js test/deliver-workflow.test.mjs
git commit -m "feat(deliver): 参考指摘も修正エージェントに渡し、回答した key を閉じる"
```

---

### Task 3: 修正エージェントの prompt を receiving-code-review に委ねる

**Files:**
- Modify: `dot_claude/workflows/deliver.js`(`fixPrompt`)
- Test: `test/deliver-workflow.test.mjs`

**Interfaces:**
- Consumes: Task 2 の `fixPrompt(items, advisory, config)`

- [ ] **Step 1: 失敗するテストを書く**

```js
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
  assert.match(prompt, /propose-defer とし、その旨を reason に書く/);
  assert.match(prompt, /参考指摘は、技術的に正しく要件文書と衝突しないなら直す/);
  assert.match(prompt, /直すのが大変だという理由では見送らない/);
  assert.match(prompt, /修正必須・参考の両方/);
});
```

- [ ] **Step 2: テストが落ちることを確かめる**

Run: `just test-deliver`
Expected: FAIL(`superpowers:receiving-code-review` が prompt に無い)

- [ ] **Step 3: `fixPrompt` を書き換える**

```js
function fixPrompt(items, advisory, config) {
  return `次のレビュー指摘に対応せよ。要件文書は ${config.requirementsPath}、対象の差分は「${config.baseRef}...HEAD」。
修正必須の指摘(JSON): ${JSON.stringify(items)}
参考指摘(JSON): ${JSON.stringify(advisory)}
- Skill ツールで「superpowers:receiving-code-review」を読み込み、その手順で各指摘を評価してから対応する。
- この実行は非対話で、人間に質問できない。skill が人間に聞く・止まって相談するとする場面(指摘が不明確、人間の過去の判断や要件文書と衝突する、アーキテクチャに関わる)では、その指摘を action="propose-defer" とし、その旨を reason に書く。他の指摘への対応は止めない。
- 全ての指摘(修正必須・参考の両方)について、修正したら action="fixed"、修正すべきでないと判断したら action="propose-defer" と具体的な理由を返す。
- 修正必須の指摘を propose-defer にしてよいのは、偽陽性か要件文書の範囲外の場合と、上の非対話の読み替えに当たる場合だけ。直すのが大変だという理由では見送らない。
- 参考指摘は、技術的に正しく要件文書と衝突しないなら直す。見送るのは、偽陽性・この差分の範囲外・要件文書との衝突・上の非対話の読み替えに当たる場合だけ。
- deferralRejectedReason がある指摘は、見送りの提案が検証者に却下されている。その理由を読んだうえで修正する。
- unansweredBefore が true の指摘は、前回の修正で対応結果が返らなかった。
- 修正した後、次のコマンドを全て成功させる: ${commands(config)}
- 修正をまとめて新しい1コミットにする(push はしない)。${keepRequirements(config).trimStart()}
${reportChanges}
- 指摘の範囲外で気づいた問題は observations に書く。${unstartedScope(config, "それを実装しない。実装しないと解消しない指摘は、要件文書の範囲外として propose-defer にする。")}`;
}
```

- [ ] **Step 4: テストを通す**

Run: `just test-deliver`
Expected: PASS(全件。review-verify の範囲を限る既存テスト「review-verify では、要件文書のうちブランチが着手していない項目を実装させないよう…」も fix の prompt を見ているので、通ることを確かめる)

- [ ] **Step 5: Commit**

```bash
git add dot_claude/workflows/deliver.js test/deliver-workflow.test.mjs
git commit -m "feat(deliver): 修正エージェントに receiving-code-review で指摘を評価させる"
```

---

### Task 4: 用語を更新し、全体の検査を通す

**Files:**
- Modify: `CONTEXT.md`(「Autonomous delivery」節)

- [ ] **Step 1: `CONTEXT.md` を更新する**

Review Finding の定義を次に置き換える。

```md
**Review Finding**:
レビューが返す個々の指摘。重大度を持つ。修正必須のものは修正されるか Deferred Finding になるかで閉じ、Advisory Finding は修正されるか Declined Advisory Finding になるかで閉じる。
```

Unresolved Finding の項の直後に足す。

```md
**Advisory Finding**:
修正必須の重大度を含まない Review Finding。修正エージェントに渡すが、ループの収束条件には数えず、上限に達しても Unresolved Finding にしない。
_Avoid_: nit(重大度を問わず使われる)、参考指摘(報告の節名としては使う)

**Declined Advisory Finding**:
修正エージェントが直さないと判断した Advisory Finding。Deferred Finding と違い検証者の同意を要さず、理由付きで最終報告に載る。
_Avoid_: Deferred Finding(検証者の同意を経たものに限る)
```

- [ ] **Step 2: 全体の検査を通す**

Run: `just lint`
Expected: PASS(`test-deliver`、`oxfmt`、`oxlint`、`check-comment-noise` を含む)。`oxfmt` が整形差分を出したら、`just --list` で整形を適用するレシピを確かめて適用し、再実行する。

- [ ] **Step 3: Commit**

```bash
git add CONTEXT.md
git commit -m "docs: Advisory Finding と Declined Advisory Finding を用語に足す"
```
