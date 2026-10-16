# 動作確認スイート

web-verify skill が生成した、機能開発後の動作確認を再実行可能にするスイート。
skill がなくても以下の手順だけで再実行できる。

## 実行方法

1. 検証対象の worktree でアプリを起動する(起動方法は `profile.md`)
2. `.env` を用意する(初回のみ。`.env.example` をコピーして値を埋める)
3. このディレクトリで:

   ```sh
   npm install                       # 初回のみ
   npx playwright install chromium   # 初回のみ
   # 機能を 1 つ検証する(データ準備・片付けも自動で走る)
   VERIFY_REPO_DIR=<検証対象の worktree の絶対パス> VERIFY_FEATURE=<機能> npx playwright test
   npx playwright show-report report/<機能>   # 結果と録画を見る
   ```

- `VERIFY_FEATURE` は `scenarios/` 配下の機能ディレクトリ名(ブランチ名の `/` と、英数字・`.`・`_`・`-` 以外の文字を
  `-` に置き換えたもの)。
  省略すると全機能を実行し、レポートは `report/_all` に出る(マージ済み機能のデグレ確認)
- `VERIFY_REPO_DIR` は、このスイートが対象リポジトリの中にあれば省略できる(`playwright.config.ts` の
  `REPO_DIR_FROM_SUITE`)。外にある場合は必須
- worktree ごとにアプリのポートが違う場合は `VERIFY_BASE_URL=...` も渡す(`.env` の値より優先される)
- `VERIFY_BASE_URL` がローカル以外を向いていると停止する(このスイートはデータを変更するため)。
  共有環境に対して実行する意図があるときだけ `VERIFY_ALLOW_REMOTE=1` を設定する
- 特定シナリオのみ: `VERIFY_FEATURE=<機能> npx playwright test scenarios/<機能>/<ファイル名>`

## 観点一覧

| 機能 | ブランチ | シナリオファイル | 観点 | 追加日 |
| --- | --- | --- | --- | --- |
| (web-verify がシナリオ追加時にここへ追記する) | | | | |

## 構成

- `scenarios/<機能>/` — 機能ごとのシナリオ(`scenarios/auth.setup.ts` はログインして認証状態を作る)
- `support/` — 複数のシナリオ・seed で使う共通モジュール。`support/run.ts` は実行ごとの切り替え
- `seed/common.ts` / `seed/features/<機能>.ts` — 全機能共通 / 機能ごとのデータ準備(`setup`)と片付け(`cleanup`)
- `profile.md` — 起動方法・ログイン方式などプロジェクト固有知識
- 録画・trace は `test-results/<機能>/`、HTML レポートは `report/<機能>/`(いずれも生成物、commit しない)
