# 動作確認スイート

web-verify skill が生成した、機能開発後の動作確認を再実行可能にするスイート。
skill がなくても以下の手順だけで再実行できる。

## 実行方法

1. アプリを起動する(起動方法は `profile.md`)
2. `.env` を用意する(初回のみ。`.env.example` をコピーして値を埋める)
3. このディレクトリで:

   ```sh
   npm install          # 初回のみ
   npx playwright install chromium   # 初回のみ
   npx playwright test  # 全シナリオ実行(データ準備・片付けも自動で走る)
   npx playwright show-report report # 結果と録画を見る
   ```

特定シナリオのみ: `npx playwright test scenarios/<ファイル名>`

## 観点一覧

| シナリオファイル | 観点 | 追加日 |
| --- | --- | --- |
| (web-verify がシナリオ追加時にここへ追記する) | | |

## 構成

- `scenarios/` — 観点ごとのシナリオ(`auth.setup.ts` はログインして認証状態を作る)
- `seed/` — データ準備(`setup.ts`)と片付け(`cleanup.ts`)
- `profile.md` — 起動方法・ログイン方式などプロジェクト固有知識
- 録画・trace は `test-results/`、HTML レポートは `report/`(いずれも生成物、commit しない)
