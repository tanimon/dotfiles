# web-verify skill 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 任意のWebプロジェクトで機能開発後の動作確認を自動化する skill `web-verify` を `dot_claude/skills/web-verify/` に作成する。

**Architecture:** skill は「観点導出・資産生成・統率」を担い、実行・録画・レポートは対象リポに scaffold する `@playwright/test` スイートに委譲する。skill 本体は SKILL.md(リーン)+ references(ステージ詳細)+ assets(scaffold 用テンプレート)の3層。

**Tech Stack:** Markdown(skill 本文)、TypeScript(Playwright テンプレート)、chezmoi(デプロイ)

**Spec:** `docs/superpowers/specs/2026-08-20-web-verify-skill-design.md`(本プランはこの spec を実装する。実装者は必ず spec も読むこと)

## Global Constraints

- 新規ドキュメント・コメントはすべて日本語で書く(`~/.claude/rules/common/documentation-language.md`)
- assets の `*.ts` / `*.json` はリポ全体の `just oxlint` / `just oxfmt` の対象になる。**必ず有効な TypeScript / JSON にし、両チェックを通す**
- テンプレートに chezmoi の `.tmpl` 拡張子を使わない(Go テンプレート構文が TS と衝突するため。spec「skill 本体の構成」)
- ソースファイル名を `.`(ドット)始まりにしない(chezmoi が source 内のドット始まりファイルを特別扱いするため。`.gitignore` テンプレートは `gitignore.template` の名前で置く)
- chezmoi の確認コマンドは必ず `--source "$(pwd)"` を付ける(worktree からの実行では既定 source が main を指すため。CLAUDE.md「Known Pitfalls」)
- 生成される検証資産は「skill なしで `npx playwright test` だけで再実行できる」形を壊さない(spec「設計の不変条件」)
- 資格情報・秘密情報をテンプレート・ドキュメントの例に書かない(環境変数名のみ)
- commit メッセージは Conventional Commits(日本語本文可)。各 commit 前に pre-commit フック(secretlint 等)が走る

---

### Task 1: scaffold 用テンプレート(assets)を作成

**Files:**
- Create: `dot_claude/skills/web-verify/assets/playwright.config.ts`
- Create: `dot_claude/skills/web-verify/assets/package.json`
- Create: `dot_claude/skills/web-verify/assets/auth.setup.ts`
- Create: `dot_claude/skills/web-verify/assets/example.spec.ts`
- Create: `dot_claude/skills/web-verify/assets/seed/setup.ts`
- Create: `dot_claude/skills/web-verify/assets/seed/cleanup.ts`
- Create: `dot_claude/skills/web-verify/assets/gitignore.template`
- Create: `dot_claude/skills/web-verify/assets/env.example`
- Create: `dot_claude/skills/web-verify/assets/profile.template.md`
- Create: `dot_claude/skills/web-verify/assets/README.template.md`

**Interfaces:**
- Consumes: なし(最初のタスク)
- Produces: Task 2 の scaffold 手順がコピーするテンプレート一式。ファイル名・配置は上記の通りで、後続タスクはこの名前を参照する(`auth.setup.ts` は scaffold 時に `scenarios/auth.setup.ts` へ、`gitignore.template` は `.gitignore` へ、`env.example` は `.env.example` へ、`profile.template.md` は `profile.md` へ、`README.template.md` は `README.md` へ配置される)。`example.spec.ts` は scaffold ではコピーしない(spec 記述のお手本として skill 側に置く)

- [ ] **Step 1: playwright.config.ts を書く**

```typescript
import { defineConfig } from '@playwright/test'
import 'dotenv/config'

// 動作確認スイートの設定。web-verify skill が scaffold する。
// - auth-setup プロジェクトは録画・trace を切る: パスワード入力を証跡に残さないため
// - 本編(scenarios)は全録画: 動画は人間が結果を確認するための証跡
export default defineConfig({
  testDir: './scenarios',
  outputDir: './test-results',
  reporter: [['html', { outputFolder: './report', open: 'never' }], ['list']],
  timeout: 60_000,
  // 動作確認は同一データを共有するため直列実行(シナリオ間の干渉を避ける)
  workers: 1,
  globalSetup: './seed/setup.ts',
  globalTeardown: './seed/cleanup.ts',
  use: {
    baseURL: process.env.VERIFY_BASE_URL,
    trace: 'on',
    video: 'on',
  },
  projects: [
    {
      name: 'auth-setup',
      testMatch: /auth\.setup\.ts/,
      use: { video: 'off', trace: 'off' },
    },
    {
      name: 'scenarios',
      testIgnore: /auth\.setup\.ts/,
      dependencies: ['auth-setup'],
      use: { storageState: '.auth/user.json' },
    },
  ],
})
```

