# 週次ジョブの Review Outcome の module(lib/harness-review-outcome.bash)の interface の検査。lib を直接 source する。
# 選別の claude が残したもの(worktree・結果ファイル・queue・判定の記録・本文)から分類の値を決めることと、
# Deploy-only Fix の記録・結果ファイル由来の本文の節はここで検査する。値ごとに週次ジョブが何をするか(公開・
# Metrics-only PR・手で公開する手順の案内)と、この lib を読み込めないときに止まることは test/harness-weekly.bats が検査する。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    mkdir -p "$HOME/.claude/scripts" "$HDIR"
    cp "$REPO_ROOT/dot_claude/scripts/executable_harness-verdict.sh" "$HOME/.claude/scripts/harness-verdict.sh"
    # 週次ジョブと同じ順に読む(Integrity Snapshot → 公開 → この lib)
    # shellcheck source=../dot_claude/scripts/lib/harness-integrity.bash
    source "$REPO_ROOT/dot_claude/scripts/lib/harness-integrity.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-publish.bash
    source "$REPO_ROOT/dot_claude/scripts/lib/harness-publish.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-review-outcome.bash
    source "$REPO_ROOT/dot_claude/scripts/lib/harness-review-outcome.bash"

    WT="$BATS_TEST_TMPDIR/worktree"
    git init -q "$WT"
    git -C "$WT" config user.email t@example.invalid
    git -C "$WT" config user.name t
    git -C "$WT" config commit.gpgsign false
    printf 'base\n' >"$WT/README.md"
    git -C "$WT" add -A
    git -C "$WT" commit -qm base
    BASE=$(git -C "$WT" rev-parse HEAD)
    RESULT="$HDIR/review-result-2026-10-20.json"
    BODY="$HDIR/review-pr-body-2026-10-20.md"
    RUN_MARK="harness/review-2026-10-20 run 0f0e"
    printf '# Harness improvement queue\n' >"$HDIR/queue.md"
    harness_integrity_snapshot
    harness_review_outcome_init --worktree "$WT" --review-result "$RESULT" --pr-body "$BODY" --run "$RUN_MARK" --date 2026-10-20
}

# 選別の commit を 1 件足す(<パス> を省くと change.md)
review_commit() { # [<パス>]
    local path=${1:-change.md}
    mkdir -p "$(dirname "$WT/$path")"
    printf '%s\n' "$RANDOM" >>"$WT/$path"
    git -C "$WT" add -A
    git -C "$WT" commit -qm "harness: $path"
}

result() { # <結果ファイルの中身>
    printf '%s\n' "$1" >"$RESULT"
}

empty_result() {
    result '{"dropped":[],"deploy_only":[]}'
}

body() {
    printf '## 採用\n\n- entry\n' >"$BODY"
}

queue_entries() { # <件数>
    local i
    for ((i = 1; i <= $1; i++)); do
        printf '\n## [2026-10-03] entry %s\n\n- **Scope:** global\n' "$i" >>"$HDIR/queue.md"
    done
}

classify() { # <claude の成否>
    run --separate-stderr harness_review_outcome_classify "$BASE" "$1"
}

@test "commit と本文があり申告も合えば publish を出す" {
    empty_result
    body
    review_commit
    classify ok
    assert_success
    assert_output 'publish'
}

@test "commit も落とした変更も無ければ、本文があっても no-change を出す" {
    empty_result
    body
    classify ok
    assert_success
    assert_output 'no-change'
}

@test "Deploy-only Fix を記録した行は stdout に混ぜず、値だけを出す" {
    result '{"dropped":[],"deploy_only":["x を適用する"]}'
    classify ok
    assert_success
    assert_output 'no-change'
    [[ "$stderr" == *'recorded 1 deploy-only fix(es)'* ]]
}

@test "結果ファイルが無ければ failed を出す" {
    classify ok
    assert_success
    assert_output 'failed'
    [[ "$stderr" == *"did not write a valid result file $RESULT"* ]]
}

