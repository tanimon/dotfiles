# web-verify skill 設計

日付: 2026-08-20
ステータス: 承認済み(設計レビュー完了)

## 背景・目的

機能開発完了後の手動動作確認を自動化する skill を作る。要件は以下の通り。

- **must:** 開発内容を分析し、確認が必要な観点・シナリオを洗い出す
- **must:** 洗い出した各シナリオを実行し動作確認を行う
- **must:** 動作確認時の画面操作の様子を録画し、人間が動作確認結果を確認できるようにする
- **should:** 再実行時に備えて動作確認に必要なデータの準備・クリーンアップを再利用可能にする
- **should:** 再実行時に備えて動作確認手順をスクリプト化する

既存の `tanomu-verify` skill(tanomu の worktree 専用・playwright-cli ベースのカスタムハーネス)は同じ要件を満たすが、本 skill は**別物として新規作成**する。対象を tanomu に限定しない**任意の Web プロジェクト汎用**の skill であり、実行エンジンにカスタムハーネスではなく標準の `@playwright/test` を採用する点が根本的に異なる。

## 決定事項サマリ

| 論点 | 決定 |
|---|---|
| 対象範囲 | 任意の Web プロジェクト汎用 |
| 再実行資産の置き場 | 対象リポ内(既定 `.claude/verify/`)に git 管理 |
| 実行エンジン | `@playwright/test`(必須依存)。録画・判定・レポートを標準機能に委譲 |
| 探索手段 | `playwright-cli` が利用可能なら任意で使用(必須にしない) |
| 承認ゲート | 初回のみ観点リストを承認。再実行(差分観点追加)は自律 |
| skill の置き場所 | chezmoi リポ `dot_claude/skills/web-verify/` |
| skill 名 | `web-verify`(`tanomu-verify` との対比で汎用 Web 版と分かる) |

## 設計の不変条件

**生成した検証資産は skill がなくても `npx playwright test` だけで再実行できる。**
資産はすべて標準形式(Playwright のスイート構成)で対象リポに commit され、チームメンバーや将来の自分が skill 非依存で利用できる。skill 独自形式の中間物をリポに持ち込まない。

## アーキテクチャ

### 責務分担

- **skill(エージェント側):** 開発内容の分析・観点導出・資産の生成(scaffold)・環境の起動統率・失敗のトリアージ・人間への報告
- **`@playwright/test`(実行エンジン):** シナリオ実行・pass/fail 判定(assertion)・録画(`video: 'on'`)・trace・HTML レポート

### 対象リポに生成する資産(`.claude/verify/`)

```
.claude/verify/
├── README.md               # 観点一覧・実行方法・前提(should②: 手順のドキュメント化)
├── profile.md              # プロジェクトプロファイル(下記)
├── package.json            # @playwright/test のみの自己完結 devDependency
├── playwright.config.ts    # video:'on'、HTML レポート、globalSetup/Teardown 配線
├── scenarios/*.spec.ts     # 観点ごとのシナリオ(1 観点 = 1 test、日本語 test 名)
├── seed/setup.ts           # データ準備(should①)。globalSetup で冪等に実行
├── seed/cleanup.ts         # クリーンアップ。globalTeardown
└── .gitignore              # test-results/ report/ .auth/ .env node_modules/
```

- ディレクトリ位置は初回にユーザーへ確認する(既定 `.claude/verify/`)
- 対象プロジェクトに既存の Playwright 基盤がある場合は、独立ディレクトリを作らず相乗りを提案する
- `package.json` を検証ディレクトリ内で自己完結させ、ホストプロジェクトの依存を汚さない

### profile.md(汎用性の要)

プロジェクト固有知識を永続化するファイル。初回実行時に CLAUDE.md / README / package.json / compose ファイル等から調査し、不明点はユーザーに質問して確定する。以後の再実行はこれを読むだけで自律動作できる。記載内容:

- アプリの起動コマンドと停止コマンド
- ベース URL と readiness 条件(どの URL がどう応答したら起動完了か)
- ログイン方式(認証エンドポイント・フォームのセレクタ・資格情報の環境変数名)
- データ準備の手段(seeder コマンド・API・SQL 等、プロジェクトで利用可能なもの)
- 既知の制約(描画されない画面・テストで触ってはいけないデータ等)

## パイプライン

### 初回(検証資産がまだ無い場合)