- [ ] **Step 2: package.json を書く**

依存のバージョンは scaffold 時の `npm install -D` で解決するため、テンプレートには scripts のみ書く。

```json
{
  "name": "verify",
  "private": true,
  "scripts": {
    "verify": "playwright test",
    "report": "playwright show-report report"
  }
}
```

- [ ] **Step 3: auth.setup.ts を書く**

```typescript
import { test as setup } from '@playwright/test'

// ログイン操作を各シナリオから分離し、認証済み状態(storageState)を生成する。
// この setup は playwright.config.ts の auth-setup プロジェクトで実行され、
// video: off / trace: off — パスワード入力を証跡に残さないため。
// セレクタ・遷移先は対象プロジェクトのログイン画面(profile.md の「ログイン方式」)に合わせて書き換える。
setup('ログインして認証状態を保存する', async ({ page }) => {
  const loginId = process.env.VERIFY_LOGIN_ID
  const password = process.env.VERIFY_LOGIN_PASSWORD
  if (!loginId || !password) {
    throw new Error('VERIFY_LOGIN_ID / VERIFY_LOGIN_PASSWORD を .env に設定してください')
  }
  await page.goto('/login')
  await page.getByLabel('メールアドレス').fill(loginId)
  await page.getByLabel('パスワード').fill(password)
  await page.getByRole('button', { name: 'ログイン' }).click()
  // ログイン成功の観測可能な証拠(遷移先URL)を待ってから保存する
  await page.waitForURL('**/dashboard')
  await page.context().storageState({ path: '.auth/user.json' })
})
```

- [ ] **Step 4: example.spec.ts を書く**

scaffold ではコピーしない、spec 記述のお手本(references/scenario-authoring.md から参照される)。

```typescript
import { test, expect } from '@playwright/test'

// spec 記述のお手本(scaffold 対象外)。規約:
// - 1 観点 = 1 test。test 名は日本語で、承認済み観点リストの文言をそのまま使う
// - 判定は durable な状態(URL 遷移・表示内容・件数差分)への expect で行う。
//   トースト等の一時表示は「出て消えた」と「出なかった」を区別できないため本判定に使わない
// - セレクタは getByRole / getByLabel を優先し、テキスト照合は完全一致を避ける
//   (テンプレート由来の空白・改行が DOM に残ることがあるため)
// - 動画は証跡であって判定の代替ではない
test('商品を新規登録すると一覧に表示され件数が1増える', async ({ page }) => {
  // 前提: seed/setup.ts が投入したカテゴリ「動作確認用カテゴリ」が存在する
  await page.goto('/items')
  const rows = page.getByRole('row')
  const before = await rows.count()

  await page.getByRole('link', { name: '新規登録' }).click()
  await page.getByLabel('商品名').fill('動作確認用商品A')
  await page.getByLabel('カテゴリ').selectOption({ label: '動作確認用カテゴリ' })
  await page.getByRole('button', { name: '登録する' }).click()

  // durable な判定: 一覧へ戻り、登録した行が表示され、件数が1増えている
  await page.waitForURL('**/items')
  await expect(page.getByRole('row').filter({ hasText: '動作確認用商品A' })).toBeVisible()
  await expect(rows).toHaveCount(before + 1)
})
```

- [ ] **Step 5: seed/setup.ts と seed/cleanup.ts を書く**

`seed/setup.ts`:

