# Review Outcome module の抽出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 週次ジョブの「選別の結果をどう読むか」(Review Outcome)を `executable_harness-weekly.sh` から 1 つの source 専用 lib に移し、fake claude を通さずに lib の interface でテストできるようにする。振る舞いは変えない。

**Architecture:** 新しい lib `dot_claude/scripts/lib/harness-review-outcome.bash` が、結果ファイルの契約(prompt の指示文・形の検査・整形)、Deploy-only Fix の記録、選別が残したものの分類を持つ。週次ジョブは claude の起動前に Integrity Snapshot の lib・公開の lib の後でこの lib を読み込み、分類の値(4 つ)で振り分けるだけになる。本文の追記・Metrics-only PR の要否・公開・手で公開する手順の案内は週次ジョブと公開の lib に残す。

**Tech Stack:** bash 3.2(macOS の `/bin/bash`)、jq、git、bats(`pnpm exec bats`)。

**Spec:** 独立した spec 文書は無い。設計は architecture review の grilling(2026-10-20)で合意した次の決定で、この plan が正本として持つ。
- 範囲: 結果ファイルの検査と整形、Deploy-only Fix の記録(結果ファイルを読めた時点で、どの失敗の判定よりも先に残す順序の不変条件ごと)、未 commit の検査、commit 数と dropped の判定、申告の突き合わせ、選別の commit が記録の置き場に触れていないかの検査、本文が無い採用の検査、選別が失敗した run の分類。Metrics-only PR の要否・本文の追記・公開・手で公開する手順の案内は外。
- 形: claude の起動前に source する lib。prompt の結果ファイルの指示文も lib が持つ。
- 返す値: 標準出力に `publish` / `no-change` / `failed` / `failed-with-commits` の 1 つ。Integrity Snapshot の照合に落ちたら予約コード 3。失敗の診断文は lib が stderr に出す。結果ファイル由来の 2 節(落とした変更・deploy-only の修正)の文字列も lib が返し、追記は呼び出し側が行う。
- 入力: run ごとの値は初期化の引数で受け取る。`~/.claude/harness` 配下の固定のパスと Verdict CLI のパスは lib が `$HOME` から組み立てる。公開の lib の `HARNESS_PUBLISH_RATES_REPO_DIR` / `HARNESS_PUBLISH_LEDGER_REPO_DIR` は読み込み順の前提として読む。
- 用語: `GLOSSARY.md` の Review Outcome(追加済み、未 commit)。
- テスト: replace, don't layer。分類の判定のテストを `test/harness-review-outcome.bats` に移し、`test/harness-weekly.bats` には分類ごとの配線だけを残す。
- PR: 人の PR 1 本・3 commit(Task 1〜3)。新しい lib と bats は Guarded Path。

## Global Constraints

- bash 3.2 互換: `mapfile`・連想配列・`${var,,}` を使わない。`set -u` 下で空配列を展開しない。
- lib は shebang だけを持ち `set` しない。ヘッダに「source 専用。set は呼び出し側に従う」と書く(`.claude/rules/shell-scripts.md`)。
- 日本語を含む文字列に埋める変数は `${VAR}` で囲む。
- `shfmt -i 4` と shellcheck を通す(`just shfmt` / `just shellcheck`)。
- 週次ジョブのログに出る行は `harness-weekly:` で始め、既存の文言を一字一句保つ。lib 自身の使い方の誤りだけ `harness-review-outcome:` で出す(公開の lib と同じ規約)。
- 関数は `$( )` や `||` の右で呼ばれ `set -e` が効かないので、失敗は明示的に返す。
- bats の `@test` 名は日本語なので `LC_ALL=C` で走らせる(`just test-harness-scripts`)。
- 作業は Guarded Path を触る人の PR。ブランチ名を `harness/review-` で始めない。

## Review Focus

1. `harness_review_outcome_classify` は `$( )` で受け取られる。Deploy-only Fix を記録した旨の行(現在 `record_deploy_only` が stdout に出す `harness-weekly: recorded N deploy-only fix(es) …`)が stdout に混ざると、分類の値が壊れて週次ジョブが誤った分岐に進む。lib ではこの行を stderr に出し、stdout が値の 1 行だけであることを Task 1 のテストで確かめる。
2. 照合の後に Verdict CLI が書き換えられた run では、classify が値を出さずに 3 で終わる(現在は 1 に潰している)。週次ジョブはどの非 0 も失敗として扱う。Task 1 と Task 2 の両方でテストを置く。
3. queue を読めない(読み取り権限が無い)run で残数を 0 と読むと、申告の食い違いを見逃して `publish` / `no-change` になる。`failed` になることを Task 1 で確かめる(現在の weekly.bats 1023 行のケース)。
4. 初期化の前に classify / sections を呼ぶか、公開の lib の 2 つの定数が未定義なら、黙って `publish` を出さずに exit 2 で `harness-review-outcome:` の行を出す。Task 1 で確かめる。
5. 選別が失敗した run で、結果ファイルは決めた形なのに Deploy-only Fix の記録が失敗しても、分類は止めない(WARN だけ出す。現在の `report_failed_review` の振る舞い)。Task 1 で確かめる。

