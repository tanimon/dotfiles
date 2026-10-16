// seed のモジュール。seed/common.ts(全機能共通)と seed/features/<feature>.ts(その機能の前提データ)は
// どちらもこの形にする。
// 規約:
// - setup は冪等に書く: 既に存在するデータは作り直さず再利用する(再実行のたびに増殖させない)
// - 手段は profile.md の「データ準備」に従う(プロジェクトの seeder コマンド・API・SQL など)
// - データは固定の識別子(名前・UUID)で作り、シナリオ間・機能間の実行順依存を作らない
// - cleanup は setup が「再利用」した既存データを消さない(消してよいのはこのスイートが作ったものだけ)
// - 複数の機能で同じ手順が要るようになったら、その手順を support/ に切り出して両方から呼ぶ

export async function setup(): Promise<void> {
  // 例: プロジェクトの seeder を呼ぶ場合(profile.md に合わせて書き換える)。
  // コマンドは対象の worktree(VERIFY_REPO_DIR)で実行する
  // const { execSync } = await import("node:child_process");
  // execSync("npm run db:seed -- --class=VerifySeeder", {
  //   stdio: "inherit",
  //   cwd: process.env.VERIFY_REPO_DIR,
  // });
}

export async function cleanup(): Promise<void> {
  // 例: setup と同じ固定の識別子を目印に削除する
}