```typescript
import 'dotenv/config'

// データ準備(globalSetup)。全シナリオ共通の前提データをここで投入する。
// 規約:
// - 冪等に書く: 既に存在するデータは作り直さず再利用する(再実行のたびに増殖させない)
// - 手段は profile.md の「データ準備」に従う(プロジェクトの seeder コマンド・API・SQL など)
// - シナリオ固有のデータも固定の識別子(名前・UUID)で作り、シナリオ間の実行順依存を作らない
export default async function globalSetup(): Promise<void> {
  // 例: プロジェクトの seeder を呼ぶ場合(profile.md に合わせて書き換える)
  // const { execSync } = await import('node:child_process')
  // execSync('npm run db:seed -- --class=VerifySeeder', { stdio: 'inherit', cwd: '../..' })
}
```

`seed/cleanup.ts`:

```typescript
import 'dotenv/config'

// クリーンアップ(globalTeardown)。シナリオが作成・変更したデータを片付ける。
// 規約:
// - setup が「再利用」した既存データは消さない(消してよいのはこのスイートが作ったものだけ)
// - 固定の識別子(setup.ts と同じ名前・UUID)を目印に削除する
// - 失敗しても throw で全体を fail させない(片付け漏れは警告として報告する)
export default async function globalTeardown(): Promise<void> {
  // 例: profile.md のクリーンアップ手段に合わせて書き換える
}
```

- [ ] **Step 6: gitignore.template と env.example を書く**

`gitignore.template`(scaffold 時に `.gitignore` として配置):

```
node_modules/
test-results/
report/
.auth/
.env
```

`env.example`(scaffold 時に `.env.example` として配置。実際の値は `.env` に書き、`.env` は commit しない):

```
# 検証対象アプリのベースURL(例: http://127.0.0.1:8080)
VERIFY_BASE_URL=
# ログイン資格情報(値はこのファイルではなく .env に書く)
VERIFY_LOGIN_ID=
VERIFY_LOGIN_PASSWORD=
```

- [ ] **Step 7: profile.template.md を書く**

```markdown
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
```

- [ ] **Step 8: README.template.md を書く**

```markdown
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
```

- [ ] **Step 9: lint を実行して通ることを確認**

Run: `cd "$(git rev-parse --show-toplevel)" && just oxlint && just oxfmt`
Expected: いずれも Passed(fail した場合は `pnpm exec oxfmt <対象ファイル>` で整形、oxlint の指摘は修正)

- [ ] **Step 10: Commit**

```bash
git add dot_claude/skills/web-verify/assets/
git commit -m "feat(web-verify): scaffold用テンプレート(assets)を追加"
```

---

### Task 2: references/scaffold.md を作成

**Files:**
- Create: `dot_claude/skills/web-verify/references/scaffold.md`

**Interfaces:**
- Consumes: Task 1 の assets 一式(ファイル名・配置先の対応)
- Produces: SKILL.md(Task 5)のステージ 2(profile 調査)・4(scaffold)から参照される手順書

- [ ] **Step 1: scaffold.md を書く**

以下の内容で作成する:

````markdown
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
- `seed/setup.ts` / `seed/cleanup.ts` — profile.md のデータ準備手段で実装
- `.env` — ユーザーに `.env.example` をコピーして値を埋めてもらう(エージェントは資格情報の値を扱う場合、
  ファイルへの書き込みのみ行い、会話ログ・レポートに値を残さない)

## 5. 生成の検証

```sh
cd .claude/verify && npx playwright test --list
```

Expected: シナリオ一覧が表示され exit 0(config・spec の構文エラーがないことの確認。
ブラウザ・アプリ起動は不要)。

## 6. ホストリポの .gitignore 確認

検証ディレクトリ自体は commit する設計(spec 参照)。ホストリポの `.gitignore` が
`.claude/` を丸ごと除外している場合は、ユーザーに確認のうえ
`!.claude/verify/` の追加(または配置場所の変更)を提案する。
````

- [ ] **Step 2: Commit**

```bash
git add dot_claude/skills/web-verify/references/scaffold.md
git commit -m "feat(web-verify): scaffold手順とprofile調査のreferenceを追加"
```

---

### Task 3: references/scenario-authoring.md を作成

**Files:**
- Create: `dot_claude/skills/web-verify/references/scenario-authoring.md`

**Interfaces:**
- Consumes: Task 1 の `assets/example.spec.ts`(お手本として参照)
- Produces: SKILL.md(Task 5)のステージ 1(分析)・3(承認)・7(シナリオ実装)から参照される規約

