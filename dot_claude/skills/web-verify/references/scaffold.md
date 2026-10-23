# scaffold — 検証ディレクトリの生成と profile 調査

## 1. 配置場所

配置場所(`<dir>`)は SKILL.md の「保存場所の決め方」で決まっている。ここでは決め直さない。

対象リポに既存の Playwright / Cypress 等の E2E 基盤があっても相乗りしない。機能ごとの切り替え
(`VERIFY_FEATURE`・seed の分割)を入れるにはチームの config を書き換える必要があり、影響が大きすぎるため。
既存基盤の隣に置きたい場合は、保存場所の自由入力で `e2e/verify/` のようなパスを選んでもらう。

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
- 検証先がローカルか共有環境か。共有環境しかない場合は、データを変更する検証を
  そこで走らせてよいかをユーザーに確認する(`VERIFY_ALLOW_REMOTE=1` はその承認の記録であり、
  エージェントの判断で設定しない)

質問できない状況(review-verify のサブエージェントなど)でこれらが確定できなければ、推測で埋めて
先へ進まず、確定できなかった項目を挙げて止める。これは troubleshooting.md の「環境問題」に当たり、
呼び出し元が `blocked` を求めていれば `blocked=true` にする。

## 3. 生成手順

`SKILL_DIR` は SKILL.md の `<skill-dir>`、`DIR` は確定した配置場所の絶対パス。
scaffold の直前に references/storage.md の「ロック」を取り直して分類し直し、「5. 生成の検証」の後まで持つ。
zsh では `$VAR:` の `:` が修飾子に化けるので、変数は常に `${}` で閉じる。

```sh
SKILL_DIR="<skill-dir>"
DIR="<配置場所の絶対パス>"
mkdir -p "${DIR}/scenarios" "${DIR}/seed/features" "${DIR}/support"
cp "${SKILL_DIR}/assets/playwright.config.ts" "${SKILL_DIR}/assets/package.json" "${DIR}/"
cp "${SKILL_DIR}/assets/support/run.ts" "${DIR}/support/"
cp "${SKILL_DIR}/assets/auth.setup.ts" "${DIR}/scenarios/"
cp "${SKILL_DIR}/assets/seed/setup.ts" "${SKILL_DIR}/assets/seed/cleanup.ts" "${SKILL_DIR}/assets/seed/modules.ts" "${DIR}/seed/"
cp "${SKILL_DIR}/assets/seed/module.template.ts" "${DIR}/seed/common.ts"
cp "${SKILL_DIR}/assets/gitignore.template" "${DIR}/.gitignore"
cp "${SKILL_DIR}/assets/env.example" "${DIR}/.env.example"
cp "${SKILL_DIR}/assets/profile.template.md" "${DIR}/profile.md"
cp "${SKILL_DIR}/assets/README.template.md" "${DIR}/README.md"
cd "${DIR}"
npm install -D @playwright/test dotenv @types/node
npx playwright install chromium
```

`playwright install` はサンドボックス内でも通るが、ブラウザの起動はサンドボックス内では失敗する。
起動段階まで気づけないので、以降の `npx playwright test` は SKILL.md の「パイプライン」冒頭の
とおりサンドボックスの外で実行する(症状と対処は references/troubleshooting.md の症状別)。

機能ごとの seed `seed/features/<feature>.ts` は、その機能のシナリオを書くときに
`module.template.ts` をコピーして作る(scaffold 時には作らない)。

`example.spec.ts` はコピーしない(spec 記述のお手本として skill 側に置いてあり、
シナリオは references/scenario-authoring.md に従って観点ごとに書き起こす)。

## 4. テンプレートのプロジェクト適合

コピー後、調査結果で以下を書き換える:

- `playwright.config.ts` の `REPO_DIR_FROM_SUITE` — 配置場所が対象リポの中なら、配置場所から
  リポのルートへの相対パス(`.claude/verify` なら `"../.."`)。外なら `null` のまま
