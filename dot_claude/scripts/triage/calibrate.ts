#!/usr/bin/env node
/**
 * estimateTokens の係数を ollama の実測 prompt_eval_count で較正する。
 * ベースライン①(ダイジェスト合計トークン数)を推定から実測ベースに直すために使う。
 *
 * 使い方: node calibrate.ts [model]
 */
import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { generateJson } from "./ollama.ts";
import { estimateTokens } from "./signals.ts";
import type { Digest } from "./types.ts";

const DIGEST_DIR = join(homedir(), ".claude", "harness", "digests");
const NUM_CTX = 16384;

// 最大級 2 件 + 中央値 1 件で較正する。最大級を含めるのは、コンテキスト溢れが
// 起きるならそこで起きるため(溢れると ollama は先頭を黙って捨て、以降の
// 測定がすべて切り詰められた入力に対するものになる)。
const all: Digest[] = readdirSync(DIGEST_DIR)
  .filter((f) => f.endsWith(".json"))
  .map((f) => JSON.parse(readFileSync(join(DIGEST_DIR, f), "utf8")) as Digest)
  .sort((a, b) => b.text.length - a.text.length);
const samples = [all[0], all[1], all[Math.floor(all.length / 2)]].filter(Boolean);

let estimated = 0;
let actual = 0;
for (const digest of samples) {
  // 中身の判定は不要。プロンプトを投入した際のトークン数だけが欲しい
  const r = await generateJson<{ ok: boolean }>({
    model: process.argv[2] ?? "qwen3:8b",
    prompt: digest.text,
    schema: { type: "object", properties: { ok: { type: "boolean" } }, required: ["ok"] },
    think: false,
    numCtx: NUM_CTX,
  });
  if (r.promptTokens > NUM_CTX * 0.9) {
    throw new Error(
      `コンテキスト溢れの疑い: ${digest.sessionId} の実測 ${r.promptTokens} トークンが ` +
        `num_ctx ${NUM_CTX} の 90% を超えた。以降の recall 測定が切り詰められた入力に ` +
        `対するものになるため、--max-chars を下げてダイジェストを作り直すこと`,
    );
  }
  const est = estimateTokens(digest.text);
  estimated += est;
  actual += r.promptTokens;
  console.log(
    `${digest.sessionId}: 概算 ${est} / 実測 ${r.promptTokens} (比 ${(r.promptTokens / est).toFixed(2)})`,
  );
}
console.log(`\n補正係数: ${(actual / estimated).toFixed(3)}`);
console.log("ベースライン①の合計トークンにこの係数を掛けた値を、実測ベースの数字として記録する");
