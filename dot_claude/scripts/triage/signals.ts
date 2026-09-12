import type { DigestLine } from "./transcript.ts";
import type { FrictionSignals } from "./types.ts";

/** 短い押し戻し発言。長文の指示に紛れる同じ語は数えない */
const NEGATION_PATTERNS = [
  /違う/,
  /そうじゃな/,
  /やめて/,
  /間違/,
  /戻して/,
  /なんで/,
  /ダメ/,
  /不要/,
];
const NEGATION_MAX_CHARS = 60;

/** ユーザーが agent を止めた印。実データに存在を確認済み */
const INTERRUPT_PATTERN = /\[Request interrupted by user\]/;

export function countSignals(lines: DigestLine[]): FrictionSignals {
  let interrupts = 0;
  let toolErrors = 0;
  let userNegations = 0;

  for (const line of lines) {
    if (line.role === "error") {
      toolErrors++;
      continue;
    }
    if (INTERRUPT_PATTERN.test(line.text)) {
      interrupts++;
      continue;
    }
    if (
      line.role === "user" &&
      line.text.length <= NEGATION_MAX_CHARS &&
      NEGATION_PATTERNS.some((p) => p.test(line.text))
    ) {
      userNegations++;
    }
  }
  return {
    interrupts,
    toolErrors,
    userNegations,
    total: interrupts + toolErrors + userNegations,
  };
}

/**
 * トークン数の概算。日本語混じりのため 1 文字 = 1 トークンに近づく分を見込み、
 * ASCII は 4 文字 = 1 トークンとして数える。Task 1 で得た ollama の
 * prompt_eval_count と突き合わせて係数を較正すること。
 */
export function estimateTokens(text: string): number {
  let ascii = 0;
  let wide = 0;
  for (const ch of text) {
    if (ch.charCodeAt(0) < 128) ascii++;
    else wide++;
  }
  return Math.ceil(ascii / 4) + wide;
}
