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
import { appendFileSync, existsSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { classifyDigest } from "./classify.ts";
import type { Digest, TriageRecord } from "./types.ts";

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

// テストが loadProcessedIds を import しただけでバッチが走らないよう、
// CLI 本体は直接実行時のみ動かす
if (import.meta.main) {
  const HARNESS_DIR = join(homedir(), ".claude", "harness");
  const DIGEST_DIR = join(HARNESS_DIR, "digests");
  const TRIAGE = join(HARNESS_DIR, "triage.jsonl");

  const arg = (name: string, fallback: string): string => {
    const i = process.argv.indexOf(`--${name}`);
    return i > -1 ? process.argv[i + 1] : fallback;
  };

  const model = arg("model", "qwen3:8b");
  const limit = Number(arg("limit", "0")) || Infinity;

  const processed = loadProcessedIds(TRIAGE);
  const files = readdirSync(DIGEST_DIR).filter((f) => f.endsWith(".json"));

  const pending = files.filter((f) => !processed.has(f.replace(/\.json$/, "")));
  console.log(
    `全 ${files.length} 件 / 処理済み ${processed.size} 件 / 今回 ${Math.min(pending.length, limit)} 件`,
  );

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

  console.log(
    `\n完了: ${done} 件 / 失敗: ${failed} 件 / 所要 ${((Date.now() - startedAt) / 60000).toFixed(1)} 分`,
  );
}
