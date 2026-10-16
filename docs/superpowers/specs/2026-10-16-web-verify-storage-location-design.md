# web-verify 検証資産の保存場所の選択と共通化 設計

日付: 2026-10-16
ステータス: 承認済み(grilling で合意)
前提: [web-verify skill 設計](2026-08-20-web-verify-skill-design.md)

## 背景・目的

- **must:** skill の起動時に検証資産の保存場所を選べる
- **should:** 個人設定でデフォルトの保存場所を指定でき、設定があればそれを使う
- 保存場所に既存の資産があり、新しく足す資産と共通化できる部分は積極的にモジュールへ切り出す
- skill 自身の配置場所が `~/.claude/skills/web-verify/` であるという前提を撤廃する

## 決定事項サマリ

| 論点 | 決定 |
|---|---|
| 保存場所の範囲 | 対象リポジトリの外も可(個人ディレクトリ等) |
| 不変条件 | 「その場所で skill なしに `npx playwright test` で再実行できる」を残す。「対象リポに commit する」は保存場所がリポ内のときだけの規約に下げる |
| 保存場所の決定順 | 1. 起動時の明示指定 2. 個人設定 `~/.config/web-verify/config.json` の `default`(質問せず使い報告に明記) 3. `AskUserQuestion` 4. 質問できない状況なら検証を始めず止める(blocked) |
| 既存の `.claude/verify/` | 保存場所の決定に使わない。個人設定が無ければ、既存スイートがあっても対話では毎回聞き、deliver 経由では止める(既存スイートの自動検出を提案したうえでユーザーが選んだ) |
| 個人設定の書式 | `{"default": "<path>"}`。リポごとの上書きは持たない。chezmoi では管理しない |
| パスの解決 | 明示指定・個人設定・自由入力のどれにも同じ規則。相対パスは対象 worktree のルート基準(リポ内ならブランチごとのコピーになり git が分ける)。`{repo}` は main worktree のディレクトリ名(bare リポジトリなら git common dir の名前から `.git` を除く)。org 違いの同名リポは同じ `{repo}` になるので、必要ならユーザーが設定のパスで分ける |
| 保存場所の分類 | スイートあり(`playwright.config.ts` と `profile.md`)/ 空 / それ以外。それ以外(`.DS_Store` と書き込み確認用の `.web-verify-write-probe` を除くファイルがある・片方だけの中断の残骸)は上書きせずに止める |
| nono の境界 | `claude-seal.json` の `filesystem.read` に `$XDG_CONFIG_HOME/web-verify` を足す(書き込みは許さない)。nono は存在しないパスの grant を評価しないので、ディレクトリを作った後に起動したセッションで効く。読み取りの拒否は黙って「設定なし」と扱わない。対話なら読めなかったことを伝えてから質問に進み、質問できなければ止める(未作成のまま起動したセッションでも対話を止めないため) |
| スイートの単位 | 1 リポジトリ 1 スイート。シナリオは `scenarios/<feature>/`、seed は `seed/common.ts` + `seed/features/<feature>.ts` |
| 実行時の切り替え | `VERIFY_FEATURE`(シナリオ・seed・生成物の置き場所)/ `VERIFY_REPO_DIR`(対象 worktree)/ `VERIFY_BASE_URL`(`.env` を上書き) |
| 共通化 | 2 か所目で必要になったら `support/` か fixture へ切り出し、既存シナリオも書き換えて再実行で結果不変を確かめる。変わったら戻して報告 |
| 旧レイアウト | config と seed を最小限書き換える。シナリオは移動しない。全体実行で結果不変を確かめる |
| マージ後の機能 | `scenarios/<feature>/` は残してデグレ確認に使う。削除は人間 |
| 承認ゲート | `scenarios/<feature>/` が無いとき(その機能の初回)。質問できない状況では飛ばし「未承認の観点」として報告 |
| 既存 E2E 基盤への相乗り | 提案しない。常に独立したスイート |
| deliver 連携 | 入口 skill が web-verify の「起動前に人間が確かめる事項」(保存場所の決定と分類、`.env` の有無)を確かめ、汎用引数 `verifyArgs` で渡す。文字列の形は web-verify 側で決め、保存場所の決まり方も含めて報告に残す。書き込み確認は副作用があるので web-verify 自身が行う。`VERIFY_SCHEMA` に `blocked` を足し、blocked なら修正エージェントに回さず停止。`verifyPrompt` は「質問できない場合の扱いが skill に書かれていればそれに従う」とし、承認ゲートを飛ばす web-verify の規則を優先させる |
| skill の配置場所 | `<skill-dir>` = `SKILL.md` のあるディレクトリとして参照し、固定パスを書かない |
| スコープ外 | 組織専用の `<work-org>-verify` 系 skill |

