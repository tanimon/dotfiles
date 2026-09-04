# ローカル LLM によるセッション・トリアージ 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 滞留している未 reflect セッション 238 件を、ローカル LLM の一次スクリーニングによって処理可能な件数まで絞り込む。

**Architecture:** 3 層。Layer 1(決定論・TypeScript)が transcript を数十 KB のダイジェストに圧縮し、Layer 2(ローカル LLM)がダイジェスト 1 件につき 1 判断を JSON スキーマ強制で返して `triage.jsonl` に追記のみを行い、Layer 3(Claude)が上位 N 件の指された根拠箇所だけを読んで `queue.md` に書く。`pending.jsonl` は Layer 2 から構造的に触らせない。

**Tech Stack:** TypeScript(ビルドなし・依存ゼロ、Node v24 の型ストリッピングで直接実行) / `node:test` / ollama(`qwen3:8b`, `qwen3:14b`)

**Spec:** `docs/superpowers/specs/2026-08-27-local-llm-session-triage-design.md`

## Global Constraints

- **実行環境:** MacBook Air M4 / 24GB / ファンレス。バッチ実行中は電源接続必須(サーマルスロットリング対策)
- **作業時間:** 6 時間(360 分)・個人作業。各タスクに時間枠と打ち切り時の退避策がある
- **実装言語:** TypeScript。ビルドステップ・トランスパイラ・外部パッケージを**追加しない**。実行は `node <file>.ts`(Node v24 系は型ストリッピング既定有効)
- **テスト:** `node:test` + `node:assert/strict`。既存 bats は bash 用のため併用
- **コードの置き場:** chezmoi source の `dot_claude/scripts/triage/`。**`~/.claude/scripts/` を直接編集しない**(worktree が clean のままになり、コミットしたつもりの変更が残らない)
- **合宿中はソースツリーから直接実行する。** すべての CLI は chezmoi source のパス(`node dot_claude/scripts/triage/*.ts`)で叩き、`~/.claude/scripts/` にデプロイされたコピーには依存しない。`chezmoi apply` が要るのは常用(cron 化)を決めてからであり、当日は不要
- **ランタイム成果物の置き場:** `~/.claude/harness/` 配下(`digests/`, `triage.jsonl`, `gold-set.jsonl`)。chezmoi 管理外
- **`~/.claude/harness/pending.jsonl` への書き込みを一切行わない。** 読み取り専用。SessionEnd hook が並行追記するため
- **コミット単位:** 各タスク末尾で 1 コミット。ブランチは `docs/local-llm-session-triage-spec` を継続使用するか、実装用に切り直す
- **文言の言語:** コード内コメント・レポート出力は日本語。ただし `queue.md` に入るエントリは既存ルール通り**英語**

---

## ファイル構成

| ファイル | 責務 |
|---|---|
| `dot_claude/scripts/triage/types.ts` | 全モジュール共有の型定義。他モジュールはここからのみ型を取る |
| `dot_claude/scripts/triage/transcript.ts` | transcript jsonl 1 ファイル → ダイジェスト行の配列。Layer 1 のパースの中核。純関数のみで I/O を持たない |
| `dot_claude/scripts/triage/digest.ts` | `transcript.ts` を使い、切り詰めとトークン概算を行い `digests/` に書き出す CLI |
| `dot_claude/scripts/triage/signals.ts` | 摩擦シグナルの集計とランキング(ベースライン②)、ダイジェスト合計トークン数の算出(ベースライン①) |
| `dot_claude/scripts/triage/ollama.ts` | ollama HTTP クライアント。JSON スキーマ強制・thinking 制御・実測トークン数の取得 |
| `dot_claude/scripts/triage/probe.ts` | ollama の挙動確認と tok/s 実測。モデル入れ替え時の再測定にも使う |
| `dot_claude/scripts/triage/pick-gold.ts` | gold set 用の層化サンプリング。低シグナル層を主層に取る |
| `dot_claude/scripts/triage/calibrate.ts` | 概算トークン数を ollama の実測値で較正する。ベースライン①を実測ベースに直す |
| `dot_claude/scripts/triage/classify.ts` | ダイジェスト 1 件 → `TriageVerdict`。プロンプトとスキーマを保持 |
| `dot_claude/scripts/triage/batch.ts` | 全件バッチ。レジューム・進捗表示・`triage.jsonl` への追記 |
| `dot_claude/scripts/triage/evaluate.ts` | gold set に対する recall / 偽陽性の算出。層別に集計 |
| `dot_claude/scripts/triage/report.ts` | `triage.jsonl` → 日本語 Markdown レポート(Layer 3 の入力かつ共有用) |
| `test/triage-transcript.test.ts` | `transcript.ts` のテスト |
| `test/triage-signals.test.ts` | `signals.ts` のテスト |
| `test/triage-batch.test.ts` | `batch.ts` のレジューム挙動のテスト |
| `justfile` | `test-triage` ターゲットを追加 |

**分割の理由:** `transcript.ts` を純関数に切り出すことで、29MB のファイルを用意せずにテストできる。`ollama.ts` を分けることで、モデルが動かない状況でも Layer 1 側の作業を止めずに進められる(当日の最大のリスクヘッジ)。

---

## Task 0: 前夜までの準備(合宿当日ではない)

**Files:** なし(環境構築のみ)

- [ ] **Step 1: ollama を導入する**

```bash
brew install ollama
brew services start ollama   # または: ollama serve &
```

- [ ] **Step 2: モデルを 2 つ pull する**

```bash
ollama pull qwen3:8b     # 約 5GB
ollama pull qwen3:14b    # 約 9GB
```

- [ ] **Step 3: 疎通だけ確認して終わる**

```bash
curl -s http://localhost:11434/api/tags | head -c 400
```

Expected: 上記 2 モデルが含まれた JSON が返る

**会場の Wi-Fi で 5〜9GB を落とすと 6 時間のうち 1 時間が溶ける。** ここは当日にやらない。

---

## Task 1: ollama クライアントと当日の実測(0:00-0:30)

**Files:**
- Create: `dot_claude/scripts/triage/types.ts`
- Create: `dot_claude/scripts/triage/ollama.ts`

**Interfaces:**
- Consumes: なし
- Produces: `types.ts` の全型。`ollama.ts` の `generateJson<T>(opts): Promise<OllamaResult<T>>`

このタスクは**測定が主目的**であり、TDD の対象は薄い。優先するのは、当日の見積もりを狂わせる 2 つの不確定要素(JSON スキーマ強制が効くか / thinking トークンが出るか)を 30 分以内に潰すこと。

- [ ] **Step 1: 型定義を書く**

`dot_claude/scripts/triage/types.ts`:

