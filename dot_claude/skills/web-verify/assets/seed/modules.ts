import fs from "node:fs";
import path from "node:path";
import { selectFeatures } from "../support/run";

export interface SeedModule {
  setup?: () => Promise<void>;
  cleanup?: () => Promise<void>;
}

const featuresDir = path.join(__dirname, "features");

function availableFeatures(): string[] {
  if (!fs.existsSync(featuresDir)) return [];
  return fs
    .readdirSync(featuresDir)
    .filter((file) => file.endsWith(".ts"))
    .map((file) => file.slice(0, -".ts".length))
    .sort();
}

// seed/common.ts と、今回の機能の seed/features/<feature>.ts をこの順で返す。
// 機能ごとに分けるのは、未マージの別機能の seed(まだ無いテーブルやカラムを前提にする)を
// 今のブランチで流さないため
export async function loadSeedModules(): Promise<SeedModule[]> {
  const modules: SeedModule[] = [(await import("./common")) as SeedModule];
  for (const name of selectFeatures(availableFeatures())) {
    const file = path.join(featuresDir, `${name}.ts`);
    if (fs.existsSync(file)) modules.push((await import(file)) as SeedModule);
  }
  return modules;
}