- `profile.md` — 調査で確定した内容をすべて記入(テンプレートの括弧書き例示は消す)
- `scenarios/auth.setup.ts` — ログイン画面のセレクタ・成功条件を profile.md と一致させる。
  認証が不要なプロジェクトでは auth.setup.ts を削除し、playwright.config.ts の
  `projects` を `scenarios` プロジェクトだけ(`dependencies` と `storageState` なし)に書き換える
  (`VERIFY_BASE_URL` の未設定検出は seed/setup.ts 側にあるため削除しても失われない)
- `seed/common.ts` — profile.md のデータ準備手段で、全機能共通の前提データを実装。
  seed/setup.ts の `VERIFY_BASE_URL` / `VERIFY_REPO_DIR` のガードと、seed/modules.ts の向き先ガード
  (ローカル以外の拒否)はスイートの前提チェックと安全装置なので残す
- `.env` — エージェントは資格情報の値を扱わない。ユーザー自身に `.env.example` を
  コピーして直接編集してもらう

保存場所は `{repo}` 単位で別の worktree と共有されるので、最初の scaffold で決めた構成がそのリポジトリの
規約になる。たとえば 1 つのスイートで複数のアプリ(セラー画面と管理画面など)をまたいで検証するなら、
最初から次のようにアプリごとに分けておく:

- ベースURLの環境変数をアプリごとに 1 つ持つ(`VERIFY_<APP>_BASE_URL`)。`.env.example` と profile.md もそれに合わせる
- `support/run.ts` に、アプリごとの認証状態の保存先を返す関数を足し、projects をアプリごとの
  auth-setup と本編に分ける。spec は `scenarios/<feature>/<app>/` のようにディレクトリ名で振り分ける
- `seed/setup.ts` の未設定検出と `seed/modules.ts` の向き先ガードは、すべてのベースURLを検査する

## 5. 生成の検証

```sh
cd "${DIR}" && npx playwright test --list
```

Expected: シナリオ一覧が表示され exit 0(config・spec の構文エラーがないことの確認。
ブラウザ・アプリ起動は不要。`--list` は globalSetup を実行しないので、seed の確認にはならない)。

通ったら完了マーカーを置き(`touch "${DIR}/.web-verify-suite"`)、references/storage.md の「ロック」の解放を行う。

## 6. ホストリポの .gitignore 確認(配置場所が対象リポの中のときだけ)

リポの中に置いた検証ディレクトリは commit する設計。ホストリポの `.gitignore` が
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

## 7. 旧レイアウトの更新

保存場所にスイートはあるが `support/run.ts` が無いものは、機能ごとの切り替えが入る前の旧レイアウト。
`VERIFY_FEATURE` が効かず、機能ごとの実行も並行実行もできないので、追加の前に最小限だけ書き換える。
同じ保存場所で構造だけを直す作業なので、始める前に references/storage.md の「ロック」を取り直し、終わるまで持つ。

1. 書き換え前の結果を控える: `VERIFY_REPO_DIR=… npx playwright test` で全体を実行し、pass/fail を記録する
   (旧 config は `VERIFY_REPO_DIR` を読まないが、新 config との比較のため同じ形で実行する)。
   書き換えるファイル(config・`seed/`・`scenarios/auth.setup.ts`・README.md・profile.md)を保存場所の外へ退避する
2. `support/run.ts` と `seed/modules.ts` をコピーし、`seed/module.template.ts` を `seed/common.ts` としてコピーする。
   `seed/features/` を作る
3. `playwright.config.ts` を新テンプレートに置き換える。旧 config に入れたプロジェクト固有の変更
   (認証不要にした `projects`・timeout など)は新しい config に移す。固有の変更かどうかは、旧 config と
   新テンプレートを並べ、新テンプレートで置き換わる配線(`testDir`・`outputDir`・reporter の出力先・
   storageState・dotenv)以外の差分を固有とみなす。判断できない差分は旧い値を残し、報告に書く。`REPO_DIR_FROM_SUITE` を「4. テンプレートのプロジェクト適合」の規則で設定する