```typescript
/** ~/.claude/harness/pending.jsonl の 1 行 */
export interface PendingEntry {
  session_id: string;
  transcript_path: string;
  cwd: string;
  recorded_epoch: number;
}

/** 決定論的に数えられる摩擦シグナル */
export interface FrictionSignals {
  /** [Request interrupted by user] の出現回数 */
  interrupts: number;
  /** tool_result で is_error だったものの件数 */
  toolErrors: number;
  /** ユーザーの短い否定・押し戻し発言の件数 */
  userNegations: number;
  /** 上記の単純合計。ベースライン②のランキングキー */
  total: number;
}

/** ダイジェスト 1 件 */
export interface Digest {
  sessionId: string;
  cwd: string;
  recordedEpoch: number;
  /** ダイジェスト本文(モデルに渡すテキスト) */
  text: string;
  signals: FrictionSignals;
  /** 概算トークン数。Task 1 で実測較正した係数を使う */
  approxTokens: number;
  /** トークン上限で切り詰めたか */
  truncated: boolean;
  /** 元 transcript のバイト数(圧縮率の算出用) */
  originalBytes: number;
}

export type TriageCategory =
  | "wrong_assumption"
  | "user_correction"
  | "repeated_attempts"
  | "rule_drift"
  | "none";

export type TriageSeverity = "high" | "medium" | "low";

/** ローカル LLM が返す判断。この形をスキーマで強制する */
export interface TriageVerdict {
  has_learning: boolean;
  category: TriageCategory;
  severity: TriageSeverity;
  /** ダイジェスト中の根拠となる引用。Layer 3 はここだけを読む */
  evidence: string;
  /** 日本語 1 行の要約 */
  one_line: string;
}

/** triage.jsonl の 1 行 */
export interface TriageRecord {
  session_id: string;
  /** ダイジェスト JSON のパス。元 transcript ではない(Layer 3 はこちらを読む) */
  digest_path: string;
  verdict: TriageVerdict;
  model: string;
  elapsed_ms: number;
  prompt_tokens: number;
  eval_tokens: number;
  signals: FrictionSignals;
}

/** gold-set.jsonl の 1 行 */
export interface GoldLabel {
  session_id: string;
  /** 人手で付けた二値ラベル */
  has_learning: boolean;
  /** "low-signal" か "high-signal"。集計時に混ぜない */
  stratum: "low-signal" | "high-signal";
  /** ラベルを付けた理由(後で自分が見返すため) */
  note: string;
}
```

- [ ] **Step 2: ollama クライアントを書く**

`dot_claude/scripts/triage/ollama.ts`:

```typescript
const OLLAMA_URL = process.env.OLLAMA_URL ?? "http://localhost:11434";

export interface OllamaResult<T> {
  value: T;
  /** ollama が報告する実測プロンプトトークン数 */
  promptTokens: number;
  /** 実測生成トークン数 */
  evalTokens: number;
  elapsedMs: number;
  /** 生のレスポンス文字列(パース失敗時の診断用) */
  raw: string;
}

export interface GenerateJsonOptions {
  model: string;
  prompt: string;
  /** JSON Schema。ollama の format に渡してデコードを制約する */
  schema: object;
  /** Qwen3 等のハイブリッド推論モデルの thinking を切る */
  think?: boolean;
  /** 決定性のため既定 0 */
  temperature?: number;
  /** コンテキスト長。ダイジェストが入り切る値にする */
  numCtx?: number;
}

/**
 * ollama に 1 回だけ問い合わせ、スキーマに従う JSON を得る。
 * ストリームは使わない(1 件 1 判断なので待てばよい)。
 */
export async function generateJson<T>(
  opts: GenerateJsonOptions,
): Promise<OllamaResult<T>> {
  const started = Date.now();
  const res = await fetch(`${OLLAMA_URL}/api/generate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: opts.model,
      prompt: opts.prompt,
      format: opts.schema,
      stream: false,
      think: opts.think ?? false,
      options: {
        temperature: opts.temperature ?? 0,
        num_ctx: opts.numCtx ?? 8192,
      },
    }),
  });
  if (!res.ok) {
    throw new Error(`ollama ${res.status}: ${await res.text()}`);
  }
  const body = (await res.json()) as {
    response: string;
    prompt_eval_count?: number;
    eval_count?: number;
  };
  return {
    value: JSON.parse(body.response) as T,
    promptTokens: body.prompt_eval_count ?? 0,
    evalTokens: body.eval_count ?? 0,
    elapsedMs: Date.now() - started,
    raw: body.response,
  };
}
```

- [ ] **Step 3: スキーマ強制と thinking の挙動を実測する**

`dot_claude/scripts/triage/probe.ts` として書く(相対 import にするため、使い捨てにせずリポジトリ内に置く。モデルを入れ替えたときの再測定にも使える)。

```typescript
import { generateJson } from "./ollama.ts";

const schema = {
  type: "object",
  properties: {
    has_learning: { type: "boolean" },
    one_line: { type: "string" },
  },
  required: ["has_learning", "one_line"],
};

for (const think of [false, true]) {
  const r = await generateJson<{ has_learning: boolean; one_line: string }>({
    model: "qwen3:8b",
    prompt: "次の作業ログに改善の学びがあるか判定せよ: ユーザーが3回同じ修正を指示し直した。",
    schema,
    think,
  });
  console.log({ think, ms: r.elapsedMs, evalTokens: r.evalTokens, raw: r.raw.slice(0, 200) });
}
```

Run: `node dot_claude/scripts/triage/probe.ts`

**確認すること(ここが本タスクの成果):**
1. `think: false` で `<think>` ブロックが出ないこと
2. `think` の切り替えで `evalTokens` と `elapsedMs` がどれだけ変わるか
3. スキーマ外のキーが混ざらないこと

- [ ] **Step 4: tok/s を記録し、238 件の所要時間を見積もる**

`evalTokens / (elapsedMs / 1000)` と `promptTokens / (elapsedMs / 1000)` をメモする。ダイジェスト 1 件 3k トークンと仮定して 238 件分を掛け、**所要時間が 60 分を超えるなら Task 7 の対象を 40 件サンプルに縮小する**と決めてしまう。

**この時点で決めた `think` の設定を、以降のすべての実行で固定する。** 測定時とバッチ実行時で違うと見積もりが数倍単位で外れる。

- [ ] **Step 5: コミット**

```bash
git add dot_claude/scripts/triage/types.ts dot_claude/scripts/triage/ollama.ts dot_claude/scripts/triage/probe.ts
git commit -m "feat(triage): ollamaクライアントと共有型を追加"
```

**打ち切り時の退避:** `format` にスキーマを渡す方式が不安定なら、スキーマを捨てて「YES / NO のみを出力せよ」という 1 トークン出力に切り替える。`TriageVerdict` のうち `has_learning` だけが必須で、他は無くても Layer 3 は動く。

---

## Task 2: transcript のダイジェスト化(0:30-1:15)

**Files:**
- Create: `dot_claude/scripts/triage/transcript.ts`
- Test: `test/triage-transcript.test.ts`

**Interfaces:**
- Consumes: `types.ts` の `FrictionSignals`
- Produces: `extractLines(rawLines: string[]): DigestLine[]`、`renderDigest(lines: DigestLine[], maxChars: number): { text: string; truncated: boolean }`

**実データに基づく設計:** 29MB / 3927 行のセッションで型の内訳は `attachment` 2030 / `assistant` 525 / `user` 334 / `last-prompt` 244 / `mode` 243 / `permission-mode` 243 / `ai-title` 219 / `system` 70。**`attachment` がサイズの大半**であり、これを落とすだけで圧縮の大部分が達成される。

- [ ] **Step 1: 失敗するテストを書く**

`test/triage-transcript.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { extractLines, renderDigest } from "../dot_claude/scripts/triage/transcript.ts";

/** テスト用に transcript の 1 行を作る */
function line(obj: unknown): string {
  return JSON.stringify(obj);
}

test("attachment 行と各種メタ行を捨てる", () => {
  const raw = [
    line({ type: "attachment", message: { content: "巨大なファイル内容" } }),
    line({ type: "last-prompt", message: { content: "x" } }),
    line({ type: "mode", message: { content: "x" } }),
    line({ type: "permission-mode", message: { content: "x" } }),
    line({ type: "ai-title", message: { content: "x" } }),
    line({ type: "user", message: { content: "本文だけ残る" } }),
  ];
  const result = extractLines(raw);
  assert.equal(result.length, 1);
  assert.equal(result[0].text, "本文だけ残る");
  assert.equal(result[0].role, "user");
});

test("スラッシュコマンド由来のノイズ行を捨てる", () => {
  const raw = [
    line({ type: "user", message: { content: "<command-name>/model</command-name>" } }),
    line({ type: "user", message: { content: "<local-command-stdout>Set model to X</local-command-stdout>" } }),
    line({ type: "user", message: { content: "普通の指示" } }),
  ];
  const result = extractLines(raw);
  assert.deepEqual(result.map((r) => r.text), ["普通の指示"]);
});

