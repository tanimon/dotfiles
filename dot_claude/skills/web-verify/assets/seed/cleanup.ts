import { loadSeedModules } from "./modules";

// クリーンアップ(globalTeardown)。片付ける処理は seed/common.ts と seed/features/<feature>.ts の
// cleanup() に書く。作った順の逆(機能 → common)に呼ぶ。
// 片付けが失敗しても throw で全体を fail させない(片付け漏れは警告として報告する)。
// seed の読み込み(loadSeedModules() の向き先ガードを含む)で失敗したときは throw のまま止める
export default async function globalTeardown(): Promise<void> {
  const seeds = (await loadSeedModules()).reverse();
  for (const seed of seeds) {
    try {
      await seed.cleanup?.();
    } catch (error) {
      console.warn("クリーンアップに失敗しました:", error);
    }
  }
}
