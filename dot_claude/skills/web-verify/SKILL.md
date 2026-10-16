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

機能開発後の手動動作確認を自動化する。保存場所を決め、新規なら **分析 → (機能の初回のみ)承認 →
scaffold → 環境起動 → seed → シナリオ実装 → 実行(録画) → 報告**、既存スイートなら環境起動を先に
行ってから同じ流れを一周させ、再実行可能な検証資産を残す。

**`<skill-dir>`** はこの `SKILL.md` があるディレクトリを指す。Claude Code は skill の起動時に
`Base directory for this skill: <path>` として示す。テンプレート(`<skill-dir>/assets/`)や
references はこのパスで参照し、`~/.claude/skills/` などの配置場所を前提にしない。

## 不変条件

- **資産は skill なしで再実行できる。** 生成物はすべて標準の `@playwright/test`
  スイートであり、保存場所で `npx playwright test` を実行するだけで誰でも再実行できる形を壊さない。
  skill 独自形式の中間物を持ち込まない。保存場所が対象リポの中なら commit される前提で書く
  (commit はユーザーに委ね、報告に変更したファイルを列挙する)
- **fail しても実装コードを直さない。** この skill の成果物は発見と報告。
  修正は別タスクとしてユーザーに委ねる
- **資格情報を commit しない・録画に映さない。** 資格情報は `.env`(gitignored)
  のみに置き、ログインは録画を切った auth setup に分離する

## 保存場所の決め方

起動のたびに次の順で決め、報告に「保存場所: `<パス>`(どれで決まったか)」を書く。

1. **起動時の明示指定**(ユーザーの依頼文や引数、deliver の「起動時の明示指定」に書かれた保存場所)
2. **個人設定** `~/.config/web-verify/config.json` の `default`。あれば質問せずに使う。
   読み取りが `Operation not permitted` で拒否された・JSON として読めない・`default` が文字列でないときは、
   黙って「設定が無い」とは扱わない。
   nono は存在しないパスの grant を評価しないので、`~/.config/web-verify/` が作られる前に起動した
   nono セッションでは読めない。対話なら個人設定を使えなかった理由(拒否なら「作成済みなら新しいセッションで読める」)を
   伝えてから 3 に進み、質問できなければ 4 と同じく止める
3. **`AskUserQuestion`** で聞く。選択肢は `.claude/verify/`(対象リポの中)と、ユーザーが自由入力する任意のパス
   (リポの中でも外でもよい)。対象リポに既存スイートがあっても、個人設定が無ければ聞く
4. **質問できない状況**(deliver のサブエージェントなど)で 1・2 が無ければ、検証を始めずに止め、
   保存場所が未決定であることを報告する。組み込みの既定値に黙って書かない
   (リポの中に置きたくない人のリポに書いてしまうため)

個人設定の書式・パスの解決規則(相対パス・`{repo}`・`~`)・決まった保存場所の分類
(スイートあり / 空 / それ以外)・書き込み確認は references/storage.md。保存場所が決まったら
必ずこの順で解決 → 分類 → 書き込み確認を行う。分類が「スイートあり」で `support/run.ts` が無ければ旧レイアウト。

## 起動前に人間が確かめる事項

質問できない呼び出し元(deliver / review-verify の入口 skill)は、起動前に次を確かめて渡す。
web-verify 自身の起動時にもこの順で確かめる。

1. **保存場所**: 上の「保存場所の決め方」の 1〜4 と、references/storage.md の解決規則・分類まで
   (書き込み確認は副作用があるので web-verify 自身が行う)。分類が「それ以外」なら別の場所を選び直してもらう。個人設定で決まった場合も、
   解決後の絶対パスを渡す
2. **資格情報**: 認証のあるアプリで、保存場所に `.env` が無ければ動作確認は blocked になる。
   認証の有無が保存場所の `profile.md` から分からない(新規の保存場所など)ときはユーザーに聞く。ユーザーに `<保存場所>/.env` を用意してもらうか(項目は `<skill-dir>/assets/env.example`)、
   blocked を承知で進めるかを選んでもらう