test("assistant のテキストブロックを残し tool_use は捨てる", () => {
  const raw = [
    line({
      type: "assistant",
      message: {
        content: [
          { type: "text", text: "説明します" },
          { type: "tool_use", name: "Read", input: { file_path: "/x" } },
        ],
      },
    }),
  ];
  const result = extractLines(raw);
  assert.deepEqual(result.map((r) => r.text), ["説明します"]);
});

test("tool_result のエラーを error ロールとして残す", () => {
  const raw = [
    line({
      type: "user",
      message: {
        content: [
          { type: "tool_result", is_error: true, content: "command not found: foo" },
          { type: "tool_result", is_error: false, content: "成功したので不要" },
        ],
      },
    }),
  ];
  const result = extractLines(raw);
  assert.equal(result.length, 1);
  assert.equal(result[0].role, "error");
  assert.match(result[0].text, /command not found/);
});

test("[Request interrupted by user] を残す", () => {
  const raw = [line({ type: "user", message: { content: "[Request interrupted by user]" } })];
  const result = extractLines(raw);
  assert.equal(result.length, 1);
  assert.match(result[0].text, /interrupted/);
});

test("壊れた JSON 行は黙って飛ばす", () => {
  const raw = ["{壊れている", line({ type: "user", message: { content: "生き残る" } })];
  const result = extractLines(raw);
  assert.deepEqual(result.map((r) => r.text), ["生き残る"]);
});

test("上限を超えたら head+tail で切り詰め truncated を立てる", () => {
  const lines = Array.from({ length: 100 }, (_, i) => ({
    role: "user" as const,
    text: `行${i}`.padEnd(50, "あ"),
  }));
  const { text, truncated } = renderDigest(lines, 500);
  assert.equal(truncated, true);
  assert.ok(text.length <= 700, "上限+マーカー程度に収まる");
  assert.match(text, /行0/, "先頭は残る");
  assert.match(text, /行99/, "末尾も残る");
  assert.match(text, /中略/, "省略マーカーが入る");
});
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `node --test test/triage-transcript.test.ts`
Expected: FAIL(`Cannot find module '../dot_claude/scripts/triage/transcript.ts'`)

- [ ] **Step 3: 実装を書く**

`dot_claude/scripts/triage/transcript.ts`:

```typescript
/** ダイジェストに残る 1 行 */
export interface DigestLine {
  role: "user" | "assistant" | "error";
  text: string;
}

/** 判断に寄与しない行の type。実データの出現頻度順 */
const DROP_TYPES = new Set([
  "attachment",
  "last-prompt",
  "mode",
  "permission-mode",
  "ai-title",
  "file-history-delta",
  "file-history-snapshot",
  "queue-operation",
  "atis-latch",
  "system",
]);

/** スラッシュコマンド実行の副産物。ユーザーの意図を含まない */
const NOISE_PATTERNS = [
  /<command-name>/,
  /<command-message>/,
  /<command-args>/,
  /<local-command-stdout>/,
  /<local-command-caveat>/,
  /^Base directory for this skill:/,
];

function isNoise(text: string): boolean {
  return NOISE_PATTERNS.some((p) => p.test(text));
}

/** 1 行分のテキストを整形する。空白の潰しと長すぎる行の頭打ち */
function normalize(text: string): string {
  return text.replace(/\s+/g, " ").trim().slice(0, 2000);
}

/**
 * transcript の生の行配列から、判断に必要な行だけを抜き出す。
 * I/O を持たない純関数なので、巨大ファイルを用意せずテストできる。
 */
export function extractLines(rawLines: string[]): DigestLine[] {
  const out: DigestLine[] = [];
  for (const raw of rawLines) {
    let entry: { type?: string; message?: { content?: unknown } };
    try {
      entry = JSON.parse(raw);
    } catch {
      continue; // 壊れた行は捨てる。1.3GB のログには必ず混ざる
    }
    const type = entry.type;
    if (!type || DROP_TYPES.has(type)) continue;
    const content = entry.message?.content;

    if (typeof content === "string") {
      const text = normalize(content);
      if (!text || isNoise(text)) continue;
      if (type === "user" || type === "assistant") {
        out.push({ role: type, text });
      }
      continue;
    }

    if (Array.isArray(content)) {
      for (const block of content) {
        if (!block || typeof block !== "object") continue;
        const b = block as { type?: string; text?: string; is_error?: boolean; content?: unknown };
        if (b.type === "text" && typeof b.text === "string") {
          const text = normalize(b.text);
          if (!text || isNoise(text)) continue;
          out.push({ role: type === "assistant" ? "assistant" : "user", text });
        } else if (b.type === "tool_result" && b.is_error === true) {
          const text = normalize(
            typeof b.content === "string" ? b.content : JSON.stringify(b.content ?? ""),
          );
          if (text) out.push({ role: "error", text });
        }
        // tool_use は捨てる: 何をしたかは assistant のテキストと error で足りる
      }
    }
  }
  return out;
}

const OMIT_MARKER = "\n…(中略)…\n";

/**
 * ダイジェスト行を 1 つのテキストに整形する。
 * 上限を超える場合は head+tail を残す。冒頭には依頼、末尾には結末が出るため、
 * 中間を削るのが判断への損失が最も小さい。
 */
export function renderDigest(
  lines: DigestLine[],
  maxChars: number,
): { text: string; truncated: boolean } {
  const rendered = lines.map((l) => `[${l.role}] ${l.text}`);
  const full = rendered.join("\n");
  if (full.length <= maxChars) return { text: full, truncated: false };

  const half = Math.floor(maxChars / 2);
  const head = full.slice(0, half);
  const tail = full.slice(full.length - half);
  return { text: head + OMIT_MARKER + tail, truncated: true };
}
```

- [ ] **Step 4: テストを実行して通ることを確認する**

Run: `node --test test/triage-transcript.test.ts`
Expected: PASS(7 tests)

- [ ] **Step 5: 実データ 1 件で圧縮率を確認する**

```bash
node --input-type=module -e '
import { readFileSync } from "node:fs";
import { extractLines, renderDigest } from "/Users/'"$USER"'/.local/share/chezmoi/dot_claude/scripts/triage/transcript.ts";
const p = process.argv[1];
const raw = readFileSync(p, "utf8");
const lines = extractLines(raw.split("\n"));
const { text, truncated } = renderDigest(lines, 12000);
console.log({ originalBytes: raw.length, digestChars: text.length, lines: lines.length, truncated });
' "$(ls -S ~/.claude/projects/*/*.jsonl | head -1)"
```

Expected: `originalBytes` が数百万〜3000 万、`digestChars` が数千〜1.2 万

- [ ] **Step 6: justfile に test-triage を追加する**

`justfile` の `lint` 行(32 行目)の末尾に `test-triage` を足し、末尾に以下を追加:

```just
# Run the session-triage TypeScript tests
@test-triage:
    node --test test/
```

**グロブを書かないこと。** `node --test test/triage-*.test.ts` はシェルにグロブ展開を任せるため、この時点でまだ存在しない `triage-signals.test.ts` / `triage-batch.test.ts` にマッチせず、zsh が `no matches found` で落ちる。`lint` がこのターゲットに依存する以上、Task 2 から Task 7 まで `just lint` が赤いままになる。ディレクトリを渡して Node に探索させれば、`.bats` は Node のテスト判定パターンに合わないため無視される。

- [ ] **Step 7: この時点で just lint が通ることを確認する**

Run: `just lint`
Expected: PASS

**Task 9 まで lint 確認を先送りしない。** ここで通しておかないと、以降のタスクで壊れた場合に原因の切り分けができなくなる。

- [ ] **Step 8: コミット**

```bash
git add dot_claude/scripts/triage/transcript.ts test/triage-transcript.test.ts justfile
git commit -m "feat(triage): transcriptのダイジェスト化を追加"
```

