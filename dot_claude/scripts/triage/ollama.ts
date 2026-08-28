const OLLAMA_URL = process.env.OLLAMA_URL ?? "http://localhost:11434";

export interface OllamaResult<T> {
  value: T;
  /** ollama が報告する実測プロンプトトークン数 */
  promptTokens: number;
  /** 実測生成トークン数 */
  evalTokens: number;
  elapsedMs: number;
  /** 生のレスポンス文字列(パース失敗時の診断用) */
  raw: string;
}

export interface GenerateJsonOptions {
  model: string;
  prompt: string;
  /** JSON Schema。ollama の format に渡してデコードを制約する */
  schema: object;
  /** Qwen3 等のハイブリッド推論モデルの thinking を切る */
  think?: boolean;
  /** 決定性のため既定 0 */
  temperature?: number;
  /** コンテキスト長。ダイジェストが入り切る値にする */
  numCtx?: number;
}

/**
 * ollama に 1 回だけ問い合わせ、スキーマに従う JSON を得る。
 * ストリームは使わない(1 件 1 判断なので待てばよい)。
 */
export async function generateJson<T>(opts: GenerateJsonOptions): Promise<OllamaResult<T>> {
  const started = Date.now();
  const res = await fetch(`${OLLAMA_URL}/api/generate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: opts.model,
      prompt: opts.prompt,
      format: opts.schema,
      stream: false,
      think: opts.think ?? false,
      options: {
        temperature: opts.temperature ?? 0,
        num_ctx: opts.numCtx ?? 8192,
      },
    }),
  });
  if (!res.ok) {
    throw new Error(`ollama ${res.status}: ${await res.text()}`);
  }
  const body = (await res.json()) as {
    response: string;
    prompt_eval_count?: number;
    eval_count?: number;
  };
  return {
    value: JSON.parse(body.response) as T,
    promptTokens: body.prompt_eval_count ?? 0,
    evalTokens: body.eval_count ?? 0,
    elapsedMs: Date.now() - started,
    raw: body.response,
  };
}
