import { test } from "node:test";
import assert from "node:assert/strict";
import { countSignals, estimateTokens } from "../dot_claude/scripts/triage/signals.ts";
import type { DigestLine } from "../dot_claude/scripts/triage/transcript.ts";

test("割り込み・ツールエラー・否定発言をそれぞれ数える", () => {
  const lines: DigestLine[] = [
    { role: "user", text: "[Request interrupted by user]" },
    { role: "error", text: "command not found" },
    { role: "error", text: "permission denied" },
    { role: "user", text: "違う、そうじゃない" },
    { role: "assistant", text: "承知しました" },
  ];
  const s = countSignals(lines);
  assert.equal(s.interrupts, 1);
  assert.equal(s.toolErrors, 2);
  assert.equal(s.userNegations, 1);
  assert.equal(s.total, 4);
});

test("長い user 発言は否定語を含んでも否定発言に数えない", () => {
  const lines: DigestLine[] = [
    {
      role: "user",
      text: "この実装は違うアプローチも検討できますが、".padEnd(200, "詳細な説明が続く"),
    },
  ];
  // 短い押し戻しだけをシグナルとする。長文は通常の指示なので除外する
  assert.equal(countSignals(lines).userNegations, 0);
});

test("トークン数の概算は日本語で文字数を下回らない", () => {
  // 日本語は 1 文字あたり 1 トークン前後になりうるため、安全側に見積もる
  assert.ok(estimateTokens("あいうえお") >= 5);
  assert.ok(estimateTokens("hello world foo bar") < 19);
});