**打ち切り時の退避:** 1:15 を過ぎたら、`extractLines` を「user のテキストだけ残す」まで単純化する。摩擦シグナルは Task 3 で別途数えるので、判断材料は最低限確保できる。

---

## Task 3: 摩擦シグナルと 2 つのベースライン(1:15-1:30)

**Files:**
- Create: `dot_claude/scripts/triage/signals.ts`
- Create: `dot_claude/scripts/triage/digest.ts`
- Test: `test/triage-signals.test.ts`

**Interfaces:**
- Consumes: `transcript.ts` の `DigestLine` / `extractLines` / `renderDigest`、`types.ts` の `Digest` / `FrictionSignals` / `PendingEntry`
- Produces: `countSignals(lines: DigestLine[]): FrictionSignals`、`estimateTokens(text: string): number`、CLI `digest.ts`

**このタスクで 2 つのベースラインが両方得られる。** ①ダイジェスト合計トークン数(算術)、②シグナル数ランキング(LLM 不要のプレフィルタ)。

- [ ] **Step 1: 失敗するテストを書く**

`test/triage-signals.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { countSignals, estimateTokens } from "../dot_claude/scripts/triage/signals.ts";
import type { DigestLine } from "../dot_claude/scripts/triage/transcript.ts";

test("割り込み・ツールエラー・否定発言をそれぞれ数える", () => {
  const lines: DigestLine[] = [
    { role: "user", text: "[Request interrupted by user]" },
    { role: "error", text: "command not found" },
    { role: "error", text: "permission denied" },
    { role: "user", text: "違う、そうじゃない" },
    { role: "assistant", text: "承知しました" },
  ];
  const s = countSignals(lines);
  assert.equal(s.interrupts, 1);
  assert.equal(s.toolErrors, 2);
  assert.equal(s.userNegations, 1);
  assert.equal(s.total, 4);
});

test("長い user 発言は否定語を含んでも否定発言に数えない", () => {
  const lines: DigestLine[] = [
    {
      role: "user",
      text: "この実装は違うアプローチも検討できますが、".padEnd(200, "詳細な説明が続く"),
    },
  ];
  // 短い押し戻しだけをシグナルとする。長文は通常の指示なので除外する
  assert.equal(countSignals(lines).userNegations, 0);
});

test("トークン数の概算は日本語で文字数を下回らない", () => {
  // 日本語は 1 文字あたり 1 トークン前後になりうるため、安全側に見積もる
  assert.ok(estimateTokens("あいうえお") >= 5);
  assert.ok(estimateTokens("hello world foo bar") < 19);
});
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `node --test test/triage-signals.test.ts`
Expected: FAIL(モジュールが無い)

- [ ] **Step 3: signals.ts を実装する**

```typescript
import type { DigestLine } from "./transcript.ts";
import type { FrictionSignals } from "./types.ts";

/** 短い押し戻し発言。長文の指示に紛れる同じ語は数えない */
const NEGATION_PATTERNS = [
  /違う/, /そうじゃな/, /やめて/, /間違/, /戻して/, /なんで/, /ダメ/, /不要/,
];
const NEGATION_MAX_CHARS = 60;

/** ユーザーが agent を止めた印。実データに存在を確認済み */
const INTERRUPT_PATTERN = /\[Request interrupted by user\]/;

export function countSignals(lines: DigestLine[]): FrictionSignals {
  let interrupts = 0;
  let toolErrors = 0;
  let userNegations = 0;

  for (const line of lines) {
    if (line.role === "error") {
      toolErrors++;
      continue;
    }
    if (INTERRUPT_PATTERN.test(line.text)) {
      interrupts++;
      continue;
    }
    if (
      line.role === "user" &&
      line.text.length <= NEGATION_MAX_CHARS &&
      NEGATION_PATTERNS.some((p) => p.test(line.text))
    ) {
      userNegations++;
    }
  }
  return {
    interrupts,
    toolErrors,
    userNegations,
    total: interrupts + toolErrors + userNegations,
  };
}

/**
 * トークン数の概算。日本語混じりのため 1 文字 = 1 トークンに近づく分を見込み、
 * ASCII は 4 文字 = 1 トークンとして数える。Task 1 で得た ollama の
 * prompt_eval_count と突き合わせて係数を較正すること。
 */
export function estimateTokens(text: string): number {
  let ascii = 0;
  let wide = 0;
  for (const ch of text) {
    if (ch.charCodeAt(0) < 128) ascii++;
    else wide++;
  }
  return Math.ceil(ascii / 4) + wide;
}
```

- [ ] **Step 4: テストを実行して通ることを確認する**

Run: `node --test test/triage-signals.test.ts`
Expected: PASS(3 tests)

- [ ] **Step 5: digest.ts(CLI)を実装する**

```typescript
#!/usr/bin/env node
/**
 * Layer 1 CLI: pending.jsonl の全エントリをダイジェスト化する。
 *
 * pending.jsonl は読み取り専用。SessionEnd hook が並行追記するため、
 * このスクリプトは一切書き戻さない。
 *
 * 使い方: node digest.ts [--max-chars 12000]
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { extractLines, renderDigest } from "./transcript.ts";
import { countSignals, estimateTokens } from "./signals.ts";
import type { Digest, PendingEntry } from "./types.ts";

const HARNESS_DIR = join(homedir(), ".claude", "harness");
const PENDING = join(HARNESS_DIR, "pending.jsonl");
const DIGEST_DIR = join(HARNESS_DIR, "digests");

const maxCharsArg = process.argv.indexOf("--max-chars");
const MAX_CHARS = maxCharsArg > -1 ? Number(process.argv[maxCharsArg + 1]) : 12000;

mkdirSync(DIGEST_DIR, { recursive: true });

const entries: PendingEntry[] = readFileSync(PENDING, "utf8")
  .split("\n")
  .filter((l) => l.trim())
  .map((l) => JSON.parse(l) as PendingEntry);

const digests: Digest[] = [];
let missing = 0;

for (const entry of entries) {
  if (!existsSync(entry.transcript_path)) {
    missing++;
    continue;
  }
  const raw = readFileSync(entry.transcript_path, "utf8");
  const lines = extractLines(raw.split("\n"));
  const { text, truncated } = renderDigest(lines, MAX_CHARS);
  const digest: Digest = {
    sessionId: entry.session_id,
    cwd: entry.cwd,
    recordedEpoch: entry.recorded_epoch,
    text,
    signals: countSignals(lines),
    approxTokens: estimateTokens(text),
    truncated,
    originalBytes: raw.length,
  };
  digests.push(digest);
  writeFileSync(join(DIGEST_DIR, `${entry.session_id}.json`), JSON.stringify(digest, null, 2));
}

// --- ベースライン①: 合計トークン数(算術・LLM 呼び出し 0 回) ---
const totalTokens = digests.reduce((a, d) => a + d.approxTokens, 0);
const totalOriginal = digests.reduce((a, d) => a + d.originalBytes, 0);
const truncatedCount = digests.filter((d) => d.truncated).length;

console.log("=== Layer 1 結果 ===");
console.log(`対象: ${digests.length} 件 (transcript 消失で除外: ${missing} 件)`);
console.log(`元サイズ合計: ${(totalOriginal / 1024 / 1024).toFixed(1)} MB`);
console.log(`ダイジェスト合計トークン(概算): ${totalTokens.toLocaleString()}`);
console.log(`  → 1M コンテキストに収まるか: ${totalTokens < 1_000_000 ? "収まる" : "収まらない"}`);
console.log(`切り詰めたセッション: ${truncatedCount} 件 (上限 ${MAX_CHARS} 文字)`);

// --- ベースライン②: シグナル数ランキング(LLM 不要のプレフィルタ) ---
const ranked = [...digests].sort((a, b) => b.signals.total - a.signals.total);
console.log("\n=== ベースライン②: 摩擦シグナル上位 20 件 ===");
for (const d of ranked.slice(0, 20)) {
  const s = d.signals;
  console.log(
    `${String(s.total).padStart(3)}  int=${s.interrupts} err=${s.toolErrors} neg=${s.userNegations}  ${d.sessionId}  ${d.cwd}`,
  );
}
const zeroSignal = digests.filter((d) => d.signals.total === 0).length;
console.log(`\nシグナル 0 件のセッション: ${zeroSignal} 件 (= ベースライン②が完全に見落とす集団)`);
```

- [ ] **Step 6: 実行してベースライン①②を記録する**

Run: `node dot_claude/scripts/triage/digest.ts`

**この出力をメモに残す。** 特に「ダイジェスト合計トークン」は本プロジェクトで最も決定的な数字である。1M に収まるなら Layer 1 だけで実現可能性の問題は解決しており、Layer 2 の価値はコスト・レイテンシ・プライバシーに変わる。**その場合も設計は変えず、共有時にその事実を正直に述べる。**

- [ ] **Step 7: 概算トークン数を実測で較正する**

ベースライン①は `estimateTokens` の概算に乗っている。**最も決定的な数字を推定のまま残さない。** ollama が返す `prompt_eval_count` は実測値なので、数件で比を取れば合計を実測ベースに直せる。

`dot_claude/scripts/triage/calibrate.ts`:

```typescript
#!/usr/bin/env node
/**
 * estimateTokens の係数を ollama の実測 prompt_eval_count で較正する。
 * ベースライン①(ダイジェスト合計トークン数)を推定から実測ベースに直すために使う。
 */