- [ ] **Step 1: scenario-authoring.md を書く**

以下の内容で作成する:

````markdown
# scenario-authoring — 観点導出とシナリオ実装

## 観点の導出

入力: `git diff <base>...HEAD`(base はデフォルトブランチ。PR があれば description も)。

**ブラックボックス志向で列挙する。** 「diff で書き換わった行」起点ではなく
「観測できる振る舞いの契約がどの画面・導線に現れるか」起点で考える。
コード検索(コンポーネントの利用箇所・ルーティング)は、現れる場所を漏れなく
特定するための網羅補助として使う。

各観点は次の 3 点セットで書く:

- **前提**: どんなデータ・状態が必要か(seed/setup.ts が用意するもの)
- **操作**: 画面で何をするか
- **期待結果**: 機械判定可能な述語(URL 遷移・表示内容・件数差分など)

**期待結果が diff・PR description から導けない場合は捏造せず、不明点を列挙して
ユーザーに質問する。** もっともらしい期待値をでっち上げた観点は、pass しても
fail しても誤った情報になる。

観点に含めるもの: 変更した機能の主要導線 / 境界値・エラーケースのうち画面で
観測できるもの / 変更が波及しうる既存画面(デグレ確認)。
含めないもの: 単体テストで担保済みの内部ロジック / 画面から観測できない副作用。

## 承認ゲート(初回のみ)

初回実行では、観点リスト(3 点セット)を提示し、`AskUserQuestion` で
承認・修正・削除を受けてから実装に入る。
再実行(検証ディレクトリが既にある場合)では、diff から差分観点のみを導出して
承認なしで追加し、実行後の報告で「今回追加した観点」を明示する。

## spec の記述規約

お手本: `~/.claude/skills/web-verify/assets/example.spec.ts`(コピーせず読んで倣う)。

- 1 観点 = 1 `test()`。test 名は日本語で、承認済み観点リストの文言をそのまま使う
- 判定は durable な状態への `expect` で行う。トースト・フラッシュメッセージ等の
  一時表示は「出て消えた」と「出なかった」を区別できないため本判定に使わない
  (補助的に映像へ残るのは良い)
- セレクタは `getByRole` / `getByLabel` を優先。テキスト照合は完全一致を避け
  部分一致にする(テンプレート由来の空白・改行が DOM に残ることがある)
- 固定 sleep(`waitForTimeout`)を使わない。Playwright の auto-waiting と
  `expect` のリトライに任せる
- シナリオ間の実行順依存を作らない。観点固有の前提データは seed/setup.ts で
  固定の識別子を付けて用意し、他シナリオが作ったデータに依存しない
- 新しい観点を追加したら README.md の観点一覧表にも 1 行追加する

## 探索(セレクタ・導線の確定)

spec を書く前に実画面を観察してセレクタと導線を確定する。手段は環境にあるものを使う:

1. `playwright-cli` が利用可能なら最優先(a11y スナップショットの ref 駆動で
   画面構造を確認できる)。**必須依存ではない** — なければ 2 へ
2. `npx playwright test --headed --debug` で実画面を見ながら書く、
   または一度実行して trace(`npx playwright show-trace`)から確定する

## 安定化

1. 観点単体で実行: `npx playwright test scenarios/<ファイル>.spec.ts`
2. fail したら切り分ける(references/troubleshooting.md の「fail の切り分け」)
3. 全観点そろったら全体実行: `npx playwright test`
````

- [ ] **Step 2: Commit**

```bash
git add dot_claude/skills/web-verify/references/scenario-authoring.md
git commit -m "feat(web-verify): 観点導出とシナリオ実装規約のreferenceを追加"
```

---

### Task 4: references/troubleshooting.md を作成

**Files:**
- Create: `dot_claude/skills/web-verify/references/troubleshooting.md`

**Interfaces:**
- Consumes: Task 1〜3 の成果物(ファイル名・環境変数名)
- Produces: SKILL.md(Task 5)から参照されるトラブルシューティング集

- [ ] **Step 1: troubleshooting.md を書く**

以下の内容で作成する:

````markdown
# troubleshooting

## fail の切り分け(最重要)

