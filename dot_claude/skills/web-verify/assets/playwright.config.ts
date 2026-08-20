import { defineConfig } from "@playwright/test";
import "dotenv/config";

// 動作確認スイートの設定。web-verify skill が scaffold する。
// - auth-setup プロジェクトは録画・trace を切る: パスワード入力を証跡に残さないため
// - 本編(scenarios)は全録画: 動画は人間が結果を確認するための証跡
export default defineConfig({
  testDir: "./scenarios",
  outputDir: "./test-results",
  reporter: [["html", { outputFolder: "./report", open: "never" }], ["list"]],
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
      testMatch: /auth\.setup\.ts/,
      use: { video: "off", trace: "off" },
    },
    {
      name: "scenarios",
      testIgnore: /auth\.setup\.ts/,
      dependencies: ["auth-setup"],
      use: { storageState: ".auth/user.json" },
    },
  ],
});
