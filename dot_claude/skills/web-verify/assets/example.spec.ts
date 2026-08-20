import { test, expect } from "@playwright/test";

// spec 記述のお手本(scaffold 対象外)。規約:
// - 1 観点 = 1 test。test 名は日本語で、承認済み観点リストの文言をそのまま使う
// - 判定は durable な状態(URL 遷移・表示内容・件数差分)への expect で行う。
//   トースト等の一時表示は「出て消えた」と「出なかった」を区別できないため本判定に使わない
// - セレクタは getByRole / getByLabel を優先し、テキスト照合は完全一致を避ける
//   (テンプレート由来の空白・改行が DOM に残ることがあるため)
// - 動画は証跡であって判定の代替ではない
test("商品を新規登録すると一覧に表示され件数が1増える", async ({ page }) => {
  // 前提: seed/setup.ts が投入したカテゴリ「動作確認用カテゴリ」が存在する
  await page.goto("/items");
  const rows = page.getByRole("row");
  const before = await rows.count();

  await page.getByRole("link", { name: "新規登録" }).click();
  await page.getByLabel("商品名").fill("動作確認用商品A");
  await page.getByLabel("カテゴリ").selectOption({ label: "動作確認用カテゴリ" });
  await page.getByRole("button", { name: "登録する" }).click();

  // durable な判定: 一覧へ戻り、登録した行が表示され、件数が1増えている
  await page.waitForURL("**/items");
  await expect(page.getByRole("row").filter({ hasText: "動作確認用商品A" })).toBeVisible();
  await expect(rows).toHaveCount(before + 1);
});