import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { generateJson } from "./ollama.ts";
import { estimateTokens } from "./signals.ts";
import type { Digest } from "./types.ts";

const DIGEST_DIR = join(homedir(), ".claude", "harness", "digests");
const files = readdirSync(DIGEST_DIR).filter((f) => f.endsWith(".json")).slice(0, 3);

let estimated = 0;
let actual = 0;
for (const file of files) {
  const digest: Digest = JSON.parse(readFileSync(join(DIGEST_DIR, file), "utf8"));
  // 中身の判定は不要。プロンプトを投入した際のトークン数だけが欲しい
  const r = await generateJson<{ ok: boolean }>({
    model: process.argv[2] ?? "qwen3:8b",
    prompt: digest.text,
    schema: { type: "object", properties: { ok: { type: "boolean" } }, required: ["ok"] },
    think: false,
    numCtx: 16384,
  });
  const est = estimateTokens(digest.text);
  estimated += est;
  actual += r.promptTokens;
  console.log(`${digest.sessionId}: 概算 ${est} / 実測 ${r.promptTokens} (比 ${(r.promptTokens / est).toFixed(2)})`);
}
console.log(`\n補正係数: ${(actual / estimated).toFixed(3)}`);
console.log("ベースライン①の合計トークンにこの係数を掛けた値を、実測ベースの数字として記録する");
```

Run: `node dot_claude/scripts/triage/calibrate.ts`

補正後の合計が 1M を超えるか下回るかを記録する。**超えるなら Layer 1 だけでは 238 件を 1 セッションに載せられず、Layer 2 の存在理由が「可能にすること」になる。下回るならその逆であり、その事実をそのまま結果に書く。**

- [ ] **Step 8: コミット**

```bash
git add dot_claude/scripts/triage/signals.ts dot_claude/scripts/triage/digest.ts dot_claude/scripts/triage/calibrate.ts test/triage-signals.test.ts
git commit -m "feat(triage): 摩擦シグナル集計とダイジェスト化CLIを追加"
```

---

## Task 4: gold set の作成(1:30-2:10)

**Files:**
- Create: `~/.claude/harness/gold-set.jsonl`(リポジトリ管理外・個人の作業ログを含むため)
- Create: `dot_claude/scripts/triage/pick-gold.ts`

**Interfaces:**
- Consumes: `digests/` 配下の `Digest` JSON
- Produces: `gold-set.jsonl`(`GoldLabel` の配列)

**このタスクだけは人間の手作業が本体である。** 20 件のダイジェストを読んでラベルを付ける。

- [ ] **Step 1: サンプリング CLI を書く**

```typescript
#!/usr/bin/env node
/**
 * gold set 用にダイジェストを層化サンプリングし、ラベル付けの雛形を出力する。
 *
 * 主層を「低シグナル層」にするのは、ベースライン②(シグナル数ソート)を
 * 上回るという主張が、そこにしか根拠を持たないため。シグナル上位で陽性を
 * 当てても、それはベースライン②が既に指している集団である。
 */
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Digest, GoldLabel } from "./types.ts";

const HARNESS_DIR = join(homedir(), ".claude", "harness");
const DIGEST_DIR = join(HARNESS_DIR, "digests");
const OUT = join(HARNESS_DIR, "gold-set-template.jsonl");

const LOW_SIGNAL_COUNT = 14;
const HIGH_SIGNAL_COUNT = 6;

const digests: Digest[] = readdirSync(DIGEST_DIR)
  .filter((f) => f.endsWith(".json"))
  .map((f) => JSON.parse(readFileSync(join(DIGEST_DIR, f), "utf8")) as Digest);

const sorted = [...digests].sort((a, b) => a.signals.total - b.signals.total);
const lowHalf = sorted.slice(0, Math.floor(sorted.length / 2));

/** 決定的なサンプリング(再実行で同じ集合を得るため乱数を使わない) */
function everyNth<T>(arr: T[], n: number): T[] {
  if (arr.length <= n) return arr;
  const step = arr.length / n;
  return Array.from({ length: n }, (_, i) => arr[Math.floor(i * step)]);
}

const picked: GoldLabel[] = [
  ...everyNth(lowHalf, LOW_SIGNAL_COUNT).map((d) => ({
    session_id: d.sessionId,
    has_learning: false, // 手で書き換える
    stratum: "low-signal" as const,
    note: "",
  })),
  ...sorted
    .slice(-HIGH_SIGNAL_COUNT)
    .map((d) => ({
      session_id: d.sessionId,
      has_learning: false,
      stratum: "high-signal" as const,
      note: "",
    })),
];

writeFileSync(OUT, picked.map((p) => JSON.stringify(p)).join("\n") + "\n");
console.log(`${picked.length} 件を ${OUT} に出力した`);
console.log("各 session_id のダイジェストを読み、has_learning と note を手で埋めること");
console.log(`ダイジェストの場所: ${DIGEST_DIR}/<session_id>.json`);
```

- [ ] **Step 2: 実行してテンプレートを作る**

Run: `node dot_claude/scripts/triage/pick-gold.ts`

- [ ] **Step 3: 20 件にラベルを付ける(手作業・約 30 分)**

各 `digests/<session_id>.json` の `text` を読み、`gold-set-template.jsonl` の `has_learning` を埋める。

**判定基準**(`harness-reflect` SKILL.md より):
- 拾う: agent の誤った前提とその根本原因 / ユーザーの訂正・押し戻し / 何度も試行してようやく正しくなったパターン / ルールと実態の乖離
- 拾わない: 再発しそうにない一回性の事情 / コードやドキュメントに既に書いてあること / そのセッション限りの文脈 / 具体性のない一般論

**必ずダイジェストだけを見てラベルを付ける。** 生の transcript を開くと、モデルが見ない情報を根拠にすることになり、測定が無意味になる。

埋め終えたら `gold-set.jsonl` にリネームする。

```bash
mv ~/.claude/harness/gold-set-template.jsonl ~/.claude/harness/gold-set.jsonl
```

- [ ] **Step 4: 陽性の数を確認する**

```bash
grep -c '"has_learning":true' ~/.claude/harness/gold-set.jsonl
grep '"stratum":"low-signal"' ~/.claude/harness/gold-set.jsonl | grep -c '"has_learning":true'
```

**低シグナル層の陽性が 0 件だった場合**、「ベースライン②を上回る」という主張は今回のデータでは検証できない。その場合は低シグナル層を 14 → 24 件に増やすか、**検証不能であること自体を結果として記録する**。取り繕わない。

- [ ] **Step 5: コミット(CLI のみ。gold-set.jsonl は個人の作業ログなのでコミットしない)**

```bash
git add dot_claude/scripts/triage/pick-gold.ts
git commit -m "feat(triage): gold set用の層化サンプリングCLIを追加"
```

---

## Task 5: Layer 2 分類器と評価(2:10-3:10)

**Files:**
- Create: `dot_claude/scripts/triage/classify.ts`
- Create: `dot_claude/scripts/triage/evaluate.ts`

**Interfaces:**
- Consumes: `ollama.ts` の `generateJson`、`types.ts` の `Digest` / `TriageVerdict` / `GoldLabel`
- Produces: `classifyDigest(digest: Digest, model: string): Promise<{ verdict: TriageVerdict; promptTokens: number; evalTokens: number; elapsedMs: number }>`

- [ ] **Step 1: classify.ts を書く**

```typescript
import { generateJson } from "./ollama.ts";
import type { Digest, TriageVerdict } from "./types.ts";

