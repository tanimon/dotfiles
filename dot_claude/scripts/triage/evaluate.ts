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
let evaluated = 0;
let errors = 0;
for (const label of gold) {
  const digest: Digest = JSON.parse(
    readFileSync(join(HARNESS_DIR, "digests", `${label.session_id}.json`), "utf8"),
  );
  let verdict, elapsedMs;
  try {
    ({ verdict, elapsedMs } = await classifyDigest(digest, model));
  } catch (err) {
    // 1 件の失敗で評価全体を落とさない。集計から除外して件数を報告する
    errors++;
    console.log(`✗ ${label.stratum.padEnd(11)} 分類エラー: ${String(err).slice(0, 120)}`);
    continue;
  }
  evaluated++;
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
      (recall === null
        ? " (陽性なし: recall 算出不能)"
        : ` → recall ${(recall * 100).toFixed(0)}%`) +
      ` / 偽陽性 ${c.falsePositive} 件`,
  );
}
if (errors > 0) console.log(`分類エラーで集計から除外: ${errors} 件`);
console.log(`平均レイテンシ: ${Math.round(totalMs / evaluated)} ms/件`);
console.log(`238 件の推定所要時間: ${(((totalMs / evaluated) * 238) / 60000).toFixed(1)} 分`);