---

### Task 1: lib と interface のテスト

**Files:**
- Create: `dot_claude/scripts/lib/harness-review-outcome.bash`
- Create: `test/harness-review-outcome.bats`
- Modify: `justfile`(`test-harness-scripts` の bats の列に `test/harness-review-outcome.bats` を足し、説明の列挙に `review outcome lib` を足す)
- 移す元(読むだけ。この Task では消さない): `dot_claude/scripts/executable_harness-weekly.sh:603-669`(結果ファイルの関数群・`record_deploy_only`・`result_sections`)、`:847-958`(`check_review_claims`・`publish_review` の前半)、`:996-1013`(`report_failed_review` の前半)、`:1182`(prompt の結果ファイルの行)

**Interfaces:**
- Consumes: Integrity Snapshot の lib の `harness_integrity_run` と `HARNESS_INTEGRITY_FAILED`、公開の lib の `HARNESS_PUBLISH_RATES_REPO_DIR` / `HARNESS_PUBLISH_LEDGER_REPO_DIR`(どちらも先に source されている前提)。
- Produces:
  - `harness_review_outcome_init --worktree <dir> --review-result <file> --pr-body <file> --run <採用の印> --date <YYYY-MM-DD>` → 0。引数の欠落・空・余り、公開の lib の 2 定数が未定義なら exit 2。
  - `harness_review_outcome_result_instructions` → prompt に埋める 1 行(`- Always write the result file …`。現在の 1182 行の文面のまま、パスは初期化の値)。
  - `harness_review_outcome_classify <base> <ok|failed|untrusted>` → stdout に値を 1 行。exit 0。Verdict CLI の照合に落ちたら値を出さずに exit 3。誤用(初期化前・引数の誤り)は exit 2。
  - `harness_review_outcome_sections` → 「落とした変更」「deploy-only の修正」の節(現在の `result_sections` と同じ文字列)。結果ファイルが無いか決めた形でなければ何も出さずに exit 0。jq の失敗は exit 1。
  - 固定のパス(lib の内部): queue `$HOME/.claude/harness/queue.md`、判定の記録 `$HOME/.claude/harness/queue-archive.md`、Deploy-only Fix `$HOME/.claude/harness/deploy-only.md`、Verdict CLI `$HOME/.claude/scripts/harness-verdict.sh`。

classify の判定順(`ok` のとき。どれも現在の `publish_review` の文言とログをそのまま出す):
1. 結果ファイルが無いか決めた形でない → `failed`
2. Deploy-only Fix の記録に失敗 → `failed`
3. worktree に未 commit の変更 → `failed`
4. commit 0 件かつ dropped が 1 件以上 → `failed`
5. 申告の突き合わせ(現在の `check_review_claims`)に落ちる → `failed`(Verdict CLI の照合の失敗は exit 3)
6. commit 0 件 → `no-change`
7. 本文が空 → `failed`
8. 選別の commit が `HARNESS_PUBLISH_RATES_REPO_DIR` か `HARNESS_PUBLISH_LEDGER_REPO_DIR` に触れた → `failed`
9. それ以外 → `publish`

`failed` / `untrusted` のとき: 結果ファイルが決めた形なら Deploy-only Fix を記録する(失敗は WARN)。commit 0 件なら現在の 2 つの文面(`untrusted` は「records the job uses were changed …」、`failed` は「review failed before committing …」)を出して `failed`。commit があるか数えられなければ `failed-with-commits`(文面は週次ジョブが出す)。

