import fs from "node:fs";
import { loadSeedModules } from "./modules";

// データ準備(globalSetup)。データを作る処理はここに書かず、seed/common.ts と
// seed/features/<feature>.ts の setup() に書く(seed/modules.ts が順に呼ぶ)。
export default async function globalSetup(): Promise<void> {
  // スイート全体の前提チェック。auth.setup.ts は認証不要プロジェクトでは削除されるため、
  // 常に実行される globalSetup に置く。向き先ガードは cleanup でも効かせるため seed/modules.ts にある。
  // 未設定だと goto() が "Cannot navigate to invalid URL" という分かりにくいエラーになるため先に検出する
  if (!process.env.VERIFY_BASE_URL) {
    throw new Error("VERIFY_BASE_URL を .env に設定するか、実行時に渡してください");
  }
  const repoDir = process.env.VERIFY_REPO_DIR;
  if (!repoDir || !fs.statSync(repoDir, { throwIfNoEntry: false })?.isDirectory()) {
    throw new Error(
      `VERIFY_REPO_DIR に検証対象の worktree のパスを渡してください(例: VERIFY_REPO_DIR="$(git -C <worktree> rev-parse --show-toplevel)")。現在値: ${repoDir ?? "未設定"}`,
    );
  }
  for (const seed of await loadSeedModules()) await seed.setup?.();
}