4. 旧 `seed/setup.ts` のデータ準備の処理を `seed/common.ts` の `setup()` へ、旧 `seed/cleanup.ts` の
   処理を `cleanup()` へ移し、`seed/setup.ts` / `seed/cleanup.ts` を新テンプレートに置き換える。
   リポのルートを `cwd: '../..'` のような相対パスで指していた箇所は `process.env.VERIFY_REPO_DIR` に直す
5. `scenarios/auth.setup.ts` の storageState の保存先を新テンプレートどおり `storageStatePath` にする
6. README.md の「実行方法」「観点一覧」「構成」と、profile.md の「対象リポジトリ」節を新テンプレートに合わせる。
   `@playwright/test` / `dotenv` / `@types/node` が `package.json` に無ければ `npm install -D` で足す。
   `.gitignore` に `.web-verify-lock/` が無ければ足す
7. 既存のシナリオは移動しない(平置きのまま、`VERIFY_FEATURE` 未設定の全体実行に含まれる)
8. 1. と同じ形で全体を実行し、pass/fail が変わらないことを確かめる。変わらなければ完了マーカーを置いてロックを解放する。
   変わったら退避したファイルで書き換えを戻し(新しくコピーしたファイルは消す)、ロックを解放して、
   今回の機能の追加には進まずに止めて報告する(旧レイアウトのままでは `VERIFY_FEATURE` が効かないため)。
   flaky が疑われるときは、変わったシナリオだけを前後それぞれもう一度実行して確かめてから判断する

## 8. 別の保存場所への移管

移管は、既存のスイートを別の保存場所へ移し、新しいレイアウトに載せ替えること。同じ場所で構造だけを直す
「7. 旧レイアウトの更新」とは別の作業で、7 の「既存のシナリオは移動しない」は移管には当てはまらない。
`/web-verify` の引数で移管を指示されたときだけ行う。

1. **ベースラインを取る**: 移管元で全体を実行し(`VERIFY_REPO_DIR=… npx playwright test`)、テストごとの pass/fail を控える
2. **移管先に scaffold する**: 移管先を references/storage.md の順で解決・ロック・分類し(「空」であること)、
   この文書の 3〜5 で新テンプレートを置く。profile 調査は移管元の profile.md を読んで行い、
   5 の完了マーカーとロックの解放はこの手順の 6 まで持ち越す
3. **既存資産を機能単位のパスへ移植する**: シナリオは README.md の観点一覧の「ブランチ」列から `<feature>` を決めて
   `scenarios/<feature>/` へ、ブランチが分からないものは `scenarios/` 直下へ平置きで移す。seed は、全機能が
   前提にするデータを `seed/common.ts` に、リポジトリ固有の列・モデルを触るものを含め機能が前提にするデータを
   `seed/features/<feature>.ts` に置く。`support/` の共通モジュールと README.md の観点一覧も移す
4. **リポジトリのルートを `VERIFY_REPO_DIR` から求める**: 移管先がリポの外なら `REPO_DIR_FROM_SUITE` は `null` のまま、
   `cwd: '../..'` のような相対パスは `process.env.VERIFY_REPO_DIR` に直す
5. **`.env` だけを値を読まずにコピーする**(`cp "<移管元>/.env" "${DIR}/.env"`)。`report/`・`test-results/`・`.auth/`・
   `node_modules/` は実行ごとに作り直されるので移さない
6. **一致を確かめる**: 移管先で機能ごとに(平置きのシナリオは全体実行で)実行し、1 のベースラインとテストごとに
   pass/fail が一致することを確かめる。一致したら完了マーカーを置いてロックを解放する。一致しなければ
   ロックだけを解放し、マーカーを置かずに止めて報告する(次の起動は「それ以外」に分類して止まる)
7. **移管元の削除をユーザーに任せる**: 削除してよいかを確かめ、ユーザー自身が `! rm -rf "<移管元>"` で
   消すよう案内する(リポの `.claude/` 配下はエージェントの権限では消せないことがある)
