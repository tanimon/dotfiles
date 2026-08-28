/**
 * ollama の挙動確認と tok/s 実測。モデル入れ替え時の再測定にも使う。
 *
 * 確認事項:
 * 1. think: false で <think> ブロックが出ないこと
 * 2. think の切り替えで evalTokens / elapsedMs がどれだけ変わるか
 * 3. スキーマ外のキーが混ざらないこと
 *
 * 使い方: node probe.ts [model]
 */
import { generateJson } from "./ollama.ts";

const model = process.argv[2] ?? "qwen3:8b";

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
    model,
    prompt: "次の作業ログに改善の学びがあるか判定せよ: ユーザーが3回同じ修正を指示し直した。",
    schema,
    think,
  });
  const evalTokPerSec = r.evalTokens / (r.elapsedMs / 1000);
  console.log({
    model,
    think,
    ms: r.elapsedMs,
    evalTokens: r.evalTokens,
    promptTokens: r.promptTokens,
    evalTokPerSec: Math.round(evalTokPerSec * 10) / 10,
    raw: r.raw.slice(0, 200),
  });
}