呼び出し元は結果を 1 つの文字列にまとめて渡す(deliver の `verifyArgs`)。形は
`検証資産の保存場所: <絶対パス>(<決まり方: 明示指定 / 個人設定 / 質問>); .env: <あり / なし(承知で進める)>`。
web-verify はこの「決まり方」をそのまま報告に使う(呼び出し元が確かめた結果なので、明示指定として扱いつつ出所を残す)

## 検証資産(保存場所 `<dir>` に 1 リポジトリ 1 スイート)

```
<dir>/
├── README.md                  # 観点一覧・実行方法(人間向け)
├── profile.md                 # 起動方法・ログイン方式・seed手段(再実行の自律性の源)
├── package.json               # 自己完結の devDependency(ホストの依存を汚さない)
├── playwright.config.ts       # video:"on"、HTMLレポート、seed の配線、機能の切り替え
├── support/run.ts             # 実行ごとの切り替え(機能・生成物の置き場所)
├── support/*.ts               # 複数のシナリオ・seed で使う共通モジュール
├── scenarios/auth.setup.ts    # ログイン分離用
├── scenarios/<feature>/*.spec.ts  # 機能ごと。1観点 = 1 test
├── seed/setup.ts / cleanup.ts / modules.ts  # globalSetup / Teardown(common → 機能の順に呼ぶ)
├── seed/common.ts             # 全機能共通のデータ準備・片付け
├── seed/features/<feature>.ts # その機能のデータ準備・片付け
└── .gitignore                 # 生成物(録画・レポート・.auth・.env)を除外
```

**`<feature>`** はブランチ名の `/` を `-` に置き換えた slug。`support/run.ts` は英数字で始まり
英数字・`.`・`_`・`-` だけからなる値しか受け付けないので、それ以外の文字(`+`・`@`・非 ASCII など)も
`-` に置き換え、先頭の英数字以外を取り除く。英数字が 1 文字も残らなければ
`b-<printf %s "<ブランチ名>" | shasum | cut -c1-8 の結果>` にする。`a/b-c` と `a-b/c` のように
別のブランチが同じ slug になりうるので、同じ slug の `scenarios/<feature>/` があれば README.md の
観点一覧の「ブランチ」列と照らし、別のブランチのものなら末尾に `-2` などを足して分け、報告に書く。マージ後も削除せず、
全体実行でのデグレ確認に使う(削除は人間が判断する)。

**実行の形**(保存場所で実行する):

```sh
VERIFY_REPO_DIR="<対象 worktree の絶対パス>" VERIFY_FEATURE=<feature> npx playwright test
```

- `VERIFY_FEATURE` で、実行するシナリオ(`scenarios/<feature>/`)・seed・生成物の置き場所
  (`test-results/<feature>/` `report/<feature>/` `.auth/<feature>/`)が切り替わる。
  未設定なら全機能を実行し生成物は `_all` に出る。生成物を分けるのは、同じ保存場所で別 worktree の
  実行が並行しても結果やログイン状態を消し合わないため
- `VERIFY_REPO_DIR` は、保存場所がリポの中なら `playwright.config.ts` の `REPO_DIR_FROM_SUITE` から
  求まるので省略できる。外なら必須
- worktree ごとにポートが違えば `VERIFY_BASE_URL` も渡す(`.env` より優先される)

## パイプライン

### 0. 保存場所と機能を決める

上の「保存場所の決め方」で `<dir>` を決め、ブランチ名から `<feature>` を作る。

### 新規(保存場所にスイートが無い)

1. **分析**: `git diff <base>...HEAD` + PR description から観点を洗い出す
   → references/scenario-authoring.md
2. **profile 調査**: 起動・ログイン・seed 手段をリポから調査、不明点はユーザーに質問
   → references/scaffold.md
3. **【承認ゲート】**: 観点リスト(前提/操作/期待結果)を `AskUserQuestion` で提示し、
   修正・承認を受けるまで先へ進まない(下記「承認ゲート」)
4. **scaffold**: `<skill-dir>/assets` からコピーして npm install → references/scaffold.md
5. **環境起動 + readiness**: 下記「環境起動と readiness」
6. **seed 実装**: 観点の前提データを `seed/features/<feature>.ts` に冪等に実装
   (全機能に共通するものは `seed/common.ts`)
