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