fail は必ず次の 3 分類のどれかに切り分けてから報告する。**分類せずに
「fail しました」とだけ報告しない。勝手に実装コードを直さない。**

1. **実装バグ**: 期待結果(承認済み観点)は正しいのに画面の振る舞いが違う。
   → trace(`npx playwright show-trace test-results/<...>/trace.zip`)で操作時点の
   画面・ネットワークを確認し、再現手順と証跡(動画パス)を添えて報告する
2. **シナリオ側の誤り**: セレクタ外れ・待ち不足・期待値の解釈違い。
   → シナリオを直して再実行する(実装は触らない)
3. **環境問題**: アプリ未起動・DB 未準備・`.env` 不足。
   → 環境を直してスイート全体を再実行する

見分けの起点: 同じ観点を trace で見て、(a) 操作自体が届いていない → 2、
(b) 操作は届いたが応答が 5xx / 想定外 → 1 か 3(アプリログを見る)、
(c) 全シナリオが同じ箇所で落ちる → 3 の可能性が高い。

## 症状別

- **`Error: VERIFY_LOGIN_ID / VERIFY_LOGIN_PASSWORD を .env に設定してください`**
  → `.env.example` をコピーして `.env` を作り値を埋める(ユーザーに依頼する)
- **auth-setup は通るのに全シナリオが未ログイン画面に飛ばされる**
  → `.auth/user.json` が古い(セッション失効)。`.auth/` を削除して再実行
- **起動確認(readiness)が通らない**
  → profile.md の起動コマンド・readiness 条件を見直す。アプリのログを提示して
  中止する(起動しないままブラウザ操作に進まない)
- **pass / fail が実行のたびに変わる(flaky)**
  → 固定 sleep や一時表示への依存を疑う(scenario-authoring.md の規約違反)。
  それでも不安定なら対象を単体実行して trace を比較する
- **再実行のたびにデータが増殖する / 前提データが見つからない**
  → seed/setup.ts が冪等でない、またはシナリオ間の実行順依存がある。
  固定識別子での存在チェックを入れる(seed/setup.ts の規約コメント参照)
- **録画にログイン操作(パスワード入力)が映っている**
  → auth の分離が壊れている。ログインが auth.setup.ts の外(シナリオ内)で
  行われていないか、playwright.config.ts の auth-setup プロジェクトの
  `video: 'off'` が消えていないかを確認する。**該当動画は共有前に削除する**
- **`npx playwright install chromium` が遅い / 失敗する**
  → 初回はブラウザバイナリのダウンロードに数分かかる。プロキシ環境では
  `HTTPS_PROXY` の設定を確認する
- **CI や別マシンで動かしたい**
  → 本 skill の scope 外だが、資産は標準形式なのでそのまま移植できる。
  `.env` 相当の環境変数と対象アプリの起動だけ用意すればよい
````

- [ ] **Step 2: Commit**

```bash
git add dot_claude/skills/web-verify/references/troubleshooting.md
git commit -m "feat(web-verify): troubleshootingのreferenceを追加"
```

---

### Task 5: SKILL.md を作成

**Files:**
- Create: `dot_claude/skills/web-verify/SKILL.md`

**Interfaces:**
- Consumes: Task 2〜4 の references(ファイル名で参照)、Task 1 の assets 構成
- Produces: skill 本体。`~/.claude/skills/web-verify/SKILL.md` としてデプロイされ、エージェントが最初に読む

- [ ] **Step 1: SKILL.md を書く**

以下の内容で作成する:

````markdown
---
name: web-verify
description: >-
  Webプロジェクトで機能実装を終えた後、手動でやっていた画面の動作確認・機能検証を自動化したいときに使う。
  「動作確認して」「ブラウザで操作して確かめて」「検証結果を録画で残して」「このブランチ/PRの変更を画面で確認して」
  「前と同じ観点で再検証して」など、実装後の動作確認・デグレ確認とその再実行が話題になったら使う。
  対象はブラウザで操作できる任意のWebアプリ。そのリポジトリ専用の検証 skill があればそちらを優先する。
  単体テストの作成・静的解析・CLI/TUIアプリの検証・見つかったバグの修正そのものには使わない。
---

# web-verify — Web アプリ動作確認の自動化