/** ollama の format に渡すスキーマ。列挙で category を縛るのが要点 */
export const TRIAGE_SCHEMA = {
  type: "object",
  properties: {
    has_learning: { type: "boolean" },
    category: {
      type: "string",
      enum: ["wrong_assumption", "user_correction", "repeated_attempts", "rule_drift", "none"],
    },
    severity: { type: "string", enum: ["high", "medium", "low"] },
    evidence: { type: "string" },
    one_line: { type: "string" },
  },
  required: ["has_learning", "category", "severity", "evidence", "one_line"],
} as const;

/**
 * 判定基準は harness-reflect SKILL.md の記述をそのまま写している。
 * ただし「迷ったらキューに入れるな」は意図的に採用しない —— Layer 2 は
 * recall 側に倒し、棄却は Layer 3(Claude)に任せる。偽陽性のコストは
 * ダイジェスト 1 件の読み込みだが、偽陰性は学びの永久喪失であり非対称。
 */
function buildPrompt(digest: Digest): string {
  return `あなたは AI コーディングエージェントの作業ログを読み、開発環境(ハーネス)の恒久的な改善につながる学びが含まれているかを判定する。

# 拾うべきもの
- エージェントが置いた誤った前提と、その根本原因
- ユーザーによる訂正・押し戻し(なぜそうしたかを含む)
- 正しくなるまでに複数回の試行を要したパターン
- ルールやドキュメントの記述と、実際の挙動との乖離

# 拾わないもの
- 再発しそうにない一回性の事情
- コードやドキュメントに既に書かれていること
- そのセッション限りの文脈で、他のセッションに波及しないもの
- 具体性のない一般論

# 判断の方針
確信が持てない場合は has_learning = true を選べ。後段の人間による精査で棄却できるが、ここで見落としたものは永久に失われる。

# evidence の書き方
has_learning が true の場合、下のログから根拠となる箇所を**原文のまま**数行引用せよ。要約や言い換えをしてはならない。後段の担当者はこの引用箇所だけを頼りに元ログを辿る。

# 作業ログ
${digest.text}`;
}

export async function classifyDigest(
  digest: Digest,
  model: string,
): Promise<{
  verdict: TriageVerdict;
  promptTokens: number;
  evalTokens: number;
  elapsedMs: number;
}> {
  const result = await generateJson<TriageVerdict>({
    model,
    prompt: buildPrompt(digest),
    schema: TRIAGE_SCHEMA as unknown as object,
    think: false, // Task 1 の実測で確定した設定に合わせること
    temperature: 0,
    numCtx: 16384, // ダイジェスト上限 12000 文字 + プロンプト分の余裕
  });
  return {
    verdict: result.value,
    promptTokens: result.promptTokens,
    evalTokens: result.evalTokens,
    elapsedMs: result.elapsedMs,
  };
}
```

- [ ] **Step 2: evaluate.ts を書く**

```typescript
#!/usr/bin/env node
/**
 * gold set に対して分類器を走らせ、層別に recall と偽陽性数を出す。
 *
 * 正解率は使わない。陽性のベースレートが低いため、「全部 false」と
 * 答えるだけのモデルが高い正解率を取ってしまい、比較の役に立たない。
 *
 * 使い方: node evaluate.ts qwen3:8b
 */
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { classifyDigest } from "./classify.ts";
import type { Digest, GoldLabel } from "./types.ts";

const model = process.argv[2] ?? "qwen3:8b";
const HARNESS_DIR = join(homedir(), ".claude", "harness");

const gold: GoldLabel[] = readFileSync(join(HARNESS_DIR, "gold-set.jsonl"), "utf8")
  .split("\n")
  .filter((l) => l.trim())
  .map((l) => JSON.parse(l) as GoldLabel);

interface Cell {
  truePositive: number;
  falseNegative: number;
  falsePositive: number;
  trueNegative: number;
}
const strata: Record<string, Cell> = {
  "low-signal": { truePositive: 0, falseNegative: 0, falsePositive: 0, trueNegative: 0 },
  "high-signal": { truePositive: 0, falseNegative: 0, falsePositive: 0, trueNegative: 0 },
};

let totalMs = 0;
for (const label of gold) {
  const digest: Digest = JSON.parse(
    readFileSync(join(HARNESS_DIR, "digests", `${label.session_id}.json`), "utf8"),
  );
  const { verdict, elapsedMs } = await classifyDigest(digest, model);
  totalMs += elapsedMs;
  const cell = strata[label.stratum];
  if (label.has_learning && verdict.has_learning) cell.truePositive++;
  else if (label.has_learning && !verdict.has_learning) cell.falseNegative++;
  else if (!label.has_learning && verdict.has_learning) cell.falsePositive++;
  else cell.trueNegative++;

  const mark = label.has_learning === verdict.has_learning ? "  " : "✗ ";
  console.log(
    `${mark}${label.stratum.padEnd(11)} 正解=${label.has_learning} 予測=${verdict.has_learning} ${Math.round(elapsedMs)}ms  ${verdict.one_line}`,
  );
}