@test "結果ファイルが JSON として読めないか、決めた形でなければ failed を出す" {
    local broken
    for broken in 'not json' '' '{}' '{"dropped":[]}' '{"dropped":"x","deploy_only":[]}' '{"dropped":[1],"deploy_only":[]}' '[]'; do
        result "$broken"
        classify ok
        assert_success
        assert_output 'failed'
    done
}

@test "commit されていない変更が残っていれば failed を出す" {
    empty_result
    printf 'dirty\n' >"$WT/dirty.md"
    classify ok
    assert_output 'failed'
    [[ "$stderr" == *'review left uncommitted changes'* ]]
}

@test "commit が無く落とした変更があれば、変更なしと扱わずに failed を出す" {
    result '{"dropped":["harness: add rule(shellcheck で失敗)"],"deploy_only":[]}'
    queue_entries 1
    classify ok
    assert_output 'failed'
    [[ "$stderr" == *'dropped 1 change(s)'* ]]
    [[ "$stderr" == *'harness: add rule(shellcheck で失敗)'* ]]
}

@test "中身のある落とした変更が 1 つでもあれば、空の要素と混ざっていても failed を出す" {
    result '{"dropped":["", "x(prek で失敗)"],"deploy_only":[]}'
    queue_entries 1
    classify ok
    assert_output 'failed'
    [[ "$stderr" == *'dropped 1 change(s)'* ]]
}

@test "空や空白だけの落とした変更は数えない" {
    result '{"dropped":["", "  ", "- "],"deploy_only":[]}'
    classify ok
    assert_output 'no-change'
}

@test "dropped が空なのに queue に項目が残っていれば failed を出す" {
    empty_result
    queue_entries 1
    classify ok
    assert_output 'failed'
    [[ "$stderr" == *"review left 1 entr(ies) in $HDIR/queue.md but reported 0 dropped change(s)"* ]]
}

@test "commit があっても、dropped が空なのに queue に項目が残っていれば failed を出す" {
    empty_result
    body
    review_commit
    queue_entries 1
    classify ok
    assert_output 'failed'
}

@test "queue に残った項目と dropped の件数が一致すれば publish を出す" {
    result '{"dropped":["harness: other entry(prek で失敗)"],"deploy_only":[]}'
    body
    review_commit
    queue_entries 1
    classify ok
    assert_output 'publish'
}

@test "queue を読めなければ、残数を 0 と読まずに failed を出す" {
    [ "$(id -u)" -ne 0 ] || skip "root は mode 000 のファイルも読めるので再現できない"
    empty_result
    chmod 000 "$HDIR/queue.md"
    classify ok
    chmod 600 "$HDIR/queue.md"
    assert_output 'failed'
    [[ "$stderr" == *"failed to count the entries in $HDIR/queue.md"* ]]
}

@test "この run の採用の印が判定の記録にあるのに commit が無ければ failed を出す" {
    empty_result
    printf -- '## [2026-10-03] entry\n\n- **Verdict:** adopted (%s)\n' "$RUN_MARK" >"$HDIR/queue-archive.md"
    classify ok
    assert_output 'failed'
    [[ "$stderr" == *"has 1 verdict(s) adopted in run \"$RUN_MARK\" but the review committed nothing"* ]]
}

