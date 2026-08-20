# scaffold — 検証ディレクトリの生成と profile 調査

## 1. 配置場所の確認(初回のみ)

`AskUserQuestion` で配置場所を確認する。既定は対象リポの `.claude/verify/`。

- 対象リポに既存の Playwright / Cypress 等の E2E 基盤がある場合(`playwright.config.*` や `e2e/` の存在で判定)、独立ディレクトリを作らず既存基盤への相乗りを提案する。相乗りする場合は既存の config・ディレクトリ規約に従い、以降の手順の「配置」を読み替える
- ユーザーが別の場所を指定したらそれに従う

## 2. profile 調査

profile.md に書く項目を対象リポから調査する。読む場所の優先順:

1. `CLAUDE.md` / `AGENTS.md`(起動コマンド・開発環境の説明があることが多い)
2. `README.md`
3. `package.json` の scripts / `compose.yml` / `Makefile` / `justfile`
4. ログイン画面の実装(ルーティング定義・ログインフォームのテンプレート)からセレクタを確認

**調査で確定できない項目は推測で埋めず、`AskUserQuestion` でユーザーに確認する。**
特に以下は間違えると全シナリオが偽の結果を出すため、必ず確定させる:

- 起動コマンドと readiness 条件(どのURLがどう応答したら起動完了か)
- ログイン成功の観測条件(遷移先URL等)
- データ準備の手段(seeder / API / SQL のどれが使えるか)
- 触ってはいけないデータ・環境の有無

## 3. 生成手順

`<dir>` = 確定した配置場所(以下 `.claude/verify/` として例示)。
テンプレートは skill の `assets/` からコピーする(`~/.claude/skills/web-verify/assets/`)。

```sh
mkdir -p .claude/verify/scenarios .claude/verify/seed .claude/verify/.auth
cp ~/.claude/skills/web-verify/assets/playwright.config.ts .claude/verify/
cp ~/.claude/skills/web-verify/assets/package.json .claude/verify/
cp ~/.claude/skills/web-verify/assets/auth.setup.ts .claude/verify/scenarios/
cp ~/.claude/skills/web-verify/assets/seed/setup.ts .claude/verify/seed/
cp ~/.claude/skills/web-verify/assets/seed/cleanup.ts .claude/verify/seed/
cp ~/.claude/skills/web-verify/assets/gitignore.template .claude/verify/.gitignore
cp ~/.claude/skills/web-verify/assets/env.example .claude/verify/.env.example
cp ~/.claude/skills/web-verify/assets/profile.template.md .claude/verify/profile.md
cp ~/.claude/skills/web-verify/assets/README.template.md .claude/verify/README.md
cd .claude/verify
npm install -D @playwright/test dotenv @types/node
npx playwright install chromium
```

`example.spec.ts` はコピーしない(spec 記述のお手本として skill 側に置いてあり、
シナリオは references/scenario-authoring.md に従って観点ごとに書き起こす)。

## 4. テンプレートのプロジェクト適合

コピー後、調査結果で以下を書き換える:

- `profile.md` — 調査で確定した内容をすべて記入(テンプレートの括弧書き例示は消す)
- `scenarios/auth.setup.ts` — ログイン画面のセレクタ・成功条件を profile.md と一致させる。
  認証が不要なプロジェクトでは auth.setup.ts を削除し、playwright.config.ts の
  `projects` を単一プロジェクト(`dependencies` と `storageState` なし)に書き換える
  (`VERIFY_BASE_URL` の未設定検出は seed/setup.ts 側にあるため削除しても失われない)
- `seed/setup.ts` / `seed/cleanup.ts` — profile.md のデータ準備手段で実装。
  setup.ts 冒頭の `VERIFY_BASE_URL` ガードはスイート唯一の `.env` 前提チェックなので残す
- `.env` — エージェントは資格情報の値を扱わない。ユーザー自身に `.env.example` を
  コピーして直接編集してもらう

## 5. 生成の検証

```sh
cd .claude/verify && npx playwright test --list
```

Expected: シナリオ一覧が表示され exit 0(config・spec の構文エラーがないことの確認。
ブラウザ・アプリ起動は不要)。

## 6. ホストリポの .gitignore 確認

検証ディレクトリ自体は commit する設計(spec 参照)。ホストリポの `.gitignore` が
`.claude/` を丸ごと除外している場合、`!.claude/verify/` を 1 行追加するだけでは効かない
(git は除外されたディレクトリの中には降りないため、親ごと除外された配下の再包含 `!` は
無効になる)。ユーザーに確認のうえ、除外行を次の 2 行に書き換えるか、配置場所の変更を提案する:

```gitignore
.claude/*
!.claude/verify/
```

書き換え後は、**リポジトリルートで** `git check-ignore -v .claude/verify/README.md` を実行し、
ignore されていないこと(何も出力されず exit 1)を確認する。パスは CWD 基準で解釈されるため、
検証ディレクトリ内から実行すると実在しない別パスを判定してしまい確認にならない。
