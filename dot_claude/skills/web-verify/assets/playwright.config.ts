import path from "node:path";
import { defineConfig } from "@playwright/test";
import dotenv from "dotenv";
import { runName, scenarioTestDir, storageStatePath, suiteDir } from "./support/run";

// 動作確認スイートの設定。web-verify skill が scaffold する。
// - auth-setup プロジェクトは録画・trace を切る: パスワード入力を証跡に残さないため
// - 本編(scenarios)は全録画: 動画は人間が結果を確認するための証跡
// - VERIFY_FEATURE で、実行するシナリオ・seed・生成物の置き場所を機能ごとに切り替える(support/run.ts)

// 実行時に渡した環境変数は .env より優先される(dotenv は既存の値を上書きしない)
dotenv.config({ path: path.join(suiteDir, ".env"), quiet: true });

// このスイートが対象リポジトリの中にあるときの、リポジトリのルートへの相対パス(例: "../..")。
// リポジトリの外にあるときは null のままにし、VERIFY_REPO_DIR を実行時に渡す。
// git rev-parse で求めないのは、スイートが別の git リポジトリの中にあるとそちらを返すため
const REPO_DIR_FROM_SUITE: string | null = null;
if (!process.env.VERIFY_REPO_DIR && REPO_DIR_FROM_SUITE !== null) {
  process.env.VERIFY_REPO_DIR = path.resolve(suiteDir, REPO_DIR_FROM_SUITE);
}

export default defineConfig({
  outputDir: `./test-results/${runName}`,
  reporter: [["html", { outputFolder: `./report/${runName}`, open: "never" }], ["list"]],
  timeout: 60_000,
  // 動作確認は同一データを共有するため直列実行(シナリオ間の干渉を避ける)
  workers: 1,
  globalSetup: "./seed/setup.ts",
  globalTeardown: "./seed/cleanup.ts",
  use: {
    baseURL: process.env.VERIFY_BASE_URL,
    trace: "on",
    video: "on",
  },
  projects: [
    {
      name: "auth-setup",
      // 機能を絞っても認証は必要なので、auth.setup.ts は常に scenarios/ 直下から収集する
      testDir: "./scenarios",
      testMatch: /auth\.setup\.ts/,
      use: { video: "off", trace: "off" },
    },
    {
      name: "scenarios",
      testDir: scenarioTestDir,
      testIgnore: /auth\.setup\.ts/,
      dependencies: ["auth-setup"],
      use: { storageState: storageStatePath },
    },
  ],
});