機能開発後の手動動作確認を自動化する。**分析 → (初回のみ)承認 → scaffold →
環境起動 → seed → シナリオ実装 → 実行(録画) → 報告** を一周させ、
再実行可能な検証資産を対象リポに残す。

## 不変条件

- **資産は skill なしで再実行できる。** 生成物はすべて標準の `@playwright/test`
  スイートであり、`npx playwright test` だけで誰でも再実行できる形を壊さない。
  skill 独自形式の中間物をリポに持ち込まない
- **fail しても実装コードを直さない。** この skill の成果物は発見と報告。
  修正は別タスクとしてユーザーに委ねる
- **資格情報を commit しない・録画に映さない。** 資格情報は `.env`(gitignored)
  のみに置き、ログインは録画を切った auth setup に分離する

## 検証資産(対象リポ、既定 `.claude/verify/`)

```
.claude/verify/
├── README.md               # 観点一覧・実行方法(人間向け)
├── profile.md              # 起動方法・ログイン方式・seed手段(再実行の自律性の源)
├── package.json            # @playwright/test のみの自己完結 devDependency
├── playwright.config.ts    # video:'on'、HTMLレポート、seed の配線
├── scenarios/*.spec.ts     # 1観点 = 1 test(auth.setup.ts はログイン分離用)
├── seed/setup.ts           # データ準備(冪等)
├── seed/cleanup.ts         # クリーンアップ
└── .gitignore              # 生成物(録画・レポート・.auth・.env)を除外
```

## パイプライン

### 初回(検証資産がまだ無い)

1. **分析**: `git diff <base>...HEAD` + PR description から観点を洗い出す
   → references/scenario-authoring.md
2. **profile 調査**: 起動・ログイン・seed 手段をリポから調査、不明点はユーザーに質問
   → references/scaffold.md
3. **【承認ゲート】**: 観点リスト(前提/操作/期待結果)を `AskUserQuestion` で提示し、
   修正・承認を受けるまで先へ進まない
4. **scaffold**: assets からコピーして npm install → references/scaffold.md
5. **環境起動 + readiness**: profile.md のコマンドで起動し、readiness 条件を確認。
   通らなければログを提示して中止する(ブラウザ操作に進まない)
6. **seed 実装**: 観点の前提データを seed/setup.ts に冪等に実装
7. **シナリオ実装**: 観点ごとに探索 → spec 化 → 単体実行で安定化
   → references/scenario-authoring.md
8. **全体実行**: 検証ディレクトリで `npx playwright test`(録画・trace・HTML レポート生成)
9. **報告**: pass/fail 一覧、fail の 3 分類(実装バグ / シナリオ誤り / 環境問題)、
   レポートの開き方(`npx playwright show-report report`)を提示
   → references/troubleshooting.md

### 再実行(検証資産が既にある)

- diff から**差分観点だけ**を導出して既存シナリオに追加する(承認ゲート不要。
  実行後の報告で追加観点を明示する)
- 環境起動・readiness・実行は初回と同じ(profile.md に従う)
- コード修正後の再確認だけなら観点導出も不要: 起動して `npx playwright test`

## ステージ別リファレンス

| ステージ | リファレンス |
|---|---|
| 観点導出・承認・spec 記述・探索 | references/scenario-authoring.md |
| profile 調査・scaffold・テンプレート適合 | references/scaffold.md |
| fail の切り分け・症状別対処 | references/troubleshooting.md |

各ステージに入る前に対応するリファレンスを読むこと。
````

- [ ] **Step 2: frontmatter の文字数を確認**

Run: `awk '/^---$/{c++} c==1' dot_claude/skills/web-verify/SKILL.md | wc -c`
Expected: 1024 以下(超えたら description を削る)

- [ ] **Step 3: Commit**

```bash
git add dot_claude/skills/web-verify/SKILL.md
git commit -m "feat(web-verify): SKILL.md本体を追加"
```

---

### Task 6: テンプレートのスモークテスト(scaffold 手順の実地検証)

**Files:**
- Modify: (スモークテストで見つかった不具合があれば Task 1〜2 のファイル)

