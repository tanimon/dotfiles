import { test as setup } from "@playwright/test";

// ログイン操作を各シナリオから分離し、認証済み状態(storageState)を生成する。
// この setup は playwright.config.ts の auth-setup プロジェクトで実行され、
// video: off / trace: off — パスワード入力を証跡に残さないため。
// セレクタ・遷移先は対象プロジェクトのログイン画面(profile.md の「ログイン方式」)に合わせて書き換える。
setup("ログインして認証状態を保存する", async ({ page }) => {
  const loginId = process.env.VERIFY_LOGIN_ID;
  const password = process.env.VERIFY_LOGIN_PASSWORD;
  if (!loginId || !password) {
    throw new Error("VERIFY_LOGIN_ID / VERIFY_LOGIN_PASSWORD を .env に設定してください");
  }
  // VERIFY_BASE_URL の未設定検出は seed/setup.ts(globalSetup)側にある
  await page.goto("/login");
  await page.getByLabel("メールアドレス").fill(loginId);
  await page.getByLabel("パスワード").fill(password);
  await page.getByRole("button", { name: "ログイン" }).click();
  // ログイン成功の観測可能な証拠(遷移先URL)を待ってから保存する
  await page.waitForURL("**/dashboard");
  await page.context().storageState({ path: ".auth/user.json" });
});