- [ ] **Step 1: `test/harness-review-outcome.bats` を書く。** setup は `test/harness-publish.bats` に倣う: `HOME` を `$BATS_TEST_TMPDIR/home` にし、integrity・publish・この lib の順に source する。実物の Verdict CLI を `$HOME/.claude/scripts/harness-verdict.sh` に置き、`harness_integrity_snapshot` を取ってから init する。fixture は bare の origin を持たない単純な git repo(base の commit と、テストごとに 0〜2 件の commit)、queue、判定の記録、結果ファイル、本文。ケース(現在の weekly.bats の行番号は移す元):
  - 値ごとに 1 件: `publish`(commit 1 件・本文あり)、`no-change`(commit 0 件・dropped 空)、`failed`(各判定順 1・3・4・5・7・8 から 1 件ずつ)、`failed-with-commits`(`failed` と `untrusted` で commit 1 件)。各ケースで `run --separate-stderr` を使い、`assert_output` で stdout が値の 1 行だけであることを確かめる(Review Focus 1)。
  - Deploy-only Fix: 日付の見出しで追記する(914)、既にある行と結果ファイル内の重複を足さない(951・962)、同じ日の見出しを重ねない(1099)、失敗する分類でも残す(906・942・1074)、結果ファイルが無ければ作らない(1110)、`untrusted` で記録が失敗しても値を出す(Review Focus 5)。
  - 結果ファイル: 形が不正なら `failed`(1119)、空や空白だけ・箇条書きの印の要素を数えず二重にしない(970)、中身のある dropped が 1 つでもあれば `failed`(986)。
  - 申告: queue の残数が dropped より多ければ `failed`(993・1004)、一致すれば通る(1013)、queue を読めなければ `failed`(1023、Review Focus 3)、この run の印があり commit 0 件なら `failed`(1033)、PR の URL に置き換え済みの採用と別の run の印は数えない(1053・1062 の分類部分)。
  - 置き場: 選別の commit が `docs/harness/failure-pattern-rates/` か `docs/harness/rule-ledger/` に触れたら `failed`(1847・2021 の分類部分)。
  - 照合: スナップショットの後に Verdict CLI を書き換え、`ok` で commit 0 件・dropped 空の分類が exit 3 で stdout が空(Review Focus 2)。
  - 誤用: init 前の classify、`HARNESS_PUBLISH_RATES_REPO_DIR` を unset した init が exit 2(Review Focus 4)。
  - 指示文: `harness_review_outcome_result_instructions` の出力に結果ファイルのパスと `{"dropped": [...], "deploy_only": [...]}` が入る。
  - 節: `harness_review_outcome_sections` が dropped と deploy_only のある結果ファイルで 2 節を出し、`$HOME` を `~` で書く。結果ファイルが無ければ出力が空で成功する。

- [ ] **Step 2: 失敗を確かめる。** `LC_ALL=C pnpm exec bats test/harness-review-outcome.bats` が lib が無いことで全件失敗する。

- [ ] **Step 3: lib を書く。** 関数の本体は weekly の移す元をそのまま移し、グローバル変数の参照を init の値と固定のパスに置き換える。内部の関数と変数は `_harness_review_outcome_` で始める。ヘッダには公開の lib と同じ形で、持つもの・読み込み順の前提(integrity → publish → この lib)・Guarded Path に載せてあること・Integrity Snapshot の一覧に載せない理由(claude の前にメモリに載る)・Interface の列挙を書く。`record_deploy_only` の「recorded」行は stderr に出す。

- [ ] **Step 4: 通ることを確かめる。** `LC_ALL=C pnpm exec bats test/harness-review-outcome.bats` が全件 ok。`just shellcheck` と `just shfmt` が通る。

- [ ] **Step 5: Commit。**

```bash
git add dot_claude/scripts/lib/harness-review-outcome.bash test/harness-review-outcome.bats justfile docs/superpowers/plans/2026-10-20-harness-review-outcome.md
git commit -m "refactor(harness): 選別の結果を分類する Review Outcome の lib を足す"
```

---

### Task 2: 週次ジョブを lib に切り替え、移したテストを消す

**Files:**
- Modify: `dot_claude/scripts/executable_harness-weekly.sh`
- Modify: `test/harness-weekly.bats`

**Interfaces:**
- Consumes: Task 1 の 4 つの関数。
- Produces: なし(振る舞いは変えない)。

- [ ] **Step 1: 配線のテストを足す。** `test/harness-weekly.bats` に、`weekly_without_publish_lib`(2299 行)と同じ形で review outcome の lib が無い・壊れた入口の複製を起動するケースを 1 件足す。期待: `harness-review-outcome.bash is missing or broken` で失敗し、失敗の Issue は作る。

- [ ] **Step 2: 失敗を確かめる。** `LC_ALL=C pnpm exec bats test/harness-weekly.bats -f 'review outcome'`(テスト名に合わせる)が失敗する。