```
1. 分析      : git diff <base>...HEAD + PR description(あれば)から観点を洗い出す
2. profile 調査: 起動・ログイン・seed 手段をリポから調査、不明点はユーザーに質問
3. 【承認ゲート】: 観点リスト(前提/操作/期待結果)を提示し、修正・承認を受ける
4. scaffold  : .claude/verify/ を生成、npm install、ブラウザバイナリ導入
5. 環境起動  : profile.md のコマンドで起動、readiness 確認(失敗ならログ提示して中止)
6. seed 実装 : 観点の前提データを seed/setup.ts に実装し、適用されることを確認
               (以後の実行では globalSetup 経由で自動適用される)
7. シナリオ実装: 観点ごとに探索 → .spec.ts 化 → 単体実行で安定化
8. 全体実行  : npx playwright test(録画 + HTML レポート生成)
9. 報告      : pass/fail 一覧・fail の切り分け・レポートの開き方を提示。cleanup 実行
```

### 再実行(検証資産が既にある場合)

- diff から**差分観点だけ**を洗い出して既存シナリオに追加する。承認ゲートは挟まない(実行後レポートで追加観点を報告する)
- 環境起動と readiness 確認は初回と同様に profile.md に従って行う
- 既存シナリオはそのまま `npx playwright test` で実行する

## 観点導出の規約

- **ブラックボックス志向**で列挙する。「diff で書き換わった行」起点ではなく「観測できる振る舞いの契約がどの画面・導線に現れるか」起点。コード検索は現れる場所を漏れなく特定する網羅補助として使う
- 各観点は「前提 / 操作 / **機械判定可能な期待結果**」の 3 点セットで記述する
- 期待結果が仕様(diff・PR description)から導けない場合は**捏造せずユーザーに質問する**(spec-gap の勝手な補完をしない)
- 判定は assertion(URL 遷移・表示内容・件数差分など durable な状態)で行う。動画は証跡であって判定の代替ではない

## 実行・録画・人間向けレポート

- ログイン操作は Playwright 標準の auth setup project に分離し、storageState(`.auth/`、gitignored)を生成する。各シナリオは認証済み状態から開始する
- **ログイン操作は録画に含めない**(auth setup project は video off)。パスワード入力が映像・trace に残るのを防ぐ
- 本編シナリオは `video: 'on'` + trace で全録画。人間は HTML レポート(`npx playwright show-report`)で動画・trace を確認する
- fail 時はエージェントが「**実装バグ / シナリオ側の誤り / 環境問題**」を切り分けて報告する
- **fail を理由に勝手に実装コードを直さない。** 本 skill の deliverable は発見と報告であり、修正は別タスク

## セキュリティ

- 資格情報は `.claude/verify/.env`(gitignored)経由でのみ扱う。spec・profile.md・README には環境変数名だけを書き、値を commit しない
- storageState(`.auth/`)・録画・trace(`test-results/`)はすべて gitignored

## skill 本体の構成(chezmoi リポ)

```
dot_claude/skills/web-verify/
├── SKILL.md                     # パイプライン全体(リーンに保つ)
├── references/
│   ├── scaffold.md              # 資産生成手順 + profile 調査の手順
│   ├── scenario-authoring.md    # 観点導出ガイド・spec 記述規約・探索(playwright-cli 任意)
│   └── troubleshooting.md
└── assets/                      # scaffold 用テンプレート(config / seed / spec / README 雛形)
```

- SKILL.md はリーンに保ち、ステージ詳細は references に委譲する
- テンプレートは chezmoi の `.tmpl` にしない素ファイル(Go テンプレート構文が TypeScript と衝突するため)
- `~/.claude/skills/web-verify/` へのデプロイは通常の `chezmoi apply` に乗る(既存の `dot_claude/skills/` 配下 skill と同じ)

## 非スコープ

- CLI / TUI / ネイティブアプリの検証(Web ブラウザで操作できるものだけが対象)
- tanomu 専用機能(クロスアプリ伝播検証・worktree 共有 DB 等)。tanomu では引き続き `tanomu-verify` を使う
- 合成カーソル・キャプション等のナレーション層(標準録画 + trace viewer で代替。必要になったら後付けを検討)
- CI への組み込み(資産は標準形式なので将来 CI に乗せることは可能だが、本 skill の scope 外)
- fail した実装バグの修正

## テスト・検証方針

- skill 自体の検証は、実プロジェクトでの試 run で行う(初回パイプライン一周 → 資産が commit 可能な形で残る → skill を介さず `npx playwright test` で再実行できる、まで確認)
- assets のテンプレートが有効な TypeScript / JSON であることは scaffold 時の `npx playwright test --list` で検証できる
