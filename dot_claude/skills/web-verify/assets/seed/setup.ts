import "dotenv/config";

// データ準備(globalSetup)。全シナリオ共通の前提データをここで投入する。
// 規約:
// - 冪等に書く: 既に存在するデータは作り直さず再利用する(再実行のたびに増殖させない)
// - 手段は profile.md の「データ準備」に従う(プロジェクトの seeder コマンド・API・SQL など)
// - シナリオ固有のデータも固定の識別子(名前・UUID)で作り、シナリオ間の実行順依存を作らない
export default async function globalSetup(): Promise<void> {
  // 例: プロジェクトの seeder を呼ぶ場合(profile.md に合わせて書き換える)
  // const { execSync } = await import('node:child_process')
  // execSync('npm run db:seed -- --class=VerifySeeder', { stdio: 'inherit', cwd: '../..' })
}
