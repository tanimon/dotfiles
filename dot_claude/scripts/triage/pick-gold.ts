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
  ...sorted.slice(-HIGH_SIGNAL_COUNT).map((d) => ({
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