console.log(`\n=== ${model} / 層別集計 ===`);
for (const [name, c] of Object.entries(strata)) {
  const positives = c.truePositive + c.falseNegative;
  const recall = positives === 0 ? null : c.truePositive / positives;
  console.log(
    `${name}: 陽性 ${positives} 件中 ${c.truePositive} 件を検出` +
      (recall === null ? " (陽性なし: recall 算出不能)" : ` → recall ${(recall * 100).toFixed(0)}%`) +
      ` / 偽陽性 ${c.falsePositive} 件`,
  );
}
console.log(`平均レイテンシ: ${Math.round(totalMs / gold.length)} ms/件`);
console.log(`238 件の推定所要時間: ${((totalMs / gold.length) * 238 / 60000).toFixed(1)} 分`);
```

- [ ] **Step 3: 実行して数字を得る**

Run: `node dot_claude/scripts/triage/evaluate.ts qwen3:8b`

**見るのは低シグナル層の recall。** ここが 0% なら、Layer 2 はベースライン②(シグナル数ソート)を上回っていない。

- [ ] **Step 4: プロンプトを 2〜3 回調整し、そのつど再実行する**

`temperature: 0` なので同じ入力なら同じ出力になり、変更の効果が切り分けられる。

**調整の指針:** 低シグナル層の recall が低いなら「拾うべきもの」の記述を具体化する。偽陽性が多すぎる(低シグナル層で 10 件超)なら「拾わないもの」を強める。**recall を犠牲にして偽陽性を減らす調整はしない。**

- [ ] **Step 5: コミット**

```bash
git add dot_claude/scripts/triage/classify.ts dot_claude/scripts/triage/evaluate.ts
git commit -m "feat(triage): ローカルLLMによる分類器とgold set評価を追加"
```

**打ち切り時の退避:** 3:10 を過ぎてもスキーマが安定しないなら、`TRIAGE_SCHEMA` を `{ has_learning: boolean }` の 1 プロパティに削る。`evidence` が無くても Layer 3 はダイジェスト全体を読めば動く。

---

## Task 6: モデル比較としきい値の決定(3:10-3:50)

**Files:** なし(既存 CLI の実行と記録のみ)

- [ ] **Step 1: 14B で同じ評価を回す**

Run: `node dot_claude/scripts/triage/evaluate.ts qwen3:14b`

- [ ] **Step 2: 比較表をメモに残す**

| モデル | 低シグナル層 recall | 低シグナル層 偽陽性 | 高シグナル層 recall | ms/件 | 238 件の推定時間 |
|---|---|---|---|---|---|

- [ ] **Step 3: バッチに使うモデルを決める**

判断基準: **低シグナル層 recall が同等なら 8B を選ぶ**(238 件の実行時間が短いほど、当日中に全件を回し切れる可能性が上がる)。14B が recall で明確に上回る場合のみ 14B にする。

- [ ] **Step 4: Layer 3 に渡す件数 N を決める**

`has_learning = true` の件数を 238 件全体に外挿し、**1 回の reflect セッションで読み切れる 20〜30 件**に収まる `severity` のしきい値を決める。外挿値が 30 件を大きく超えるなら `severity: high` のみに絞る。

---

## Task 7: 全件バッチ(3:50-4:50 / バックグラウンド実行)

**Files:**
- Create: `dot_claude/scripts/triage/batch.ts`
- Test: `test/triage-batch.test.ts`

**Interfaces:**
- Consumes: `classify.ts` の `classifyDigest`、`types.ts` の `TriageRecord`
- Produces: `~/.claude/harness/triage.jsonl`、`loadProcessedIds(path: string): Set<string>`

**レジューム可能であることが要件。** プロンプト調整の途中で中断・再開するため、また 238 件の途中で失敗しても最初からやり直さないため。

- [ ] **Step 1: 失敗するテストを書く**

`test/triage-batch.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadProcessedIds } from "../dot_claude/scripts/triage/batch.ts";

test("既存 triage.jsonl から処理済み session_id を読む", () => {
  const dir = mkdtempSync(join(tmpdir(), "triage-"));
  const path = join(dir, "triage.jsonl");
  writeFileSync(
    path,
    [
      JSON.stringify({ session_id: "aaa", verdict: { has_learning: true } }),
      JSON.stringify({ session_id: "bbb", verdict: { has_learning: false } }),
    ].join("\n") + "\n",
  );
  const ids = loadProcessedIds(path);
  assert.equal(ids.size, 2);
  assert.ok(ids.has("aaa"));
  assert.ok(ids.has("bbb"));
});

test("ファイルが無ければ空集合を返す", () => {
  const dir = mkdtempSync(join(tmpdir(), "triage-"));
  assert.equal(loadProcessedIds(join(dir, "missing.jsonl")).size, 0);
});

test("壊れた行があっても読める行は拾う", () => {
  const dir = mkdtempSync(join(tmpdir(), "triage-"));
  const path = join(dir, "triage.jsonl");
  // 実行中に中断すると最終行が途中で切れうる
  writeFileSync(path, JSON.stringify({ session_id: "aaa" }) + "\n{壊れた行");
  const ids = loadProcessedIds(path);
  assert.equal(ids.size, 1);
  assert.ok(ids.has("aaa"));
});
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `node --test test/triage-batch.test.ts`
Expected: FAIL(モジュールが無い)

- [ ] **Step 3: batch.ts を実装する**

```typescript
#!/usr/bin/env node
/**
 * Layer 2 バッチ: digests/ の全件を分類し triage.jsonl に追記する。
 *
 * pending.jsonl には一切触れない。SessionEnd hook が並行して追記するため、
 * 読み込んだ内容を書き戻すと、その間に記録されたセッションが黙って失われる。
 * 追記のみに徹することで、このバッチは冪等かつ再実行可能になる。
 *
 * 使い方: node batch.ts [--model qwen3:8b] [--limit 40]
 */
import { appendFileSync, readdirSync, readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { classifyDigest } from "./classify.ts";
import type { Digest, TriageRecord } from "./types.ts";

const HARNESS_DIR = join(homedir(), ".claude", "harness");
const DIGEST_DIR = join(HARNESS_DIR, "digests");
const TRIAGE = join(HARNESS_DIR, "triage.jsonl");

/** 既に分類済みの session_id を読む。中断からの再開に使う */
export function loadProcessedIds(path: string): Set<string> {
  if (!existsSync(path)) return new Set();
  const ids = new Set<string>();
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      ids.add((JSON.parse(line) as { session_id: string }).session_id);
    } catch {
      // 中断で最終行が切れている場合がある。読める行だけ拾う
    }
  }
  return ids;
}

function arg(name: string, fallback: string): string {
  const i = process.argv.indexOf(`--${name}`);
  return i > -1 ? process.argv[i + 1] : fallback;
}

const model = arg("model", "qwen3:8b");
const limit = Number(arg("limit", "0")) || Infinity;

const processed = loadProcessedIds(TRIAGE);
const files = readdirSync(DIGEST_DIR).filter((f) => f.endsWith(".json"));

const pending = files.filter((f) => !processed.has(f.replace(/\.json$/, "")));
console.log(`全 ${files.length} 件 / 処理済み ${processed.size} 件 / 今回 ${Math.min(pending.length, limit)} 件`);

let done = 0;
let failed = 0;
const startedAt = Date.now();

for (const file of pending.slice(0, limit)) {
  const digest: Digest = JSON.parse(readFileSync(join(DIGEST_DIR, file), "utf8"));
  try {
    const { verdict, promptTokens, evalTokens, elapsedMs } = await classifyDigest(digest, model);
    const record: TriageRecord = {
      session_id: digest.sessionId,
      digest_path: join(DIGEST_DIR, file),
      verdict,
      model,
      elapsed_ms: elapsedMs,
      prompt_tokens: promptTokens,
      eval_tokens: evalTokens,
      signals: digest.signals,
    };
    appendFileSync(TRIAGE, JSON.stringify(record) + "\n");
    done++;
  } catch (err) {
    // 1 件の失敗でバッチ全体を落とさない。未処理として残り、再実行で拾われる
    failed++;
    console.error(`FAIL ${digest.sessionId}: ${String(err).slice(0, 200)}`);
  }
  if (done % 10 === 0 && done > 0) {
    const perItem = (Date.now() - startedAt) / done;
    const remaining = Math.min(pending.length, limit) - done;
    console.log(
      `${done} 件完了 / 残り ${remaining} 件 / 推定残時間 ${((perItem * remaining) / 60000).toFixed(1)} 分`,
    );
  }
}

console.log(`\n完了: ${done} 件 / 失敗: ${failed} 件 / 所要 ${((Date.now() - startedAt) / 60000).toFixed(1)} 分`);
```

- [ ] **Step 4: テストを実行して通ることを確認する**

Run: `node --test test/triage-batch.test.ts`
Expected: PASS(3 tests)

- [ ] **Step 5: 少数で動作確認する**

Run: `node dot_claude/scripts/triage/batch.ts --model qwen3:8b --limit 5`

- [ ] **Step 6: 再実行して重複しないことを確認する**

Run: `node dot_claude/scripts/triage/batch.ts --model qwen3:8b --limit 5`
Expected: 「処理済み 5 件 / 今回 5 件」と表示され、先の 5 件は再処理されない

- [ ] **Step 7: 全件をバックグラウンドで流す**

```bash
node dot_claude/scripts/triage/batch.ts --model qwen3:8b > ~/.claude/harness/batch.log 2>&1 &
tail -f ~/.claude/harness/batch.log
```

