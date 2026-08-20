import "dotenv/config";

// クリーンアップ(globalTeardown)。シナリオが作成・変更したデータを片付ける。
// 規約:
// - setup が「再利用」した既存データは消さない(消してよいのはこのスイートが作ったものだけ)
// - 固定の識別子(setup.ts と同じ名前・UUID)を目印に削除する
// - 失敗しても throw で全体を fail させない(片付け漏れは警告として報告する)
export default async function globalTeardown(): Promise<void> {
  // 例: profile.md のクリーンアップ手段に合わせて書き換える
}
