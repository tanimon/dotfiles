import path from "node:path";

// 実行ごとに変わる値を 1 か所で決める。config・auth.setup・seed はここから読む。
// VERIFY_FEATURE(機能の slug。規則は README.md の「実行方法」)が未設定なら全機能を対象にする。
const feature = process.env.VERIFY_FEATURE ?? "";
// パスの一部に使うので、ディレクトリを抜け出せる値は拒否する
if (feature !== "" && !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(feature)) {
  throw new Error(`VERIFY_FEATURE には英数字・"."・"_"・"-" だけを使ってください: ${feature}`);
}
const allFeatures = feature === "";

// playwright.config.ts の scenarios プロジェクトの testDir
export const scenarioTestDir = allFeatures ? "./scenarios" : `./scenarios/${feature}`;

// 実行する機能の seed の名前。全機能なら seed/features/ にあるものすべて
export function selectFeatures(available: string[]): string[] {
  return allFeatures ? available : [feature];
}

// Playwright は実行開始時に outputDir と HTML レポートの出力先を消す。同じ保存場所で並行する
// 別の機能の実行結果・ログイン状態を消さないよう、生成物は実行ごとのサブディレクトリに置く
export const runName = allFeatures ? "_all" : feature;

export const suiteDir = path.resolve(__dirname, "..");
export const storageStatePath = path.join(suiteDir, ".auth", runName, "user.json");
