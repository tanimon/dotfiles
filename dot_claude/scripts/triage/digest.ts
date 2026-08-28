#!/usr/bin/env node
/**
 * Layer 1 CLI: pending.jsonl の全エントリをダイジェスト化する。
 *
 * pending.jsonl は読み取り専用。SessionEnd hook が並行追記するため、
 * このスクリプトは一切書き戻さない。
 *
 * 使い方: node digest.ts [--max-chars 12000]
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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
    originalBytes: Buffer.byteLength(raw), // raw.length は文字数であり日本語でバイト数を過小評価する
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
