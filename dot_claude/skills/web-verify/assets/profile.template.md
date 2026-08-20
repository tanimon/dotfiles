# プロジェクトプロファイル

web-verify skill が動作確認の再実行時に読む、プロジェクト固有知識の置き場。
初回 scaffold 時に調査・確定した内容を記録し、変わったら更新する。

## アプリの起動・停止

- 起動コマンド: (例: `docker compose up -d` / `npm run dev`)
- 停止コマンド:
- 起動にかかる目安時間:

## ベースURLと readiness

- ベースURL: (`.env` の `VERIFY_BASE_URL` と一致させる)
- readiness 条件: (例: `GET /` が HTTP 200 を返す)

## ログイン方式

- ログイン画面URL:
- セレクタ: (ID入力・パスワード入力・送信ボタン。`scenarios/auth.setup.ts` と一致させる)
- ログイン成功の観測条件: (例: `/dashboard` へ遷移)
- 資格情報の環境変数: `VERIFY_LOGIN_ID` / `VERIFY_LOGIN_PASSWORD`(値は `.env` のみに書く)

## データ準備の手段

- 利用可能な手段: (seeder コマンド / API / SQL など。`seed/setup.ts` が使う)
- クリーンアップの手段: (`seed/cleanup.ts` が使う)

## 既知の制約

- (例: ローカルでは描画されない画面、触ってはいけない共有データ、メール送信はモック等)
