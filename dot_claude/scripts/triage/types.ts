/** ~/.claude/harness/pending.jsonl の 1 行 */
export interface PendingEntry {
  session_id: string;
  transcript_path: string;
  cwd: string;
  recorded_epoch: number;
}

/** 決定論的に数えられる摩擦シグナル */
export interface FrictionSignals {
  /** [Request interrupted by user] の出現回数 */
  interrupts: number;
  /** tool_result で is_error だったものの件数 */
  toolErrors: number;
  /** ユーザーの短い否定・押し戻し発言の件数 */
  userNegations: number;
  /** 上記の単純合計。ベースライン②のランキングキー */
  total: number;
}

/** ダイジェスト 1 件 */
export interface Digest {
  sessionId: string;
  cwd: string;
  recordedEpoch: number;
  /** ダイジェスト本文(モデルに渡すテキスト) */
  text: string;
  signals: FrictionSignals;
  /** 概算トークン数。Task 1 で実測較正した係数を使う */
  approxTokens: number;
  /** トークン上限で切り詰めたか */
  truncated: boolean;
  /** 元 transcript のバイト数(圧縮率の算出用) */
  originalBytes: number;
}

export type TriageCategory =
  | "wrong_assumption"
  | "user_correction"
  | "repeated_attempts"
  | "rule_drift"
  | "none";

export type TriageSeverity = "high" | "medium" | "low";

/** ローカル LLM が返す判断。この形をスキーマで強制する */
export interface TriageVerdict {
  has_learning: boolean;
  category: TriageCategory;
  severity: TriageSeverity;
  /** ダイジェスト中の根拠となる引用。Layer 3 はここだけを読む */
  evidence: string;
  /** 日本語 1 行の要約 */
  one_line: string;
}

/** triage.jsonl の 1 行 */
export interface TriageRecord {
  session_id: string;
  /** ダイジェスト JSON のパス。元 transcript ではない(Layer 3 はこちらを読む) */
  digest_path: string;
  verdict: TriageVerdict;
  model: string;
  elapsed_ms: number;
  prompt_tokens: number;
  eval_tokens: number;
  signals: FrictionSignals;
}

/** gold-set.jsonl の 1 行 */
export interface GoldLabel {
  session_id: string;
  /** 人手で付けた二値ラベル */
  has_learning: boolean;
  /** "low-signal" か "high-signal"。集計時に混ぜない */
  stratum: "low-signal" | "high-signal";
  /** ラベルを付けた理由(後で自分が見返すため) */
  note: string;
}
