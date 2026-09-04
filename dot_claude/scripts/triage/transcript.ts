/** ダイジェストに残る 1 行 */
export interface DigestLine {
  role: "user" | "assistant" | "error";
  text: string;
}

/** 判断に寄与しない行の type。実データの出現頻度順 */
const DROP_TYPES = new Set([
  "attachment",
  "last-prompt",
  "mode",
  "permission-mode",
  "ai-title",
  "file-history-delta",
  "file-history-snapshot",
  "queue-operation",
  "atis-latch",
  "system",
]);

/** スラッシュコマンド実行の副産物。ユーザーの意図を含まない */
const NOISE_PATTERNS = [
  /<command-name>/,
  /<command-message>/,
  /<command-args>/,
  /<local-command-stdout>/,
  /<local-command-caveat>/,
  /^Base directory for this skill:/,
];

function isNoise(text: string): boolean {
  return NOISE_PATTERNS.some((p) => p.test(text));
}

/** 1 行分のテキストを整形する。空白の潰しと長すぎる行の頭打ち */
function normalize(text: string): string {
  return text.replace(/\s+/g, " ").trim().slice(0, 2000);
}

/**
 * transcript の生の行配列から、判断に必要な行だけを抜き出す。
 * I/O を持たない純関数なので、巨大ファイルを用意せずテストできる。
 */
export function extractLines(rawLines: string[]): DigestLine[] {
  const out: DigestLine[] = [];
  for (const raw of rawLines) {
    let entry: { type?: string; message?: { content?: unknown } };
    try {
      entry = JSON.parse(raw);
    } catch {
      continue; // 壊れた行は捨てる。1.3GB のログには必ず混ざる
    }
    const type = entry.type;
    if (!type || DROP_TYPES.has(type)) continue;
    const content = entry.message?.content;

    if (typeof content === "string") {
      const text = normalize(content);
      if (!text || isNoise(text)) continue;
      if (type === "user" || type === "assistant") {
        out.push({ role: type, text });
      }
      continue;
    }

    if (Array.isArray(content)) {
      for (const block of content) {
        if (!block || typeof block !== "object") continue;
        const b = block as {
          type?: string;
          text?: string;
          is_error?: boolean;
          content?: unknown;
        };
        if (b.type === "text" && typeof b.text === "string") {
          const text = normalize(b.text);
          if (!text || isNoise(text)) continue;
          out.push({ role: type === "assistant" ? "assistant" : "user", text });
        } else if (b.type === "tool_result" && b.is_error === true) {
          const text = normalize(
            typeof b.content === "string" ? b.content : JSON.stringify(b.content ?? ""),
          );
          if (text) out.push({ role: "error", text });
        }
        // tool_use は捨てる: 何をしたかは assistant のテキストと error で足りる
      }
    }
  }
  return out;
}

const OMIT_MARKER = "\n…(中略)…\n";

/**
 * ダイジェスト行を 1 つのテキストに整形する。
 * 上限を超える場合は head+tail を残す。冒頭には依頼、末尾には結末が出るため、
 * 中間を削るのが判断への損失が最も小さい。
 */
export function renderDigest(
  lines: DigestLine[],
  maxChars: number,
): { text: string; truncated: boolean } {
  const rendered = lines.map((l) => `[${l.role}] ${l.text}`);
  const full = rendered.join("\n");
  if (full.length <= maxChars) return { text: full, truncated: false };

  const half = Math.floor(maxChars / 2);
  const head = full.slice(0, half);
  const tail = full.slice(full.length - half);
  return { text: head + OMIT_MARKER + tail, truncated: true };
}
