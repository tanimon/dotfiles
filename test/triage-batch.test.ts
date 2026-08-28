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