## 保存場所をリポジトリの外にも広げた理由

仕事のリポジトリに検証資産を commit しづらいことが動機。外に置くと git による
ブランチごとの分離が効かず、同じ場所に複数ブランチ・worktree の資産が集まる。
そのため次の 3 つをセットで入れる。

1. **機能ごとの分離(`VERIFY_FEATURE`)**: 機能 A のブランチで全体を実行すると未マージの
   機能 B のシナリオ・seed が落ちるため、シナリオと seed を機能単位に分け、今回の機能だけを実行する。
   slug はブランチ名の `/` を `-` に置き換えて作る
2. **並行実行への備え**: 生成物(`test-results/` `report/` `.auth/`)を `<feature>`(未設定時は `_all`)
   のサブディレクトリに分ける。Playwright は実行開始時に `outputDir` と HTML レポートの出力先を消すため、
   同じディレクトリを共有すると別 worktree の実行結果やログイン状態を消してしまう
3. **対象 worktree の指定(`VERIFY_REPO_DIR`)**: 資産の位置からリポジトリを辿れないため実行時に渡す。
   保存場所がリポ内のときだけ、scaffold 時に config へ書いた相対パスから既定値を求める。
   `git rev-parse --show-toplevel` による自動導出は採らない。保存場所自体が別の git リポジトリの中にあると
   そちらを返し、黙って別のリポジトリを指すため

## 質問できない状況で止める理由

保存場所が決まらないまま組み込みの既定値(リポ内の `.claude/verify/`)に書くと、
「仕事のリポジトリに置きたくない」という動機を黙って破る。そのため止める。

deliver の Workflow は動作確認の `passed=false` を修正エージェントに回すので、止めた結果が
コードの書き換えに化ける。これを `blocked` で区別する。`blocked` の範囲は
**ブランチのコードの外に原因があるもの**(保存場所が未決定・書き込みが拒否された・資格情報が無い・
ポートを別 worktree が握っている等)に限る。ブランチのコードが原因でアプリが起動しない場合は
従来どおり `passed=false`。範囲を広げると本物のバグが修正ループを素通りする。

## サンドボックスとの関係

リポジトリの外の保存場所は、nono や Claude Code の Bash サンドボックスの書き込み許可の外にあることが多い。
skill は scaffold の前に保存場所へ書き込めるかを確かめ、拒否されたら迂回せず blocked として止め、
許可を広げるかどうかはユーザーに委ねる。

## 検証

- `deliver.js`: blocked の結果で修正エージェントが起動されないこと、`verifyArgs` が prompt に入り
  統計(public な Issue に投稿されうる)に入らないことを `test/deliver-workflow.test.mjs` で確かめる
- テンプレート: scratch に scaffold し、`VERIFY_FEATURE` の有無で収集されるシナリオが切り替わり、
  `auth-setup` は常に収集されること(Contrast Pair)、`VERIFY_BASE_URL` / `VERIFY_REPO_DIR` の
  未設定で globalSetup が落ちることを実行で確かめる(`--list` は globalSetup を実行しないので使えない)
- skill の手順: サブエージェントに保存場所の選択・共通化・旧レイアウト更新の場面を演じさせて確かめる