- [ ] **Step 3: 週次ジョブを書き換える。**
  - 公開の lib の読み込みの直後に、同じ手順(可読・`bash -n`・source・`declare -F` で 4 関数)で lib を読み、`harness_publish_init` の後に `harness_review_outcome_init` を呼ぶ。`REVIEW_RESULT` / `DEPLOY_ONLY` の定義のコメントのうち形の説明は lib に移ったので、パスの定義だけ残す。
  - 移した関数(`review_result_valid`・`RESULT_ITEMS_FILTER`・`result_items`・`result_count`・`record_deploy_only`・`result_sections`・`check_review_claims`)を消す。`count_queue` と `adopted_titles` は main の工程と Rule Ledger の節が使うので残す。
  - `publish_review` は classify の値で振り分ける: 非 0 の終了 → `return 1`。`failed` → `return 1`。`no-change` → 現在の Metrics-only PR / discard の分岐。`publish` → `harness_review_outcome_sections >>"$PR_BODY"` の後、現在の節の追加(検出件数・推移・評価・純増・Rule Ledger)と `harness_publish_review`。
  - `report_failed_review` は `failed` / `untrusted` を classify に渡し、`failed` なら戻る。`failed-with-commits` なら commit 数を数え、`harness_review_outcome_sections` を本文に足し(失敗は WARN)、残りの現在の分岐(データを信頼できるときの検出件数と推移の節、手で公開する手順か公開しない案内)をそのまま行う。
  - `REVIEW_PROMPT` の結果ファイルの行を `$(harness_review_outcome_result_instructions)` に置き換える(代入を分けて失敗を見る)。

- [ ] **Step 4: 移したケースを消す。** Task 1 Step 1 で行番号を挙げたケースのうち、分類・Deploy-only Fix・結果ファイル・申告・置き場だけを確かめているものを消す。残すのは配線: 851(`no-change`)・1043(`publish`)・829(`failed`)・1084(`failed-with-commits` の本文の節)・933(前の run の結果ファイルを消す)・1062(finish_run)・1333 と 1353(prompt の文面)・1880(Metrics-only PR)・2451(照合)・Step 1 で足したケース。消した後に使われなくなった `STUB_REVIEW_MODE` のモードと `STUB_RESULT` の分岐を stub から消す。

- [ ] **Step 5: 通ることを確かめる。** `just test-harness-scripts` が全件 ok(出力はファイルに書いて `grep -naE 'not ok|^1\.\.'` で見る)。`just shellcheck` と `just shfmt` が通る。`grep -n "review_result_valid\|record_deploy_only\|check_review_claims\|RESULT_ITEMS_FILTER" dot_claude/scripts/executable_harness-weekly.sh` が 0 件。

- [ ] **Step 6: Commit。**

```bash
git add dot_claude/scripts/executable_harness-weekly.sh test/harness-weekly.bats
git commit -m "refactor(harness): 週次ジョブの選別の結果の判定を Review Outcome の lib に移す"
```

---

### Task 3: Guarded Path・ルール・用語を揃える

**Files:**
- Modify: `scripts/guarded-paths.txt`(公開の lib の行の後に、新しい lib と bats をコメント付きで足す)
- Modify: `.claude/rules/harness-weekly.md`(「選別の結果ファイル」「heartbeat を書く条件」の項で `publish_review` / `check_review_claims` のコメントを指している箇所を、lib のヘッダを指すように直す)
- Modify: `dot_claude/scripts/CLAUDE.md`(Weekly harness job の段落の正本の列挙に、選別の結果の分類は `lib/harness-review-outcome.bash` を足す)
- Modify: `GLOSSARY.md`(Review Outcome。作業ツリーに追加済み)

**Interfaces:**
- Consumes: Task 1 と Task 2 のファイル名。
- Produces: なし。

- [ ] **Step 1: 上の 4 ファイルを直す。** `grep -rn 'check_review_claims\|publish_review\|result_sections\|record_deploy_only' .claude dot_claude docs/adr CLAUDE.md harness/modules` で古い参照を探し、移した関数を指すものを lib に向ける(`publish_review` 自体は残るので、残る役割を指す参照はそのまま)。

- [ ] **Step 2: 確かめる。** `just lint-fast` と `just test-harness-scripts` が通る(`[slow]` なので明示する)。`just check-instructions` が drift を出さない(`harness/modules/` を触ったときは `just harness-sync` の後に)。

- [ ] **Step 3: Commit。**

```bash
git add scripts/guarded-paths.txt .claude/rules/harness-weekly.md dot_claude/scripts/CLAUDE.md GLOSSARY.md
git commit -m "docs(harness): Review Outcome の lib を Guarded Path とルールと用語に載せる"
```
