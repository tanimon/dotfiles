import { test } from "node:test";
import assert from "node:assert/strict";
import { extractLines, renderDigest } from "../dot_claude/scripts/triage/transcript.ts";

/** テスト用に transcript の 1 行を作る */
function line(obj: unknown): string {
  return JSON.stringify(obj);
}

test("attachment 行と各種メタ行を捨てる", () => {
  const raw = [
    line({ type: "attachment", message: { content: "巨大なファイル内容" } }),
    line({ type: "last-prompt", message: { content: "x" } }),
    line({ type: "mode", message: { content: "x" } }),
    line({ type: "permission-mode", message: { content: "x" } }),
    line({ type: "ai-title", message: { content: "x" } }),
    line({ type: "user", message: { content: "本文だけ残る" } }),
  ];
  const result = extractLines(raw);
  assert.equal(result.length, 1);
  assert.equal(result[0].text, "本文だけ残る");
  assert.equal(result[0].role, "user");
});

test("スラッシュコマンド由来のノイズ行を捨てる", () => {
  const raw = [
    line({ type: "user", message: { content: "<command-name>/model</command-name>" } }),
    line({
      type: "user",
      message: { content: "<local-command-stdout>Set model to X</local-command-stdout>" },
    }),
    line({ type: "user", message: { content: "普通の指示" } }),
  ];
  const result = extractLines(raw);
  assert.deepEqual(
    result.map((r) => r.text),
    ["普通の指示"],
  );
});

test("assistant のテキストブロックを残し tool_use は捨てる", () => {
  const raw = [
    line({
      type: "assistant",
      message: {
        content: [
          { type: "text", text: "説明します" },
          { type: "tool_use", name: "Read", input: { file_path: "/x" } },
        ],
      },
    }),
  ];
  const result = extractLines(raw);
  assert.deepEqual(
    result.map((r) => r.text),
    ["説明します"],
  );
});

test("tool_result のエラーを error ロールとして残す", () => {
  const raw = [
    line({
      type: "user",
      message: {
        content: [
          { type: "tool_result", is_error: true, content: "command not found: foo" },
          { type: "tool_result", is_error: false, content: "成功したので不要" },
        ],
      },
    }),
  ];
  const result = extractLines(raw);
  assert.equal(result.length, 1);
  assert.equal(result[0].role, "error");
  assert.match(result[0].text, /command not found/);
});

test("[Request interrupted by user] を残す", () => {
  const raw = [line({ type: "user", message: { content: "[Request interrupted by user]" } })];
  const result = extractLines(raw);
  assert.equal(result.length, 1);
  assert.match(result[0].text, /interrupted/);
});

test("壊れた JSON 行は黙って飛ばす", () => {
  const raw = ["{壊れている", line({ type: "user", message: { content: "生き残る" } })];
  const result = extractLines(raw);
  assert.deepEqual(
    result.map((r) => r.text),
    ["生き残る"],
  );
});

test("上限を超えたら head+tail で切り詰め truncated を立てる", () => {
  const lines = Array.from({ length: 100 }, (_, i) => ({
    role: "user" as const,
    text: `行${i}`.padEnd(50, "あ"),
  }));
  const { text, truncated } = renderDigest(lines, 500);
  assert.equal(truncated, true);
  assert.ok(text.length <= 700, "上限+マーカー程度に収まる");
  assert.match(text, /行0/, "先頭は残る");
  assert.match(text, /行99/, "末尾も残る");
  assert.match(text, /中略/, "省略マーカーが入る");
});