@test "PR の URL に置き換え済みの採用と別の run の印は、commit が無いことの失敗に数えない" {
    empty_result
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (PR https://github.com/example/dotfiles/pull/1)\n\n## [2026-01-02] other\n\n- **Verdict:** adopted (harness/review-2026-10-20 run old)\n' >"$HDIR/queue-archive.md"
    classify ok
    assert_output 'no-change'
}

@test "スナップショットの後に Verdict CLI が書き換えられたら、値を出さずに 3 で終わる" {
    empty_result
    printf '# tampered\n' >>"$HOME/.claude/scripts/harness-verdict.sh"
    classify ok
    assert_equal "$status" 3
    assert_output ''
}

@test "commit があるのに本文が無ければ failed を出す" {
    empty_result
    review_commit
    classify ok
    assert_output 'failed'
    [[ "$stderr" == *'no PR body'* ]]
}

@test "選別の commit が週の記録か Rule Ledger の置き場に触れたら failed を出す" {
    local dir
    for dir in "$HARNESS_PUBLISH_RATES_REPO_DIR" "$HARNESS_PUBLISH_LEDGER_REPO_DIR"; do
        empty_result
        body
        git -C "$WT" reset -q --hard "$BASE"
        review_commit "$dir/x.json"
        classify ok
        assert_output 'failed'
        [[ "$stderr" == *"review commits touched $dir"* ]]
    done
}

@test "Deploy-only Fix は日付の見出しの下に追記し、前の記録を消さない" {
    printf '## 2026-01-01\n\n- old fix\n' >"$HDIR/deploy-only.md"
    result '{"dropped":[],"deploy_only":["new fix"]}'
    classify ok
    run cat "$HDIR/deploy-only.md"
    assert_line '- old fix'
    assert_line '## 2026-10-20'
    assert_line '- new fix'
}

@test "同じ日の Deploy-only Fix は見出しを重ねない" {
    printf '## 2026-10-20\n\n- first fix\n\n' >"$HDIR/deploy-only.md"
    result '{"dropped":[],"deploy_only":["second fix"]}'
    classify ok
    run grep -c '^## 2026-10-20$' "$HDIR/deploy-only.md"
    assert_output '1'
    run grep -c '^- second fix$' "$HDIR/deploy-only.md"
    assert_output '1'
}

@test "既にある Deploy-only Fix と、結果ファイルの中で重なったものは二重に足さない" {
    printf '## 2026-01-01\n\n- same fix\n' >"$HDIR/deploy-only.md"
    result '{"dropped":[],"deploy_only":["same fix","other fix","other fix"]}'
    classify ok
    run grep -c '^- same fix$' "$HDIR/deploy-only.md"
    assert_output '1'
    run grep -c '^- other fix$' "$HDIR/deploy-only.md"
    assert_output '1'
}

@test "Deploy-only Fix は空の要素を捨て、改行を潰し、箇条書きの印を二重にしない" {
    result '{"dropped":[],"deploy_only":["", " - bullet fix ", "* star fix", "複数行の\n説明"]}'
    classify ok
    run cat "$HDIR/deploy-only.md"
    assert_line '- bullet fix'
    assert_line '- star fix'
    assert_line '- 複数行の 説明'
    refute_line '- '
    refute_output --partial '- - '
}

@test "failed になる分類でも、結果ファイルを読めた時点で Deploy-only Fix を残す" {
    result '{"dropped":["x(prek で失敗)"],"deploy_only":["y を適用する"]}'
    printf 'dirty\n' >"$WT/dirty.md"
    classify ok
    assert_output 'failed'
    run cat "$HDIR/deploy-only.md"
    assert_line '- y を適用する'
}

@test "選別の claude が commit せずに失敗したら failed を出し、Deploy-only Fix は残す" {
    result '{"dropped":[],"deploy_only":["w を適用する"]}'
    classify failed
    assert_output 'failed'
    [[ "$stderr" == *'review failed before committing'* ]]
    run cat "$HDIR/deploy-only.md"
    assert_line '- w を適用する'
}

@test "照合に落ちた選別が commit していなければ、claude の失敗と読める文面を出さずに failed を出す" {
    empty_result
    classify untrusted
    assert_output 'failed'
    [[ "$stderr" == *'the records the job uses were changed'* ]]
    [[ "$stderr" != *'review failed before committing'* ]]
}

@test "選別の claude が commit を残して失敗したら、信頼できるかに関わらず failed-with-commits を出す" {
    local claude
    for claude in failed untrusted; do
        empty_result
        review_commit
        classify "$claude"
        assert_success
        assert_output 'failed-with-commits'
    done
}

@test "選別の claude が結果ファイルを書かずに失敗したら、Deploy-only Fix の記録を作らない" {
    classify failed
    assert_output 'failed'
    assert [ ! -f "$HDIR/deploy-only.md" ]
    [[ "$stderr" != *'failed to record deploy-only'* ]]
}

@test "選別の claude が失敗した run で Deploy-only Fix を記録できなくても分類は出す" {
    result '{"dropped":[],"deploy_only":["w を適用する"]}'
    mkdir "$HDIR/deploy-only.md"
    review_commit
    classify failed
    assert_output 'failed-with-commits'
    [[ "$stderr" == *'failed to record deploy-only fixes'* ]]
}

@test "結果ファイル由来の 2 節を、パスを ~ で書いて出す" {
    result '{"dropped":["harness: other(prek で失敗)"],"deploy_only":["v を適用する"]}'
    run --separate-stderr harness_review_outcome_sections
    assert_success
    assert_output --partial '## 落とした変更'
    assert_output --partial '- harness: other(prek で失敗)'
    assert_output --partial '## deploy-only の修正'
    assert_output --partial '- v を適用する'
    assert_output --partial '~/.claude/harness/deploy-only.md にも記録した'
    refute_output --partial "$HOME"
}

@test "要素の無い節は出さない" {
    result '{"dropped":["x"],"deploy_only":[]}'
    run --separate-stderr harness_review_outcome_sections
    assert_output --partial '## 落とした変更'
    refute_output --partial '## deploy-only の修正'
}

@test "結果ファイルが無いか決めた形でなければ、節は出さずに成功する" {
    run --separate-stderr harness_review_outcome_sections
    assert_success
    assert_output ''
    result '{}'
    run --separate-stderr harness_review_outcome_sections
    assert_success
    assert_output ''
}

@test "結果ファイルの指示文は、パスと形を含む 1 行を出す" {
    run --separate-stderr harness_review_outcome_result_instructions
    assert_success
    assert_equal "${#lines[@]}" 1
    assert_output --partial "the result file $RESULT"
    assert_output --partial '{"dropped": [...], "deploy_only": [...]}'
}

@test "初期化の前に呼ぶと、値を出さずに 2 で終わる" {
    run bash -c 'set -euo pipefail
        source "$1/dot_claude/scripts/lib/harness-integrity.bash"
        source "$1/dot_claude/scripts/lib/harness-publish.bash"
        source "$1/dot_claude/scripts/lib/harness-review-outcome.bash"
        harness_review_outcome_classify HEAD ok' _ "$REPO_ROOT"
    assert_equal "$status" 2
    assert_output --partial 'harness-review-outcome:'
    refute_line 'publish'
}

@test "公開の lib の置き場の定数が無ければ、初期化が 2 で終わる" {
    unset HARNESS_PUBLISH_RATES_REPO_DIR
    run harness_review_outcome_init --worktree "$WT" --review-result "$RESULT" --pr-body "$BODY" --run "$RUN_MARK" --date 2026-10-20
    assert_equal "$status" 2
    assert_output --partial 'HARNESS_PUBLISH_RATES_REPO_DIR'
}

@test "初期化の引数の欠落・空・余りは 2 で終わる" {
    run harness_review_outcome_init --worktree "$WT" --review-result "$RESULT" --pr-body "$BODY" --run "$RUN_MARK"
    assert_equal "$status" 2
    run harness_review_outcome_init --worktree '' --review-result "$RESULT" --pr-body "$BODY" --run "$RUN_MARK" --date 2026-10-20
    assert_equal "$status" 2
    run harness_review_outcome_init --worktree "$WT" --review-result "$RESULT" --pr-body "$BODY" --run "$RUN_MARK" --date 2026-10-20 extra
    assert_equal "$status" 2
}

@test "classify の claude の成否が ok / failed / untrusted 以外なら 2 で終わる" {
    empty_result
    classify maybe
    assert_equal "$status" 2
    assert_output ''
}
