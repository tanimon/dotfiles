#!/usr/bin/env node
/**
 * gold set 用にダイジェストを層化サンプリングし、ラベル付けの雛形を出力する。
 *
 * 主層を「低シグナル層」にするのは、ベースライン②(シグナル数ソート)を
 * 上回るという主張が、そこにしか根拠を持たないため。シグナル上位で陽性を
 * 当てても、それはベースライン②が既に指している集団である。
 *
 * 使い方:
 *   node pick-gold.ts            # 新規に gold-set-template.jsonl を出力
 *   node pick-gold.ts --extend   # 既存 gold-set.jsonl の session_id を除外して追加分を出力
 */
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Digest, GoldLabel } from "./types.ts";

const HARNESS_DIR = join(homedir(), ".claude", "harness");
const DIGEST_DIR = join(HARNESS_DIR, "digests");
const GOLD = join(HARNESS_DIR, "gold-set.jsonl");
const OUT = join(HARNESS_DIR, "gold-set-template.jsonl");

const LOW_SIGNAL_COUNT = 14;
const HIGH_SIGNAL_COUNT = 6;

const isExtend = process.argv.includes("--extend");

// --extend: 既存 gold set に含まれる session_id は抽出対象から除外する
const excluded = new Set<string>();
if (isExtend) {
  if (!existsSync(GOLD)) {
    console.error(`--extend には既存の ${GOLD} が必要`);
    process.exit(1);
  }
  for (const line of readFileSync(GOLD, "utf8").split("\n")) {
    if (!line.trim()) continue;
    excluded.add((JSON.parse(line) as GoldLabel).session_id);
  }
}

const digests: Digest[] = readdirSync(DIGEST_DIR)
  .filter((f) => f.endsWith(".json"))
  .map((f) => JSON.parse(readFileSync(join(DIGEST_DIR, f), "utf8")) as Digest)
  .filter((d) => !excluded.has(d.sessionId));

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
  ...sorted.slice(-HIGH_SIGNAL_COUNT).map((d) => ({
    session_id: d.sessionId,
    has_learning: false,
    stratum: "high-signal" as const,
    note: "",
  })),
];

writeFileSync(OUT, picked.map((p) => JSON.stringify(p)).join("\n") + "\n");
console.log(
  `${picked.length} 件を ${OUT} に出力した` + (isExtend ? `(既存 ${excluded.size} 件を除外)` : ""),
);
console.log("各 session_id のダイジェストを読み、has_learning と note を手で埋めること");
console.log(`ダイジェストの場所: ${DIGEST_DIR}/<session_id>.json`);