**電源を接続する。** ファンレス機の持続推論はスロットリングする。バッチ実行中に Task 8 を進める。

- [ ] **Step 8: コミット**

```bash
git add dot_claude/scripts/triage/batch.ts test/triage-batch.test.ts
git commit -m "feat(triage): レジューム可能な全件バッチを追加"
```

**打ち切り時の退避:** 4:50 時点で終わっていなければ、`Ctrl-C` で止めて `triage.jsonl` にある分だけで Task 8 に進む。追記のみの設計なので、途中結果はそのまま使える。残りは初回の夜間実行に回す。

---

## Task 8: レポート生成と Layer 3 接続(4:50-5:30)

**Files:**
- Create: `dot_claude/scripts/triage/report.ts`

**Interfaces:**
- Consumes: `types.ts` の `TriageRecord`
- Produces: `~/.claude/harness/triage-report.md`

- [ ] **Step 1: report.ts を書く**

```typescript
#!/usr/bin/env node
/**
 * triage.jsonl から日本語 Markdown レポートを生成する。
 * Layer 3(Claude)の入力であり、そのまま共有用の成果物にもなる。
 *
 * 使い方: node report.ts [--top 30]
 */
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { TriageRecord } from "./types.ts";

const HARNESS_DIR = join(homedir(), ".claude", "harness");
const i = process.argv.indexOf("--top");
const TOP = i > -1 ? Number(process.argv[i + 1]) : 30;

const records: TriageRecord[] = readFileSync(join(HARNESS_DIR, "triage.jsonl"), "utf8")
  .split("\n")
  .filter((l) => l.trim())
  .map((l) => JSON.parse(l) as TriageRecord);

const SEVERITY_ORDER = { high: 0, medium: 1, low: 2 } as const;
const hits = records
  .filter((r) => r.verdict.has_learning)
  .sort((a, b) => SEVERITY_ORDER[a.verdict.severity] - SEVERITY_ORDER[b.verdict.severity]);

const totalMs = records.reduce((a, r) => a + r.elapsed_ms, 0);
const totalPromptTokens = records.reduce((a, r) => a + r.prompt_tokens, 0);

// ベースライン②との比較: LLM が拾った中で、シグナル数では上位に来なかったもの
const bySignal = [...records].sort((a, b) => b.signals.total - a.signals.total);
const signalTopIds = new Set(bySignal.slice(0, TOP).map((r) => r.session_id));
const missedBySignalSort = hits.filter((h) => !signalTopIds.has(h.session_id));

const lines: string[] = [
  "# セッション・トリアージ結果",
  "",
  `- 分類したセッション: ${records.length} 件`,
  `- 学びありと判定: ${hits.length} 件 (${((hits.length / records.length) * 100).toFixed(0)}%)`,
  `- 使用モデル: ${records[0]?.model ?? "-"}`,
  `- 総処理時間: ${(totalMs / 60000).toFixed(1)} 分 (平均 ${Math.round(totalMs / records.length)} ms/件)`,
  `- 投入プロンプトトークン合計: ${totalPromptTokens.toLocaleString()}`,
  "",
  "## ベースライン②(摩擦シグナル数ソート)との比較",
  "",
  `シグナル数の上位 ${TOP} 件に入らなかったが、ローカル LLM が学びありと判定したセッション: **${missedBySignalSort.length} 件**`,
  "",
  "これがローカル LLM の上乗せ分にあたる。0 件の場合、シグナル数を数えるだけの無料のプレフィルタで同じ結果が得られたことを意味する。",
  "",
  `## 学びありと判定された上位 ${Math.min(TOP, hits.length)} 件`,
  "",
];

for (const h of hits.slice(0, TOP)) {
  lines.push(
    `### [${h.verdict.severity}] ${h.verdict.one_line}`,
    "",
    `- session: \`${h.session_id}\``,
    `- category: ${h.verdict.category}`,
    `- signals: total=${h.signals.total} (int=${h.signals.interrupts} err=${h.signals.toolErrors} neg=${h.signals.userNegations})`,
    `- digest: \`${h.digest_path}\``,
    "",
    "根拠:",
    "",
    "```",
    h.verdict.evidence.slice(0, 800),
    "```",
    "",
  );
}

const out = join(HARNESS_DIR, "triage-report.md");
writeFileSync(out, lines.join("\n"));
console.log(`${out} に出力した (学びあり ${hits.length} 件 / 上位 ${TOP} 件を掲載)`);
```

- [ ] **Step 2: レポートを生成する**

Run: `node dot_claude/scripts/triage/report.ts --top 30`

- [ ] **Step 3: Layer 3 を 1〜2 件で試す**

Claude のセッションで以下を行い、既存フローに接続できることを確認する。

1. `~/.claude/harness/triage-report.md` の上位 2 件を読む
2. 各件の `digest` パスから、`evidence` に対応する箇所だけを読む
3. `harness-reflect` SKILL.md の書式(英語)で `queue.md` にエントリを追記する
4. **`pending.jsonl` の削除は SKILL.md の作法通りに行う**(`grep -vF` で今の状態からフィルタし temp ファイル経由で `mv`。読み込んだコピーを書き戻さない)

**全件を投入しない。** 接続が成立することの確認が目的であり、キューを一気に膨らませると次の `/harness-review` が回らなくなる。

- [ ] **Step 4: コミット**

```bash
git add dot_claude/scripts/triage/report.ts
git commit -m "feat(triage): 日本語トリアージレポートの生成を追加"
```

---

## Task 9: 結果のまとめ(5:30-6:00)

**Files:**
- Create: `docs/superpowers/plans/2026-08-27-local-llm-session-triage-results.md`

- [ ] **Step 1: 数字を 1 ファイルにまとめる**

以下を埋める。**思わしくない結果もそのまま書く。**

```markdown
# セッション・トリアージ 実施結果

日付: 2026-08-27

## 環境
- モデル: (8B / 14B のどちらを採用したか、およびその理由)
- thinking: (有効 / 無効。Task 1 での実測差)

## Layer 1(決定論)
- 対象セッション: N 件
- 元サイズ合計: X MB → ダイジェスト合計トークン Y
- 圧縮率: Z 倍
- **ベースライン①: 合計 Y トークンが 1M コンテキストに収まったか**
- 切り詰めたセッション: N 件

## Layer 2(ローカル LLM)
- gold set: 20 件(低シグナル 14 / 高シグナル 6)、うち陽性 N 件
- 低シグナル層 recall: N%(← 主指標)
- 低シグナル層 偽陽性: N 件
- 高シグナル層 recall: N%
- 8B vs 14B の比較表
- スループット: N ms/件、238 件で N 分

## ベースライン②(摩擦シグナル数ソート)との比較
- シグナル上位 30 件に入らず、LLM が拾ったセッション: N 件
- **この数字が 0 なら、ローカル LLM は無料のプレフィルタを上回っていない**

## 結論
- (ローカル LLM は何を上乗せしたか。上乗せが無かったならそう書く)
- (この仕組みを常用するか。するなら次に何が要るか)

## 積み残し
```

- [ ] **Step 2: コミット**

```bash
git add docs/superpowers/plans/2026-08-27-local-llm-session-triage-results.md
git commit -m "docs(triage): 合宿での実施結果を記録"
```

- [ ] **Step 3: lint を通す**

Run: `just lint`
Expected: PASS(oxlint / oxfmt が新規 TS を拾う。落ちたら `pnpm exec oxfmt dot_claude/scripts/triage/*.ts` で整形)

---

## 積み残し(合宿では作らない)

- **cron 化(夜間自動実行)** — 常用すると決めてから。launchd plist を `dot_local/` に置く形になる
- **`/harness-reflect` からの自動呼び出し** — Layer 3 の手順が固まってから
- **`pending.jsonl` の自動削除** — 既存 SKILL の作法に委ねたまま変更しない
- **埋め込みによる過去セッション検索** — 別プロジェクト