**Interfaces:**
- Consumes: Task 1 の assets、Task 2 の scaffold 手順
- Produces: 「テンプレート一式が scaffold 手順どおりに組み上がり `npx playwright test --list` が通る」ことの検証済み状態

- [ ] **Step 1: scratchpad に scaffold 手順を再現する**

scaffold.md の手順を機械的になぞる(`~/.claude/skills/...` はまだ未デプロイなので、リポ内の `dot_claude/skills/web-verify/assets/` から読み替えてコピーする)。加えて example.spec.ts もシナリオとして配置し、お手本自体の構文も検証する:

```bash
SRC="$(git rev-parse --show-toplevel)/dot_claude/skills/web-verify/assets"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/web-verify-smoke-XXXXXX")
mkdir -p "$WORK/scenarios" "$WORK/seed"
cp "$SRC/playwright.config.ts" "$SRC/package.json" "$WORK/"
cp "$SRC/auth.setup.ts" "$WORK/scenarios/"
cp "$SRC/example.spec.ts" "$WORK/scenarios/"
cp "$SRC/seed/setup.ts" "$SRC/seed/cleanup.ts" "$WORK/seed/"
cp "$SRC/gitignore.template" "$WORK/.gitignore"
cp "$SRC/env.example" "$WORK/.env.example"
cd "$WORK" && npm install -D @playwright/test dotenv @types/node
```

Expected: npm install が exit 0(ブラウザのインストールは不要 — `--list` は構文検証のみでブラウザを使わない)

注意: シェル状態は Bash 呼び出し間で持ち越されないため、Step 2 以降を別呼び出しで実行する場合は `$WORK` を実パスに読み替える(Step 1 の最後に `echo "$WORK"` して控えるか、Step 1〜2 を 1 回の呼び出しにまとめる)。

- [ ] **Step 2: `npx playwright test --list` で構文検証**

Run: `cd "$WORK" && npx playwright test --list`
Expected: `auth.setup.ts` と `example.spec.ts` のテストが auth-setup / scenarios の各プロジェクトに列挙され exit 0

- [ ] **Step 3: fail した場合はテンプレートを修正して再検証**

修正はスモークテストの作業ディレクトリではなく**必ずリポ側(`dot_claude/skills/web-verify/assets/`)に対して行い**、Step 1〜2 をやり直す。scaffold.md の手順自体に不備があればそれも直す。

- [ ] **Step 4: 作業ディレクトリを片付けて、修正があれば commit**

```bash
rm -rf "$WORK"
# 修正があった場合のみ:
git add dot_claude/skills/web-verify/
git commit -m "fix(web-verify): スモークテストで見つかったテンプレート不具合を修正"
```

---

### Task 7: リポ全体の検証とデプロイ確認

**Files:**
- Modify: (lint で見つかった不具合があれば該当ファイル)

**Interfaces:**
- Consumes: Task 1〜6 のすべての成果物
- Produces: CI 相当のチェックが通り、chezmoi のデプロイ対象になっていることが確認された状態

- [ ] **Step 1: chezmoi のデプロイ対象になっていることを確認**

Run: `cd "$(git rev-parse --show-toplevel)" && chezmoi managed --source "$(pwd)" | grep '^\.claude/skills/web-verify'`
Expected: SKILL.md / references / assets の全ファイルが `.claude/skills/web-verify/...` として列挙される(0 件なら `.chezmoiignore` に吸われていないか確認する)

- [ ] **Step 2: リポ全体の lint を実行**

Run: `just lint`
Expected: すべて Passed(scan-sensitive で assets 内の例示値が引っかかった場合は例示値を変更する。`.env` 系の実値は書いていないはず — 書いていたら削除する)

- [ ] **Step 3: 修正があれば commit**

```bash
git add -A dot_claude/skills/web-verify/
git commit -m "fix(web-verify): lint指摘の修正"
```

- [ ] **Step 4: 実プロジェクトでの試 run が残タスクであることを報告**

skill の最終検証(spec「テスト・検証方針」の実プロジェクト試 run)は、本ブランチのマージ → `chezmoi apply` でのデプロイ後に実施する。プラン完了報告に「未デプロイのため実プロジェクト試 run は未実施。マージ後に任意の Web プロジェクトで初回パイプラインを一周して検証する」ことを明記する。
