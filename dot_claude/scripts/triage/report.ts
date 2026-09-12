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

const SEVERITY_ORDER = { high: 0, medium: 1, low: 2 } as const;

/**
 * Layer 3 に渡す優先順位: severity 優先、同値なら摩擦シグナル数の降順。
 * severity 単独では 8B が medium に縮退させて機能しないことが gold set 評価で
 * 分かっているため、決定論的なシグナル数を第2キーに入れてランキングを保つ。
 */
export function compareTriageHits(a: TriageRecord, b: TriageRecord): number {
  const bySeverity = SEVERITY_ORDER[a.verdict.severity] - SEVERITY_ORDER[b.verdict.severity];
  if (bySeverity !== 0) return bySeverity;
  return b.signals.total - a.signals.total;
}

/**
 * Layer 3 に渡す候補の選択。LLM の true 判定に加え、interrupts >= 1 の
 * セッションを決定論で必ず含める。ユーザー割り込み→言い直しは gold set 上
 * 偽陽性ゼロの強い訂正シグナルだが、8B はプロンプト調整 3 回でも
 * 安定して拾えなかった(v3.2 時点)。全体の 1 割未満なので常時採用が安い。
 */
export function isLayer3Candidate(record: TriageRecord): boolean {
  return record.verdict.has_learning || record.signals.interrupts >= 1;
}

if (import.meta.main) {
  const HARNESS_DIR = join(homedir(), ".claude", "harness");
  const i = process.argv.indexOf("--top");
  const TOP = i > -1 ? Number(process.argv[i + 1]) : 30;

  const records: TriageRecord[] = readFileSync(join(HARNESS_DIR, "triage.jsonl"), "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l) as TriageRecord);

  const hits = records.filter(isLayer3Candidate).sort(compareTriageHits);
  const overrides = hits.filter((r) => !r.verdict.has_learning).length;

  const totalMs = records.reduce((a, r) => a + r.elapsed_ms, 0);
  const totalPromptTokens = records.reduce((a, r) => a + r.prompt_tokens, 0);

  // ベースライン②との比較: LLM が拾った中で、シグナル数では上位に来なかったもの。
  // interrupts オーバーライドで採用された候補はシグナル規則による選出なので、
  // ここに混ぜると LLM の上乗せをベースライン自身の選出で水増ししてしまう。
  // 必ず LLM 単独の true 判定だけで数える
  const bySignal = [...records].sort((a, b) => b.signals.total - a.signals.total);
  const signalTopIds = new Set(bySignal.slice(0, TOP).map((r) => r.session_id));
  const missedBySignalSort = hits.filter(
    (h) => h.verdict.has_learning && !signalTopIds.has(h.session_id),
  );

  const lines: string[] = [
    "# セッション・トリアージ結果",
    "",
    `- 分類したセッション: ${records.length} 件`,
    `- Layer 3 候補: ${hits.length} 件 (${((hits.length / records.length) * 100).toFixed(0)}%、うち LLM は false だが割り込みシグナルで採用: ${overrides} 件)`,
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
    const overrideMark = h.verdict.has_learning ? "" : "(割り込みシグナルによる採用)";
    lines.push(
      `### [${h.verdict.severity}] ${h.verdict.one_line}${overrideMark}`,
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
}
