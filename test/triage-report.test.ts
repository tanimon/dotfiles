import { test } from "node:test";
import assert from "node:assert/strict";
import { compareTriageHits, isLayer3Candidate } from "../dot_claude/scripts/triage/report.ts";
import type { TriageRecord } from "../dot_claude/scripts/triage/types.ts";

function record(severity: "high" | "medium" | "low", signalTotal: number): TriageRecord {
  return {
    session_id: `s-${severity}-${signalTotal}`,
    digest_path: "/dev/null",
    verdict: {
      has_learning: true,
      category: "wrong_assumption",
      severity,
      evidence: "",
      one_line: "",
    },
    model: "test",
    elapsed_ms: 0,
    prompt_tokens: 0,
    eval_tokens: 0,
    signals: { interrupts: 0, toolErrors: signalTotal, userNegations: 0, total: signalTotal },
  };
}

test("severity が異なれば severity 順(high が先)", () => {
  const sorted = [record("low", 99), record("high", 0), record("medium", 50)].sort(
    compareTriageHits,
  );
  assert.deepEqual(
    sorted.map((r) => r.verdict.severity),
    ["high", "medium", "low"],
  );
});

test("LLM が true なら候補になる", () => {
  assert.equal(isLayer3Candidate(record("medium", 0)), true);
});

test("LLM が false でも interrupts>=1 なら候補になる(決定論オーバーライド)", () => {
  const r = record("low", 1);
  r.verdict.has_learning = false;
  r.signals.interrupts = 1;
  assert.equal(isLayer3Candidate(r), true);
});

test("LLM が false かつ interrupts=0 なら候補にならない", () => {
  const r = record("low", 3);
  r.verdict.has_learning = false;
  assert.equal(isLayer3Candidate(r), false);
});

test("severity が同じならシグナル数の降順", () => {
  const sorted = [record("medium", 1), record("medium", 10), record("medium", 5)].sort(
    compareTriageHits,
  );
  assert.deepEqual(
    sorted.map((r) => r.signals.total),
    [10, 5, 1],
  );
});