7. **シナリオ実装**: 観点ごとに探索 → `scenarios/<feature>/` に spec 化 → 単体実行で安定化
   → references/scenario-authoring.md
8. **実行**: `VERIFY_FEATURE=<feature>` を付けて `npx playwright test`(録画・trace・HTML レポート生成)
9. **報告**: 下記「報告」

### 既存スイートへの追加(保存場所にスイートがある)

書き換え前後の比較実行にアプリが要るので、環境起動を先に行う。

1. **準備**: `node_modules` が無ければ `npm install`、ブラウザが無ければ `npx playwright install chromium`。
   `.env` が無ければユーザーに `.env.example` からの作成を依頼する(資格情報の値は扱わない)。
   worktree ごとにポートが違う構成なら、この worktree のポートを profile.md の手順で確かめて `VERIFY_BASE_URL` に渡す
2. **環境起動 + readiness**: 下記「環境起動と readiness」
3. **旧レイアウトなら更新する**(references/scaffold.md の「旧レイアウトの更新」)
4. **観点の導出**: `scenarios/<feature>/` が無ければその機能の初回なので承認ゲートを出す。
   あれば**差分観点だけ**を承認なしで追加し、報告で追加観点を明示する
5. **共通化**: シナリオ・seed を書く前に既存の `support/`・`seed/`・他機能のシナリオを読み、
   共通化できる部分を切り出す(references/scenario-authoring.md の「共通化」)。既存の資産が
   不変条件に反している(シナリオの中でログインしている等)のを見つけたら、新しいシナリオでは使わず報告する
6. **seed・シナリオの実装、実行、報告**は新規の 6〜9 と同じ

コード修正後の再確認だけなら観点導出も不要: 起動して `VERIFY_FEATURE=<feature> npx playwright test`

### 承認ゲート

機能の初回(`scenarios/<feature>/` が無い)に観点リストを承認してもらう。観点リスト(前提/操作/期待結果)は
本文に番号付きで出し、`AskUserQuestion` の選択肢は「承認」「修正したい」にする(修正内容は自由入力で受ける)。
質問できない状況では飛ばし、報告に「未承認の観点」として一覧を出す。

### 環境起動と readiness

profile.md のコマンドを対象 worktree(`VERIFY_REPO_DIR`)で実行して起動し、readiness 条件を確認する。
通らなければログを提示して中止する(ブラウザ操作に進まない)。応答しているのが対象 worktree の
プロセスか・ビルド済みアセットと常駐ワーカーが新しいコードかも確かめる → references/environment.md

### 報告

- 保存場所とその決まり方、`<feature>`
- pass/fail 一覧、fail の 3 分類(実装バグ / シナリオ誤り / 環境問題)→ references/troubleshooting.md
- 今回追加した観点(承認なしで追加したもの・未承認のものは明示する)
- 共通化・旧レイアウト更新で書き換えた既存ファイルと、その後の再実行結果
- レポートの開き方(`npx playwright show-report report/<feature>`)
- 呼び出し元(deliver など)が summary しか受け取らないなら、保存場所・未承認の観点・書き換えたファイルを summary に入れる
- 呼び出し元(deliver など)が結果に `blocked` を求めている場合: fail の分類が「環境問題」
  (references/troubleshooting.md。範囲の定義はそこだけに置く)のときだけ `blocked=true` にする。
  保存場所が未決定で止めたときは、人間が取れる手順として「`~/.config/web-verify/config.json` に `default` を書く」
  「deliver / review-verify を起動し直し、入口で保存場所を答える」を示す(nono の中で設定ディレクトリを
  新しく作ったなら、新しいセッションで起動し直す)

## ステージ別リファレンス

| ステージ | リファレンス |
|---|---|
| 観点導出・承認・spec 記述・探索・共通化 | references/scenario-authoring.md |
| 保存場所の解決・分類・書き込み確認 | references/storage.md |
| profile 調査・scaffold・テンプレート適合・旧レイアウトの更新 | references/scaffold.md |
| 環境起動・readiness(ポート・アセット・ワーカーの鮮度) | references/environment.md |
| fail の切り分け・症状別対処 | references/troubleshooting.md |

各ステージに入る前に対応するリファレンスを読むこと。
