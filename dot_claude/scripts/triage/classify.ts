import { generateJson } from "./ollama.ts";
import type { Digest, TriageVerdict } from "./types.ts";

/** ollama の format に渡すスキーマ。列挙で category を縛るのが要点 */
export const TRIAGE_SCHEMA = {
  type: "object",
  properties: {
    has_learning: { type: "boolean" },
    category: {
      type: "string",
      enum: ["wrong_assumption", "user_correction", "repeated_attempts", "rule_drift", "none"],
    },
    severity: { type: "string", enum: ["high", "medium", "low"] },
    evidence: { type: "string" },
    one_line: { type: "string" },
  },
  required: ["has_learning", "category", "severity", "evidence", "one_line"],
} as const;

/**
 * 判定基準は harness-reflect SKILL.md の記述をベースにしている。
 * ただし「迷ったらキューに入れるな」は意図的に採用しない —— Layer 2 は
 * recall 側に倒し、棄却は Layer 3(Claude)に任せる。偽陽性のコストは
 * ダイジェスト 1 件の読み込みだが、偽陰性は学びの永久喪失であり非対称。
 *
 * v3: v2 の gold set 評価で観測した偽陽性の典型(作業対象コードの発見・
 * 検証作業そのもの・セッション内で文書化済みの事故)を反例として明示し、
 * 「ルール」の指す範囲を限定し、severity のアンカーを定義した。
 */
function buildPrompt(digest: Digest): string {
  return `あなたは AI コーディングエージェントの作業ログを読み、「エージェント自身の振る舞い・開発環境(ツール、スキル、ルール、サンドボックス、ワークフロー)」に関する恒久的な学びが含まれているかを判定する。

# 最重要の区別
学びの対象は**エージェントの作業プロセス**であって、**作業対象のコードやドキュメント**ではない。
- セッションの作業内容そのもの(コードのバグ修正、PR 説明の乖離の修正、レビュー指摘への対応、設計判断)は、どれほど興味深くても学びではない。それはそのセッションの成果物であり、コードや PR に既に反映されている。
- 「ルール」とは**エージェント自身に与えられた指示・スキル・CLAUDE.md・運用規約**を指す。作業対象のコードとそのドキュメント・コメント・PR 説明の食い違いは「ルールの乖離」ではない。
- 学びとは「次の別セッションでエージェントが同じ失敗を繰り返さないために、ルールやスキルに書き足すべきこと」である。

# 拾うべきもの(エージェントのプロセスに関するものだけ)
- エージェントが誤った前提を置き、後で覆された(例: 存在しないファイルが存在すると思い込んだ、古い出力を実在と誤認した)
- ユーザーがエージェントの進め方を訂正・中断した(例: 質問に答えず作業を始めて止められた、意図と違う方法を選んで言い直された)。**ログ中に [Request interrupted by user] があり、直後にユーザーが要求を言い直している場合は、内容がどう見えてもこの型に該当する(割り込み自体が「進め方が違った」証拠)**
- ツールや環境の非自明な仕様に何度も試行してようやく気づいた(例: コマンドのフラグの誤解、サンドボックスの制約、API の落とし穴)
- 環境の制約で最初のアプローチが失敗し、**別のツール・手段に切り替えて**成功した(例: SSH での取得が塞がれ API 経由に切り替えた)。切り替え先の手段自体が、次のセッションで最初から使うべき知識になる
- エージェントが従うべきルール・スキルの記述と、実際の挙動が食い違っていた

# 拾わないもの(実際のログで多い誤判定の型)
- 「PR 説明・コメント・チケットの記述が実装と食い違っていたので直した」→ それが作業内容そのもの。false
- 「grep・diff・テスト・静的解析で確認した / 乖離を発見して修正した」→ 通常の検証ワークフロー。false
- 「レビュー指摘を検証し、対応または理由付きで見送った」→ 通常のレビュー対応。false
- 失敗や事故が起きたが、**そのセッション内で修正とルール・ドキュメントへの反映まで完了している** → 既に記録済み。false
- 既知と明言されているパターン(「過去のメモリ通り」「既知の制約」等でエージェントが即座に対処した)→ false
- サンドボックスで失敗した**同じコマンドを、サンドボックス無効化して再実行しただけ** → 定型対応であり false(手段の切り替えを伴う場合だけ true)
- 作業が円滑に完了し、訂正も試行錯誤も環境起因の失敗もないセッション → false
- 再発しそうにない一回性のエラー(1 回のタイポ、単発のネットワーク断、1 回で自明に直った呼び出しミス)→ false

# 判断の方針
上記の「拾うべきもの」に**具体的な該当箇所がログ中にある**場合だけ true とせよ。円滑なセッションを true にしてはならない。ただし該当箇所がある場合は、確信が弱くても true に倒してよい(後段の人間が棄却できる)。

# severity の基準
- high: ユーザーがエージェントを止めた・訂正した。またはエージェントの誤前提で成果物や環境が実際に壊れた
- medium: ツール・環境の非自明な仕様に試行錯誤して気づいた(壊れはしなかった)
- low: 軽微な改善余地・気づき

# evidence の書き方
has_learning が true の場合、下のログから根拠となる箇所を**原文のまま**数行引用せよ。要約や言い換えをしてはならない。後段の担当者はこの引用箇所だけを頼りに元ログを辿る。

# 作業ログ
${digest.text}`;
}

export async function classifyDigest(
  digest: Digest,
  model: string,
): Promise<{
  verdict: TriageVerdict;
  promptTokens: number;
  evalTokens: number;
  elapsedMs: number;
}> {
  const base = {
    model,
    prompt: buildPrompt(digest),
    schema: TRIAGE_SCHEMA as unknown as object,
    think: false, // Task 1 の実測で確定した設定。バッチ・評価で必ず揃える
    numCtx: 16384, // ダイジェスト上限 12000 文字 + プロンプト分の余裕
  };
  let result;
  try {
    result = await generateJson<TriageVerdict>({ ...base, temperature: 0 });
  } catch {
    // temperature 0 では稀に反復縮退ループに陥り、ollama が応答を打ち切って
    // 不完全な JSON が返る(実測: 同一トークンの無限反復)。決定性を諦めて
    // 温度を上げ、repeat_penalty でループを抑えて 1 回だけリトライする
    result = await generateJson<TriageVerdict>({
      ...base,
      temperature: 0.3,
      repeatPenalty: 1.1,
    });
  }
  return {
    verdict: result.value,
    promptTokens: result.promptTokens,
    evalTokens: result.evalTokens,
    elapsedMs: result.elapsedMs,
  };
}
