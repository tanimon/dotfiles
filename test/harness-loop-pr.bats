# 週次ジョブの Loop PR の module(lib/harness-loop-pr.bash)の interface の検査。lib を直接 source する。
# 選別の経路(当日のブランチの照会・作業場所の準備・選別の実行・分類・評価と封印・本文・公開・失敗した選別の案内)、
# 選別を省いた週の Metrics-only PR、片付け、選別の prompt の指示はここで検査する。選別の claude の代わりに、worktree に
# commit と本文・結果ファイルを書くシェル関数を選別の経路の入口に渡す。本文の lib と Review Outcome の lib は stub せず
# 本物を使う(本文の節の中身は test/harness-pr-body.bats、分類の細部は test/harness-review-outcome.bats の範囲)。
# 週次ジョブがこの lib を読み込めないときに止まること、工程の順序、選別の claude の成否と入口の成否が run の成否と
# heartbeat に届く配線は test/harness-weekly.bats が検査する。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    LIB_DIR="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude/scripts"
    # 選別の代わりの関数は相対パスで commit するので、worktree の外で走ったときにリポジトリの中にいないようにする
    cd "$BATS_TEST_TMPDIR" || return 1
    # 週次ジョブと同じく、Integrity Snapshot の lib の後でこの lib だけを読む(Review Outcome と本文の lib はこの lib が読む)
    # shellcheck source=../dot_claude/scripts/lib/harness-integrity.bash
    source "$LIB_DIR/harness-integrity.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-loop-pr.bash
    source "$LIB_DIR/harness-loop-pr.bash"
}

@test "push のコマンドは、リポジトリを渡せば -C 付き、渡さなければ -C 無しで綴る" {
    run harness_loop_pr_push_command harness/review-2026-10-17 /work/repo
    assert_success
    assert_output 'git -C /work/repo push origin harness/review-2026-10-17'
    run harness_loop_pr_push_command '<branch>'
    assert_success
    assert_output 'git push origin <branch>'
}

@test "draft PR の作成のコマンドは、本文を渡せば --body-file 付き、渡さなければ無しで綴る" {
    run harness_loop_pr_create_command harness/review-2026-10-17 /h/review-pr-body-2026-10-17.md
    assert_success
    assert_output 'gh pr create --draft --base main --head harness/review-2026-10-17 --body-file /h/review-pr-body-2026-10-17.md'
    run harness_loop_pr_create_command '<branch>'
    assert_success
    assert_output 'gh pr create --draft --base main --head <branch>'
}

@test "判定の記録に PR の URL を記録するコマンドは、印をシングルクォートで囲んで綴る" {
    run harness_loop_pr_record_command 'harness/review-2026-10-17 run 0f0e'
    assert_success
    assert_output "bash ~/.claude/scripts/harness-verdict.sh publish --run 'harness/review-2026-10-17 run 0f0e' --pr-url <PR URL>"
}

# 綴りを人が貼り付けて <PR URL> を埋めて実行したときに、CLI が受け取る印を記録する
paste_record_command() { # <印>
    local command
    cat >"$HOME/.claude/scripts/harness-verdict.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HOME/verdict-args"
EOF
    command=$(harness_loop_pr_record_command "$1")
    eval "${command/<PR URL>/https://github.com/example/dotfiles/pull/42}"
}

@test "印が ' や \$( ) を含んでも、貼り付けたコマンドは印をそのまま CLI に渡す" {
    run paste_record_command "Bob's \$(touch $HOME/expanded) fix"
    assert_success
    run cat "$HOME/verdict-args"
    assert_output "$(printf '%s\n' publish --run "Bob's \$(touch $HOME/expanded) fix" --pr-url https://github.com/example/dotfiles/pull/42)"
    assert [ ! -e "$HOME/expanded" ]
}

@test "印が引用符を含まなければ、貼り付けたコマンドは印をそのまま CLI に渡す" {
    run paste_record_command 'harness/review-2026-10-17 run 0f0e'
    assert_success
    run sed -n 3p "$HOME/verdict-args"
    assert_output 'harness/review-2026-10-17 run 0f0e'
}

init_loop_pr() { # [<上書きする引数>…]
    harness_loop_pr_init --repo /work/repo --worktree /h/review-worktree \
        --branch harness/review-2026-10-17 --loop-branch-prefix harness/review- \
        --pr-body /h/review-pr-body-2026-10-17.md --review-result /h/review-result-2026-10-17.json \
        --eval-requests /h/eval-requests-2026-10-17.json --eval-results /h/eval-results-2026-10-17.json --eval-budget-usd 5 \
        --date 2026-10-17 --run 'harness/review-2026-10-17 run 0f0e' "$@"
}

@test "初期化は run ごとの値と Loop PR のブランチの prefix がすべて揃えば成功する" {
    run init_loop_pr
    assert_success
    assert_output ''
}

@test "初期化は値が欠けていれば、欠けた引数の名前を出して失敗する" {
    run harness_loop_pr_init --repo /work/repo --worktree /h/review-worktree \
        --branch harness/review-2026-10-17 --loop-branch-prefix harness/review- \
        --pr-body /h/review-pr-body-2026-10-17.md --review-result /h/review-result-2026-10-17.json --eval-results /h/eval-results-2026-10-17.json \
        --date 2026-10-17
    assert_failure
    assert_output --partial '--run'
    assert_output --partial '--eval-requests'
    assert_output --partial '--eval-budget-usd'
    run init_loop_pr --worktree ''
    assert_failure
    assert_output --partial '--worktree'
}

@test "初期化は知らない引数を受け付けない" {
    run init_loop_pr --repository /work/repo
    assert_failure
    assert_output --partial '--repository'
}

@test "初期化はブランチが Loop PR の prefix で始まらなければ失敗する" {
    run init_loop_pr --branch feature/x
    assert_failure
    assert_output --partial 'feature/x'
    assert_output --partial 'harness/review-'
}

@test "初期化は公開に使う値が空か壊れていれば失敗する" {
    local name
    for name in _HARNESS_LOOP_PR_RATES_REPO_DIR _HARNESS_LOOP_PR_LEDGER_REPO_DIR _HARNESS_LOOP_PR_AGENT_GIT_CONFIG \
        _HARNESS_LOOP_PR_METRICS_ONLY_WEEKS; do
        run bash -c 'set -euo pipefail
            for lib in integrity review-outcome pr-body loop-pr; do source "$1/harness-$lib.bash"; done
            printf -v "$2" "%s" ""
            harness_loop_pr_init --repo /work/repo --worktree /h/review-worktree \
                --branch harness/review-2026-10-17 --loop-branch-prefix harness/review- \
                --pr-body /h/body.md --review-result /h/result.json --eval-requests /h/eval-requests.json \
                --eval-results /h/eval-results.json --eval-budget-usd 5 \
                --date 2026-10-17 --run mark' _ "$LIB_DIR" "$name"
        assert_failure
        assert_output 'harness-loop-pr: the publish values of this lib are empty or broken; run chezmoi apply'
    done
    _HARNESS_LOOP_PR_METRICS_ONLY_WEEKS=four
    run init_loop_pr
    assert_failure
    assert_output --partial 'the publish values of this lib are empty or broken'
}

# <Review Outcome の lib の中身> <本文の lib の中身>(missing なら置かない)を置いたディレクトリに、この lib の写しを置いて読む
source_with_siblings() {
    local dir="$BATS_TEST_TMPDIR/lib-$RANDOM"
    mkdir -p "$dir"
    cp "$LIB_DIR/harness-integrity.bash" "$LIB_DIR/harness-loop-pr.bash" "$dir/"
    [[ "$1" == missing ]] || printf '%s\n' "$1" >"$dir/harness-review-outcome.bash"
    [[ "$2" == missing ]] || printf '%s\n' "$2" >"$dir/harness-pr-body.bash"
    bash -c 'set -euo pipefail
        source "$1/harness-integrity.bash"
        source "$1/harness-loop-pr.bash" || { printf "source failed\n"; exit 1; }
        printf "loaded\n"' _ "$dir"
}

@test "読み込むと Review Outcome の lib と本文の lib も読み込み、どちらかが無いか欠けていれば理由を出して読み込みが失敗する" {
    local outcome body
    outcome=$(cat "$LIB_DIR/harness-review-outcome.bash")
    body=$(cat "$LIB_DIR/harness-pr-body.bash")
    run source_with_siblings "$outcome" "$body"
    assert_success
    assert_output loaded
    run source_with_siblings missing "$body"
    assert_failure
    assert_line --partial 'harness-review-outcome.bash is missing or broken; run chezmoi apply'
    assert_line 'source failed'
    run source_with_siblings 'harness_review_outcome_init() {' "$body"
    assert_failure
    assert_line --partial 'harness-review-outcome.bash is missing or broken'
    # 本文の lib が無くても、Review Outcome の lib の欠けを先に告げる
    run source_with_siblings '# empty' missing
    assert_failure
    assert_line --partial 'harness-review-outcome.bash lacks the review outcome checks; run chezmoi apply'
    run source_with_siblings "$outcome" missing
    assert_failure
    assert_line --partial 'harness-pr-body.bash is missing or broken; run chezmoi apply'
    run source_with_siblings "$outcome" '# empty'
    assert_failure
    assert_line --partial 'harness-pr-body.bash lacks the PR body sections; run chezmoi apply'
}

@test "選別の指示は、1 回の初期化だけで、結果ファイル・本文・記録の置き場に触れさせないことを 1 つにまとめて返す" {
    init_loop_pr
    run harness_loop_pr_review_instructions
    assert_success
    assert_equal "${#lines[@]}" 2
    assert_line --index 0 --partial '- Always write the result file /h/review-result-2026-10-17.json before you finish'
    assert_line --index 1 --partial '- Write the PR body (in Japanese) to /h/review-pr-body-2026-10-17.md:'
    assert_line --index 1 --partial "Never change files under docs/harness/failure-pattern-rates or docs/harness/rule-ledger, or the local Rule Ledger in $HOME/.claude/harness/rule-ledger; this job commits them."
}

@test "選別に触れさせない Rule Ledger の置き場は、Rule Ledger のスクリプトが書き出す置き場と同じ" {
    local ledger_repo_dir
    ledger_repo_dir=$(sed -n 's/^LEDGER_REPO_DIR="\(.*\)"$/\1/p' "$REPO_ROOT/dot_claude/scripts/executable_harness-rule-ledger.sh")
    assert_equal "$ledger_repo_dir" docs/harness/rule-ledger
    init_loop_pr
    run harness_loop_pr_review_instructions
    assert_output --partial " or ${ledger_repo_dir}, or the local Rule Ledger"
}

@test "選別に触れさせない Weekly Rate Record の置き場は、再発率の CLI が書き出す置き場と同じ" {
    local rates_repo_dir
    rates_repo_dir=$(sed -n 's/^RATES_REPO_DIR="\(.*\)"$/\1/p' "$REPO_ROOT/dot_claude/scripts/executable_harness-failure-rates.sh")
    assert_equal "$rates_repo_dir" docs/harness/failure-pattern-rates
    init_loop_pr
    run harness_loop_pr_review_instructions
    assert_output --partial "Never change files under ${rates_repo_dir} or"
}

# <Source> が <一覧> の行(完全一致か、末尾 / の行の配下。先頭の + は外す)に当たれば 0
guarded() { # <Source> <一覧のファイル>
    local line
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == '#'* ]] && continue
        line=${line#+}
        if [[ "$line" == */ ]]; then
            [[ "$1" == "$line"* ]] && return 0
        elif [[ "$1" == "$line" ]]; then
            return 0
        fi
    done <"$2"
    return 1
}

@test "この lib とその bats は Guarded Path に載っている" {
    run guarded dot_claude/scripts/lib/harness-loop-pr.bash "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
    run guarded test/harness-loop-pr.bats "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
}

# publish_fixture は Loop PR の module の入口の検査の fixture。git は実物を使い、origin は使い捨ての bare リポジトリにする。
# gh と pnpm は PATH に置いた偽物、Rule Ledger のスクリプトは書き出す件数を STUB_LEDGER_EXPORT で決める偽物、再発率の
# スクリプトは推移の節を出し、書き出す記録を STUB_RATES_EXPORT で決める偽物、Eval Case の評価のスクリプトは結果と節を書くだけの
# 偽物にする(記録の選び方は test/harness-rule-ledger.bats と test/harness-failure-rates.bats、推移の中身は
# test/harness-failure-rates.bats、評価の中身は test/harness-eval-cases.bats の範囲)。
# Integrity Snapshot・Review Outcome・本文の lib は本物を使う。
#
# 偽の gh:
# - pr list は STUB_GH_OPEN_PRS(既定 [])の JSON に、渡された --jq の式を jq -r で当てて返す(本物の gh と同じく、
#   照会の式そのものを検査に残す)。STUB_GH_LIST_FAIL で失敗する
# - pr create は --body-file を GH_BODY に写し、STUB_GH_FAIL で失敗し、成功時は PR の URL を出す
# 呼び出しはすべて GH_LOG に 1 行ずつ書く
publish_fixture() {
    unset STUB_GH_OPEN_PRS STUB_GH_LIST_FAIL STUB_GH_HEAD_PRS STUB_GH_HEAD_LIST_FAIL STUB_GH_FAIL STUB_PNPM_FAIL \
        STUB_PNPM_INSTALL_FAIL STUB_LEDGER_EXPORT STUB_LEDGER_FAIL STUB_LEDGER_TAMPER_RATES STUB_RATES_TAMPER_LEDGER STUB_EVAL_FAIL \
        STUB_EVAL_FAIL_AFTER_WRITE STUB_EVAL_NO_OUT STUB_EVAL_TAMPER STUB_RATES_EXPORT STUB_RATES_EXPORT_OUTPUT STUB_EXPORT_TAMPER_LEDGER HARNESS_REVIEW_RUN
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    printf '[user]\n\tname = test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
        >"$GIT_CONFIG_GLOBAL"
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_BODY="$BATS_TEST_TMPDIR/gh-body.md" PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log" \
        EVAL_LOG="$BATS_TEST_TMPDIR/eval.log" EVAL_ENV_LOG="$BATS_TEST_TMPDIR/eval-env.log" REVIEW_LOG="$BATS_TEST_TMPDIR/review.log"
    HDIR="$HOME/.claude/harness"
    RATES="$HDIR/failure-pattern-rates"
    mkdir -p "$RATES"
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    REPO="$BATS_TEST_TMPDIR/repo"
    WT="$HDIR/review-worktree"
    BRANCH=test/loop-2026-10-17
    BODY="$HDIR/review-pr-body-2026-10-17.md"
    RESULT="$HDIR/review-result-2026-10-17.json"
    EVAL_REQUESTS="$HDIR/eval-requests-2026-10-17.json"
    EVAL_RESULTS="$HDIR/eval-results-2026-10-17.json"
    git init -q --bare "$ORIGIN"
    git clone -q "$ORIGIN" "$REPO" 2>/dev/null
    printf 'line1\n' >"$REPO/README.md"
    git -C "$REPO" add README.md
    git -C "$REPO" commit -qm init
    git -C "$REPO" push -q origin main

    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
'pr list')
    expression="" prs=${STUB_GH_OPEN_PRS:-[]}
    if [[ "$*" == *' --head '* ]]; then
        [[ -z "${STUB_GH_HEAD_LIST_FAIL:-}" ]] || exit 1
        prs=${STUB_GH_HEAD_PRS:-[]}
    else
        [[ -z "${STUB_GH_LIST_FAIL:-}" ]] || exit 1
    fi
    while [[ $# -gt 0 ]]; do
        [[ "$1" == --jq ]] && expression=$2
        shift
    done
    printf '%s\n' "$prs" | jq -r "$expression"
    ;;
'pr create')
    while [[ $# -gt 0 ]]; do
        [[ "$1" == --body-file ]] && cp "$2" "$GH_BODY"
        shift
    done
    [[ -z "${STUB_GH_FAIL:-}" ]] || exit 1
    printf 'Creating draft pull request\nhttps://github.com/example/dotfiles/pull/42\n'
    ;;
*) exit 1 ;;
esac
EOF
    cat >"$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$(pwd)" "$*" >>"$PNPM_LOG"
if [[ "$1" == install ]]; then
    [[ -z "${STUB_PNPM_INSTALL_FAIL:-}" ]]
else
    [[ -z "${STUB_PNPM_FAIL:-}" ]]
fi
EOF
    chmod +x "$STUBS/gh" "$STUBS/pnpm"
    export PATH="$STUBS:$PATH"
    # 偽の Rule Ledger の export。worktree の置き場に STUB_LEDGER_EXPORT 件の記録を書いて件数を出す。STUB_LEDGER_FAIL なら
    # 1 件だけ書いてから失敗する(写しかけの記録を残して失敗する export の再現)。STUB_LEDGER_TAMPER_RATES なら再発率の
    # スクリプトを書き換える(記録の commit の後、本文の推移の節の前に実行物が書き換えられた run の再現)
    cat >"$HOME/.claude/scripts/harness-rule-ledger.sh" <<'EOF'
#!/usr/bin/env bash
[[ -z "${STUB_LEDGER_TAMPER_RATES:-}" ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-failure-rates.sh"
worktree=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == --worktree ]] && worktree=$2
    shift
done
dir="$worktree/docs/harness/rule-ledger"
mkdir -p "$dir"
if [[ -n "${STUB_LEDGER_FAIL:-}" ]]; then
    printf '{"id":"partial"}\n' >"$dir/partial.json"
    exit 1
fi
for i in $(seq 1 "${STUB_LEDGER_EXPORT:-0}"); do
    printf '{"id":"pr30-%s"}\n' "$i" >"$dir/pr30-$i.json"
done
printf 'harness-rule-ledger: exported %s record(s)\n' "${STUB_LEDGER_EXPORT:-0}"
EOF
    # 偽の再発率のスクリプト。trend は推移の節を、detections は渡された日付を書いた失敗の検出の節を出す。
    # export は記録を選ばない。STUB_RATES_EXPORT(日付を空白で区切った列。既定はローカルの置き場にある全部)の
    # Weekly Rate Record をローカルの置き場から worktree の置き場に写し(--dry-run なら写さない)、件数の行を本物の CLI と
    # 同じ文言で出す(記録を選ぶ規則は test/harness-failure-rates.bats が本物の CLI で検査する)。STUB_RATES_EXPORT で
    # ローカルの件数と違う答えを返させると、module が CLI の答えで決めていることを確かめられる。
    # STUB_RATES_EXPORT_OUTPUT なら、何も写さずに件数の行の代わりにその文字列を出して成功する(CLI の文言が変わった run の再現)。
    # STUB_EXPORT_TAMPER_LEDGER なら、--dry-run でない export の後に Rule Ledger のスクリプトを
    # 書き換える(再発率の記録の commit の後、Rule Ledger の記録の commit の前に実行物が書き換えられた run の再現)。
    # STUB_RATES_TAMPER_LEDGER なら detections(Metrics-only PR の本文で最後に呼ばれる)の後に Rule Ledger のスクリプトを
    # 書き換える(本文を書いた後、push の前に実行物が書き換えられた run の再現)
    cat >"$HOME/.claude/scripts/harness-failure-rates.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
export)
    if [[ -n "${STUB_RATES_EXPORT_OUTPUT:-}" ]]; then
        printf '%s\n' "$STUB_RATES_EXPORT_OUTPUT"
        exit 0
    fi
    worktree="" dry_run="" count=0 rates="$HOME/.claude/harness/failure-pattern-rates"
    while [[ $# -gt 0 ]]; do
        [[ "$1" != --worktree ]] || worktree=$2
        [[ "$1" != --dry-run ]] || dry_run=1
        shift
    done
    shopt -s nullglob
    if [[ -n "${STUB_RATES_EXPORT:-}" ]]; then
        files=()
        for date in $STUB_RATES_EXPORT; do
            files+=("$rates/$date.json")
        done
    else
        files=("$rates"/*.json)
    fi
    for file in ${files[@]+"${files[@]}"}; do
        if [[ -z "$dry_run" ]]; then
            mkdir -p "$worktree/docs/harness/failure-pattern-rates"
            cp "$file" "$worktree/docs/harness/failure-pattern-rates/"
        fi
        count=$((count + 1))
    done
    if [[ -n "$dry_run" ]]; then
        printf 'harness-failure-rates: would export %s record(s)\n' "$count"
    else
        printf 'harness-failure-rates: exported %s record(s)\n' "$count"
        [[ -z "${STUB_EXPORT_TAMPER_LEDGER:-}" ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
    fi
    ;;
trend) printf '\n## 推移\n\n直近 4 週\n' ;;
detections)
    printf '\n## 失敗の検出\n\n%s の Weekly Rate Record の期間\n' "$2"
    [[ -z "${STUB_RATES_TAMPER_LEDGER:-}" ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
    ;;
*) exit 1 ;;
esac
EOF
    # 偽の Eval Case の評価。呼び出しと評価の予算を EVAL_LOG に、採用の印を EVAL_ENV_LOG に 1 行ずつ書く。run は --out に結果を
    # 書き(STUB_EVAL_NO_OUT なら書かない)、STUB_EVAL_FAIL なら書かずに、STUB_EVAL_FAIL_AFTER_WRITE なら書いてから失敗する。
    # STUB_EVAL_TAMPER のファイルがあれば中身を書き換える(選別の工程の照合の後に記録が書き換えられた run の再現)。
    # section は採用の見出しを並べた効果の節を出す
    cat >"$HOME/.claude/scripts/harness-eval-cases.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s budget=%s\n' "$*" "${HARNESS_EVAL_BUDGET_USD:-}" >>"$EVAL_LOG"
printf 'HARNESS_REVIEW_RUN=%s\n' "${HARNESS_REVIEW_RUN-<unset>}" >>"$EVAL_ENV_LOG"
[[ -z "${STUB_EVAL_TAMPER:-}" ]] || printf '{"tampered":true}\n' >"$STUB_EVAL_TAMPER"
command=$1 out="" adopted=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == --out ]] && out=$2
    [[ "$1" == --adopted ]] && adopted=$2
    shift
done
[[ -z "${STUB_EVAL_FAIL:-}" ]] || exit 1
if [[ "$command" == run ]]; then
    [[ -n "${STUB_EVAL_NO_OUT:-}" ]] || printf '{"cases":[]}\n' >"$out"
    [[ -z "${STUB_EVAL_FAIL_AFTER_WRITE:-}" ]] || exit 1
    exit 0
fi
printf '\n## ルールの効果\n\n評価した採用: %s' "$(paste -sd, "$adopted")"
EOF
}

# <日付>: ローカルに週の記録を置く
local_record() {
    printf '{"date":"%s"}\n' "$1" >"$RATES/$1.json"
}

# スナップショットを取ってから、実際のパスと既定と違う Loop PR の prefix で初期化する
init_real() {
    harness_integrity_snapshot
    harness_loop_pr_init --repo "$REPO" --worktree "$WT" --branch "$BRANCH" --loop-branch-prefix test/loop- \
        --pr-body "$BODY" --review-result "$RESULT" --eval-requests "$EVAL_REQUESTS" --eval-results "$EVAL_RESULTS" \
        --eval-budget-usd 1.5 --date 2026-10-17 --run "$BRANCH run 0f0e"
}

four_local_records() {
    local_record 2026-09-26
    local_record 2026-10-03
    local_record 2026-10-10
    local_record 2026-10-17
}

# Metrics-only PR の本文の先頭の行(件数の文)。件数は記録の commit の後にしか決まらない
metrics_only_counts() { # <週の再発率の記録の件数>
    printf '採用した変更は無い。origin/main に無い週の Failure Pattern の再発率の記録が %s 週分たまったので、記録だけを commit した。' "$1"
}

# 公開しない(PR を作らず origin にもブランチを出さない)ことを確かめる
refute_published() {
    refute_pr_create
    run git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_failure
}

# gh pr create を呼んでいない(gh を一度も呼んでいなければ GH_LOG は無い)
refute_pr_create() {
    [[ ! -e "$GH_LOG" ]] || refute grep -q '^pr create' "$GH_LOG"
}

# 公開しないで片付けたこと(worktree・本文・結果ファイルを消し、ローカルブランチは残す)を確かめる
assert_discarded() {
    refute_published
    assert [ ! -e "$WT" ]
    assert [ ! -e "$BODY" ]
    assert [ ! -e "$RESULT" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
}

# pnpm を除いた PATH(git と jq と偽の gh だけを置いたディレクトリと、システムのディレクトリ)
path_without_pnpm() {
    local dir="$BATS_TEST_TMPDIR/no-pnpm" git_bin jq_bin
    git_bin=$(command -v git) || return 1
    jq_bin=$(command -v jq) || return 1
    mkdir -p "$dir"
    ln -sf "$git_bin" "$dir/git"
    ln -sf "$jq_bin" "$dir/jq"
    ln -sf "$STUBS/gh" "$dir/gh"
    printf '%s\n' "$dir:/usr/bin:/bin"
}

# 当日のブランチに origin/main に無い commit を 1 つ持たせる(push か PR の作成に失敗した前の run が残したブランチ)
unpushed_branch() {
    git -C "$REPO" branch "$BRANCH" main
    git -C "$REPO" worktree add -q "$BATS_TEST_TMPDIR/other" "$BRANCH"
    git -C "$BATS_TEST_TMPDIR/other" commit -q --allow-empty -m 'unpushed'
    git -C "$REPO" worktree remove "$BATS_TEST_TMPDIR/other"
}

@test "選別を省いた週: 初期化で受け取った prefix のブランチの PR が開いていれば、その URL を出して worktree を作らずに成功する" {
    publish_fixture
    four_local_records
    init_real
    STUB_GH_OPEN_PRS='[{"headRefName":"feature/x","url":"https://github.com/example/dotfiles/pull/39"},{"headRefName":"test/loop-2026-10-10","url":"https://github.com/example/dotfiles/pull/40"}]' \
        run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_output 'harness-weekly: loop PR https://github.com/example/dotfiles/pull/40 is open; weekly failure rate records carried over'
    assert [ ! -e "$WT" ]
    refute_published
}

@test "選別を省いた週: 開いている PR のブランチが prefix で始まらなければ Loop PR と数えず、Metrics-only PR を作る" {
    publish_fixture
    four_local_records
    init_real
    STUB_GH_OPEN_PRS='[{"headRefName":"harness/review-2026-10-10","url":"https://github.com/example/dotfiles/pull/40"},{"headRefName":"feature/test/loop-x","url":"https://github.com/example/dotfiles/pull/41"}]' \
        run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_line 'harness-weekly: opened metrics-only draft PR https://github.com/example/dotfiles/pull/42 (4 weekly record(s))'
}

@test "選別を省いた週: 開いている PR を調べられなければ WARN を出して worktree を作らずに成功する" {
    publish_fixture
    four_local_records
    init_real
    STUB_GH_LIST_FAIL=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_output 'harness-weekly: WARN listing open loop PRs failed; no metrics-only PR this week'
    assert [ ! -e "$WT" ]
}

@test "選別を省いた週: 当日のブランチが origin にあれば worktree を作らずに成功し、照会に失敗したら WARN を出して成功する" {
    publish_fixture
    four_local_records
    init_real
    git -C "$REPO" push -q origin "main:refs/heads/$BRANCH"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_output ''
    assert [ ! -e "$WT" ]
    refute_pr_create
    git -C "$REPO" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_line --regexp "^harness-weekly: WARN failed to query origin for ${BRANCH} \(git ls-remote exit [0-9]+\); no metrics-only PR this week$"
    assert [ ! -e "$WT" ]
}

@test "選別を省いた週: pnpm が PATH に無ければ、原因を名指しして worktree を作らずに失敗する" {
    publish_fixture
    four_local_records
    init_real
    local path
    path=$(path_without_pnpm)
    if PATH="$path" command -v pnpm >/dev/null 2>&1; then
        skip 'pnpm exists in the system directories on this machine'
    fi
    PATH="$path" run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_output "harness-weekly: pnpm not found on PATH (${path}); add the directory that holds it (e.g. ~/.local/share/mise/shims) to PATH in the launchd plist; no metrics-only PR"
    assert [ ! -e "$WT" ]
}

@test "選別を省いた週: origin/main に無い commit を持つ当日のローカルブランチは作り直さずに失敗する" {
    publish_fixture
    four_local_records
    unpushed_branch
    init_real
    run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_output "$(printf '%s\n' \
        "harness-weekly: local branch ${BRANCH} in ${REPO} has 1 commit(s) not on origin/main; push / open the PR by hand (PR body ${BODY}, if present) or delete the branch, then rerun" \
        "harness-weekly: failed to prepare the worktree ${WT} for a metrics-only PR")"
    run git -C "$REPO" log --format=%s -1 "$BRANCH"
    assert_output unpushed
    assert [ ! -e "$PNPM_LOG" ]
}

@test "選別を省いた週: 再発率の CLI が数えた origin/main に無い記録が 4 週分に満たなければ、件数を出し、依存を入れずに片付けて成功する" {
    publish_fixture
    # ローカルには 4 週分あるが、CLI は 3 件と答える(1 件は origin/main にある)
    four_local_records
    init_real
    printf 'body of the previous run\n' >"$BODY"
    printf '{}\n' >"$RESULT"
    STUB_RATES_EXPORT='2026-10-03 2026-10-10 2026-10-17' run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_output "harness-weekly: 3 weekly failure rate record(s) not on origin/main; carried over in $RATES (a metrics-only PR needs 4)"
    assert [ ! -e "$PNPM_LOG" ]
    assert_discarded
}

@test "選別を省いた週: 再発率の CLI の出力から件数の行を読めなければ、受け取った出力と WARN を出し、PR を作らずに片付けて成功する" {
    publish_fixture
    four_local_records
    init_real
    STUB_RATES_EXPORT_OUTPUT='harness-failure-rates: counted 4 record(s)' run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_line "harness-weekly: unexpected output from $HOME/.claude/scripts/harness-failure-rates.sh export: harness-failure-rates: counted 4 record(s)"
    assert_line 'harness-weekly: WARN counting the weekly failure rate records not on origin/main failed; no metrics-only PR this week'
    assert [ ! -e "$PNPM_LOG" ]
    assert_discarded
}

@test "選別を省いた週: 要ると決まったら、worktree に依存を入れてから記録を整形して Metrics-only PR を作る。前の run の本文と結果ファイルは使わない" {
    publish_fixture
    four_local_records
    init_real
    printf 'body of the previous run\n' >"$BODY"
    printf '{}\n' >"$RESULT"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_line 'harness-weekly: opened metrics-only draft PR https://github.com/example/dotfiles/pull/42 (4 weekly record(s))'
    run cat "$PNPM_LOG"
    assert_output "$(printf '%s\n' "$WT install --frozen-lockfile --prefer-offline" "$WT exec oxfmt docs/harness/failure-pattern-rates")"
    run cat "$GH_BODY"
    refute_output --partial 'body of the previous run'
    assert [ ! -e "$RESULT" ]
}

@test "選別を省いた週: 依存のインストールが失敗したら、PR を作らずに失敗する。前の run の結果ファイルは残さない" {
    publish_fixture
    four_local_records
    init_real
    printf '{}\n' >"$RESULT"
    STUB_PNPM_INSTALL_FAIL=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_output "harness-weekly: pnpm install failed in ${WT}; no metrics-only PR"
    refute_published
    assert [ ! -e "$RESULT" ]
}

@test "Metrics-only PR: 記録を commit して push し、commit した件数を書いた本文で draft PR を作って片付ける" {
    publish_fixture
    four_local_records
    local_record 2026-09-19
    init_real
    # ローカルには 5 週分あるが、module は CLI が書き出した 4 件(STUB_RATES_EXPORT)を commit する
    STUB_RATES_EXPORT='2026-09-19 2026-10-03 2026-10-10 2026-10-17' run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_line 'harness-weekly: opened metrics-only draft PR https://github.com/example/dotfiles/pull/42 (4 weekly record(s))'
    run grep '^pr create' "$GH_LOG"
    assert_output "pr create --draft --base main --head ${BRANCH} --title harness: 週次の指標 2026-10-17 --body-file ${BODY}"
    run cat "$GH_BODY"
    assert_line --index 0 "$(metrics_only_counts 4)"
    assert_line '## 推移'
    assert_line '## 失敗の検出'
    assert_line '2026-10-17 の Weekly Rate Record の期間'
    refute_output --partial 'Rule Ledger'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: Failure Pattern の再発率の週の記録を足す'
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH"
    assert_output "$(printf 'docs/harness/failure-pattern-rates/%s.json\n' 2026-09-19 2026-10-03 2026-10-10 2026-10-17)"
    assert [ ! -e "$WT" ]
    assert [ ! -e "$BODY" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_failure
}

@test "記録の commit は、GIT_CONFIG_GLOBAL が無ければ Claude Code の git の設定(~/.config/git/claude-code.inc)で作る" {
    publish_fixture
    four_local_records
    init_real
    mkdir -p "$HOME/.config/git"
    printf '[user]\n\tname = claude-code-agent\n\temail = agent@example.com\n[commit]\n\tgpgsign = false\n' \
        >"$HOME/.config/git/claude-code.inc"
    unset GIT_CONFIG_GLOBAL
    run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    run git -C "$ORIGIN" log --format=%an "main..$BRANCH"
    assert_output claude-code-agent
}

@test "Metrics-only PR: 持ち越した Rule Ledger の記録を PR を作る前に commit し、その件数と置き場も本文に書く" {
    publish_fixture
    four_local_records
    init_real
    STUB_LEDGER_EXPORT=2 run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Rule Ledger の記録を足す' 'harness: Failure Pattern の再発率の週の記録を足す')"
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output "$(printf 'docs/harness/rule-ledger/%s.json\n' pr30-1 pr30-2)"
    run cat "$GH_BODY"
    assert_line --index 0 "$(metrics_only_counts 4)"
    assert_line 'マージ済みの PR の Rule Ledger の記録のうち、まだ載っていなかった 2 件も足した(docs/harness/rule-ledger)。'
}

@test "Metrics-only PR: 再発率の記録を commit できなければ、PR を作らずに失敗する" {
    publish_fixture
    four_local_records
    init_real
    STUB_PNPM_FAIL=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_line "harness-weekly: failed to commit the weekly failure rate records in ${WT}; no PR created"
    refute_published
}

@test "Metrics-only PR: スナップショットの後に週の記録が書き換えられていたら、commit も PR もせずに失敗し、予約コードを外に出さない" {
    publish_fixture
    four_local_records
    init_real
    printf '{"tampered":true}\n' >"$RATES/2026-10-10.json"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_output --partial "changed: $RATES/2026-10-10.json"
    assert_line "harness-weekly: no PR created; check ${RATES} by hand"
    refute_output --partial 'failed to commit the weekly failure rate records'
    run git -C "$WT" rev-list --count "origin/main..HEAD"
    assert_output 0
    refute_published
}

@test "Metrics-only PR: Rule Ledger のスクリプトが書き換えられていたら、Rule Ledger を信頼できないとして PR を作らずに失敗する" {
    publish_fixture
    four_local_records
    init_real
    STUB_EXPORT_TAMPER_LEDGER=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_line 'harness-weekly: the Rule Ledger records could not be trusted; no PR created'
    refute_published
}

@test "Metrics-only PR: 要否を数える前に実行物が書き換えられていたら、記録を commit せず PR も作らずに失敗し、予約コードを外に出さない" {
    publish_fixture
    four_local_records
    init_real
    printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-rule-ledger.sh"
    assert_line 'harness-weekly: no metrics-only PR; the scripts the job runs could not be trusted when counting the weekly failure rate records'
    refute_output --partial 'opened metrics-only'
    refute_published
    run git -C "$WT" log --format=%s "main..HEAD"
    assert_output ''
}

@test "Metrics-only PR: 要否を数えた後、記録の書き出しの前に実行物が書き換えられたら、記録ではなく実行物を見るよう案内し、記録を commit せず PR も作らずに失敗する" {
    publish_fixture
    four_local_records
    init_real
    # 依存のインストール(要否の判定の後、記録の commit の前)の最中に実行物を書き換える
    cat >"$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
[[ "$1" != install ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
EOF
    run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-rule-ledger.sh"
    assert_line 'harness-weekly: no PR created; the scripts the job runs could not be trusted when exporting the weekly failure rate records'
    refute_output --partial "check ${RATES} by hand"
    refute_output --partial 'failed to commit the weekly failure rate records'
    refute_published
    run git -C "$WT" log --format=%s "main..HEAD"
    assert_output ''
    run git -C "$WT" status --porcelain --untracked-files=all
    assert_output ''
}

@test "Metrics-only PR: Rule Ledger の記録を commit できなければ、写しかけを戻して Metrics-only PR を作る" {
    publish_fixture
    four_local_records
    init_real
    STUB_LEDGER_FAIL=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_success
    assert_line "harness-weekly: WARN failed to commit the Rule Ledger records; they stay in $HDIR/rule-ledger for a later PR"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: Failure Pattern の再発率の週の記録を足す'
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output ''
    run cat "$GH_BODY"
    assert_line --index 0 "$(metrics_only_counts 4)"
    refute_output --partial 'Rule Ledger'
}

@test "Metrics-only PR: 本文を書けなければ、push も PR の作成もせずに失敗する" {
    publish_fixture
    four_local_records
    init_real
    # 本文のパスにディレクトリを置いて書けなくする
    mkdir -p "$BODY"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_line "harness-weekly: failed to write the record counts to ${BODY}; no PR created"
    refute_published
}

@test "Metrics-only PR: 記録の commit の後に再発率のスクリプトが書き換えられたら、予約コードを外に出さずに PR を作らずに失敗する" {
    publish_fixture
    four_local_records
    init_real
    STUB_LEDGER_TAMPER_RATES=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-failure-rates.sh"
    assert_line 'harness-weekly: no PR created; the failure rate trend could not be trusted'
    refute_published
}

@test "Metrics-only PR: 本文を書いた後に実行物が書き換えられたら、push の直前の関門で止まる" {
    publish_fixture
    four_local_records
    init_real
    STUB_RATES_TAMPER_LEDGER=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_line "harness-weekly: stopped before push on ${BRANCH}; no PR created, because the scripts the job runs could not be trusted"
    refute_published
}

@test "Metrics-only PR: push の後に実行物が書き換えられたら、PR の作成の直前の関門で止まり、ブランチを消すよう案内する" {
    publish_fixture
    four_local_records
    init_real
    # push を受けた origin のフックが実行物を書き換える
    printf '#!/usr/bin/env bash\nprintf "# tampered\\n" >>"%s"\n' "$HOME/.claude/scripts/harness-rule-ledger.sh" >"$ORIGIN/hooks/post-receive"
    chmod +x "$ORIGIN/hooks/post-receive"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_line "harness-weekly: stopped before gh pr create on ${BRANCH}; no PR created, because the scripts the job runs could not be trusted"
    assert_line "harness-weekly: ${BRANCH} is already on origin; do not open a PR from it as it is. Find what changed the scripts, then delete the branch (git push origin --delete ${BRANCH})"
    refute_pr_create
    run git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
}

@test "Metrics-only PR: push に失敗したら、手で公開するコマンドを出して失敗し、worktree・ローカルブランチ・本文を残す" {
    publish_fixture
    four_local_records
    init_real
    printf '#!/usr/bin/env bash\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
    chmod +x "$ORIGIN/hooks/pre-receive"
    run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_line "harness-weekly: push of ${BRANCH} failed; no PR created. To publish by hand: git -C ${REPO} push origin ${BRANCH}, then gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}"
    refute_published
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
    run git -C "$REPO" rev-list --count "origin/main..refs/heads/$BRANCH"
    assert_output 1
}

@test "Metrics-only PR: PR の作成に失敗したら、手で PR を作るコマンドを出して失敗し、worktree・ローカルブランチ・本文を残す" {
    publish_fixture
    four_local_records
    init_real
    STUB_GH_FAIL=1 run harness_loop_pr_publish_metrics_only_if_due
    assert_failure 1
    assert_line "harness-weekly: pushed ${BRANCH} but gh pr create failed; open the PR by hand with gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}"
    run git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
}

# review_fixture は選別の経路の入口(harness_loop_pr_run_review)の検査の fixture。publish_fixture に判定の記録と Rule Ledger の
# record を足す。Verdict の CLI は本物を置き(判定の記録の書き換えを検査に残す)、Rule Ledger の record は偽物にする
# (記録の作り方は test/harness-rule-ledger.bats の範囲)。
#
# 偽の Rule Ledger の record:
# - STUB_LEDGER_RECORD の id ごとにローカルの記録を書いて「recorded <id>」を出す。STUB_LEDGER_RECORD_FAIL なら何も書かずに失敗する
# - 受け取った引数を LEDGER_LOG に 1 行で書く(export も同じ)
review_fixture() {
    publish_fixture
    export LEDGER_LOG="$BATS_TEST_TMPDIR/ledger.log"
    unset STUB_LEDGER_RECORD STUB_LEDGER_RECORD_FAIL STUB_GH_TAMPER
    cp "$REPO_ROOT/dot_claude/scripts/executable_harness-verdict.sh" "$HOME/.claude/scripts/harness-verdict.sh"
    cat >"$HOME/.claude/scripts/harness-rule-ledger.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$LEDGER_LOG"
if [[ "$1" == record ]]; then
    [[ -z "${STUB_LEDGER_RECORD_FAIL:-}" ]] || exit 1
    mkdir -p "$HOME/.claude/harness/rule-ledger"
    for id in ${STUB_LEDGER_RECORD:-}; do
        printf '{"id":"%s"}\n' "$id" >"$HOME/.claude/harness/rule-ledger/$id.json"
        printf 'harness-rule-ledger: recorded %s\n' "$id"
    done
    exit 0
fi
worktree=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == --worktree ]] && worktree=$2
    shift
done
dir="$worktree/docs/harness/rule-ledger"
mkdir -p "$dir"
if [[ -n "${STUB_LEDGER_FAIL:-}" ]]; then
    printf '{"id":"partial"}\n' >"$dir/partial.json"
    exit 1
fi
for i in $(seq 1 "${STUB_LEDGER_EXPORT:-0}"); do
    printf '{"id":"pr42-%s"}\n' "$i" >"$dir/pr42-$i.json"
done
printf 'harness-rule-ledger: exported %s record(s)\n' "${STUB_LEDGER_EXPORT:-0}"
EOF
    # PR を作った直後に、STUB_GH_TAMPER のファイルに 1 行足す(PR を作った後に書き換えられた run の再現)
    cat >"$STUBS/gh-tamper" <<'EOF'
[[ "$1 $2" != 'pr create' || -z "${STUB_GH_TAMPER:-}" || -n "${STUB_GH_FAIL:-}" ]] || printf '# tampered\n' >>"$STUB_GH_TAMPER"
EOF
    sed -i.bak '1r '"$STUBS/gh-tamper" "$STUBS/gh"
    # この run の採用が 1 件ある判定の記録
    printf -- '## [2026-10-03] entry\n\n- **Verdict:** adopted (%s run 0f0e)\n' "$BRANCH" >"$HDIR/queue-archive.md"
}

# 選別の経路の入口に渡す開始の行
START_LINE='harness-weekly: review session=s1 queue=1 branch=test/loop-2026-10-17'

# 入口に開始の行と <コマンド> を渡す
review_with() { # <コマンド> [<引数>…]
    harness_loop_pr_run_review "$START_LINE" "$@"
}

# 選別の claude の代わり。cwd に採用の commit を 1 つ作り、本文と結果ファイルを書く。呼ばれたときの cwd・採用の印・
# 本文と結果ファイルの有無を REVIEW_LOG に 1 行で書く(パスは相対で書くので、cwd が worktree でなければ commit できない)
review_commits() {
    printf '%s HARNESS_REVIEW_RUN=%s body=%s result=%s\n' "$(pwd)" "${HARNESS_REVIEW_RUN-<unset>}" \
        "$([[ -e "$BODY" ]] && echo present || echo absent)" "$([[ -e "$RESULT" ]] && echo present || echo absent)" >>"$REVIEW_LOG"
    printf 'rule\n' >rule.md
    git add rule.md
    git commit -qm 'harness: add rule'
    printf '本文\n' >"$BODY"
    printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
}

# 選別の claude の代わり。commit せずに本文と結果ファイルだけを書き、判定の記録を却下にする(採用も陳腐化の修正も無い週)
review_no_commits() {
    printf '%s\n' "$(pwd)" >>"$REVIEW_LOG"
    printf -- '## [2026-10-03] entry\n\n- **Verdict:** rejected (stub)\n' >"$HDIR/queue-archive.md"
    printf 'reason\n' >"$BODY"
    printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
}

# <コマンド> を走らせてから、選別の claude が失敗したとして 1 を返す
then_fail() { # <コマンド> [<引数>…]
    "$@"
    return 1
}

# <パス> のファイルを書き換えてから <コマンド> を走らせる(選別の claude がスクリプトか記録を書き換える run)
rewriting() { # <パス> <コマンド> [<引数>…]
    local path=$1
    shift
    printf '{"tampered":true}\n' >>"$path"
    "$@"
}

# 公開も評価もしていないことを確かめる(評価の工程は公開する選別の結果にだけ走る)
refute_evaluated() {
    assert [ ! -e "$EVAL_LOG" ]
}

# 選別の claude を走らせていないことを確かめる
refute_reviewed() {
    assert [ ! -e "$REVIEW_LOG" ]
}

@test "選別の経路: 開始の行を出し、origin/main から切った worktree に依存を入れてから、その中で採用の印を渡して選別を走らせ、commit を PR にする" {
    review_fixture
    # 手元の未 push の commit は PR に入らない
    git -C "$REPO" commit -q --allow-empty -m 'local only'
    init_real
    run review_with review_commits
    assert_success
    assert_line --index 0 "$START_LINE"
    refute_output --partial 'but the review committed nothing'
    run cat "$REVIEW_LOG"
    assert_output "$WT HARNESS_REVIEW_RUN=${BRANCH} run 0f0e body=absent result=absent"
    run cat "$PNPM_LOG"
    assert_line --index 0 "$WT install --frozen-lockfile --prefer-offline"
    run grep -c '^pr create' "$GH_LOG"
    assert_output 1
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
    # 評価には採用の印を渡さない
    run cat "$EVAL_ENV_LOG"
    assert_line --index 0 'HARNESS_REVIEW_RUN=<unset>'
}

@test "選別の経路: 当日のブランチが origin にあり PR もあれば、開始の行も出さず選別も走らせずに成功する" {
    review_fixture
    init_real
    git -C "$REPO" push -q origin "main:refs/heads/$BRANCH"
    STUB_GH_HEAD_PRS='[{"url":"https://github.com/example/dotfiles/pull/41"}]' run review_with review_commits
    assert_success
    assert_output "harness-weekly: ${BRANCH} already exists on origin (PR https://github.com/example/dotfiles/pull/41); skipped review"
    run grep '^pr list' "$GH_LOG"
    assert_output "pr list --head ${BRANCH} --state all --json url --jq .[0].url // empty"
    refute_reviewed
    refute_pr_create
    assert [ ! -e "$WT" ]
}

@test "選別の経路: 当日のブランチが origin にあっても PR が無ければ、選別を走らせずに手で PR を作る手順を出して失敗する" {
    review_fixture
    init_real
    git -C "$REPO" push -q origin "main:refs/heads/$BRANCH"
    run review_with review_commits
    assert_failure 1
    assert_output "harness-weekly: ${BRANCH} exists on origin but has no PR; skipped review. Check the log of the run that pushed it: if it stopped before gh pr create because the scripts could not be trusted, delete the branch (git push origin --delete ${BRANCH}); otherwise open the PR by hand (gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY})"
    refute_reviewed
    STUB_GH_HEAD_LIST_FAIL=1 run review_with review_commits
    assert_failure 1
    assert_output "harness-weekly: ${BRANCH} exists on origin but listing its PR failed; skipped review"
    refute_reviewed
}

@test "選別の経路: 当日のブランチを origin に照会できなければ、選別を走らせずに失敗する" {
    review_fixture
    init_real
    git -C "$REPO" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
    run review_with review_commits
    assert_failure 1
    assert_line --regexp "^harness-weekly: failed to query origin for ${BRANCH} \(git ls-remote exit [0-9]+\)$"
    refute_reviewed
}

@test "選別の経路: pnpm が PATH に無ければ、原因を名指しし、開始の行を出さず選別も走らせずに失敗する" {
    review_fixture
    init_real
    local path
    path=$(path_without_pnpm)
    if PATH="$path" command -v pnpm >/dev/null 2>&1; then
        skip 'pnpm exists in the system directories on this machine'
    fi
    PATH="$path" run review_with review_commits
    assert_failure 1
    assert_output "harness-weekly: pnpm not found on PATH (${path}); add the directory that holds it (e.g. ~/.local/share/mise/shims) to PATH in the launchd plist; skipped review"
    refute_reviewed
    assert [ ! -e "$WT" ]
}

@test "選別の経路: 依存のインストールが失敗したら、選別を走らせずに失敗する" {
    review_fixture
    init_real
    STUB_PNPM_INSTALL_FAIL=1 run review_with review_commits
    assert_failure 1
    assert_output "$(printf '%s\n' "$START_LINE" "harness-weekly: pnpm install failed in ${WT}; skipped review")"
    refute_reviewed
}

@test "選別の経路: origin/main に無い commit を持つ当日のローカルブランチは作り直さず、手で使う本文も消さずに失敗する" {
    review_fixture
    unpushed_branch
    init_real
    printf 'body of the run that failed to push\n' >"$BODY"
    run review_with review_commits
    assert_failure 1
    assert_output "$(printf '%s\n' "$START_LINE" \
        "harness-weekly: local branch ${BRANCH} in ${REPO} has 1 commit(s) not on origin/main; push / open the PR by hand (PR body ${BODY}, if present) or delete the branch, then rerun" \
        "harness-weekly: failed to prepare the review worktree ${WT}")"
    run git -C "$REPO" log --format=%s -1 "$BRANCH"
    assert_output unpushed
    run cat "$BODY"
    assert_output 'body of the run that failed to push'
    assert [ ! -e "$WT.new" ]
    refute_reviewed
}

@test "選別の経路: 当日のブランチが別の worktree で checkout されていると、その旨を添えて失敗する" {
    review_fixture
    git -C "$REPO" worktree add -q -b "$BRANCH" "$BATS_TEST_TMPDIR/other" main
    init_real
    run review_with review_commits
    assert_failure 1
    assert_line "harness-weekly: could not reset branch ${BRANCH} (is it checked out in another worktree of ${REPO}?)"
    assert_line "harness-weekly: failed to prepare the review worktree ${WT}"
    refute_reviewed
}

@test "選別の経路: 止まった実行が残した worktree があっても、作り直して PR まで進む" {
    review_fixture
    git -C "$REPO" worktree add -q --detach "$WT" HEAD
    printf 'leftover\n' >"$WT/leftover.md"
    init_real
    run review_with review_commits
    assert_success
    run git -C "$ORIGIN" ls-tree -r --name-only "$BRANCH"
    assert_output "$(printf '%s\n' README.md rule.md)"
}

@test "選別の経路: worktree の登録だけが残っていても PR まで進む" {
    review_fixture
    git -C "$REPO" worktree add -q --detach "$WT" HEAD
    rm -rf "$WT"
    init_real
    run review_with review_commits
    assert_success
    run grep -c '^pr create' "$GH_LOG"
    assert_output 1
}

@test "選別の経路: gitdir を stat できない他の linked worktree の登録を消さない(nono の内側の状況)" {
    [[ "$(id -u)" -ne 0 ]] || skip 'root は権限に関係なく stat できるので状況を作れない'
    review_fixture
    local locked="$BATS_TEST_TMPDIR/workspaces"
    mkdir -p "$locked"
    git -C "$REPO" worktree add -q --detach "$locked/other" HEAD
    chmod 000 "$locked"
    init_real
    run review_with review_commits
    chmod 755 "$locked"
    assert_success
    assert [ -d "$REPO/.git/worktrees/other" ]
}

@test "選別の経路: push に失敗した run の後に同じ日に再実行しても、手で PR を作るための本文と worktree を消さない" {
    review_fixture
    init_real
    cat >"$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
exit 1
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
    run review_with review_commits
    assert_failure 1
    assert_line "harness-weekly: push of ${BRANCH} failed; no PR created. To publish by hand: git -C ${REPO} push origin ${BRANCH}, then gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}"
    rm -f "$ORIGIN/hooks/pre-receive" "$REVIEW_LOG"
    run review_with review_commits
    assert_failure 1
    assert_line --partial "harness-weekly: local branch ${BRANCH} in ${REPO} has 1 commit(s) not on origin/main"
    refute_reviewed
    run cat "$BODY"
    assert_line '## 純増'
    run git -C "$WT" log --format=%s
    assert_line 'harness: add rule'
    assert [ ! -e "$WT.new" ]
}

@test "選別の経路: 選別の前に、同じ日の前の run が残した本文・結果ファイル・Eval Case の依頼と結果を消す" {
    review_fixture
    init_real
    local file
    for file in "$BODY" "$RESULT" "$EVAL_REQUESTS" "$EVAL_RESULTS"; do
        printf 'previous\n' >"$file"
    done
    run review_with review_commits
    assert_success
    # 選別が依頼を書かなかったことになり、空の依頼で評価する(前の run の依頼を使わない)
    assert_line "harness-weekly: review wrote no eval requests ${EVAL_REQUESTS}; the PR body lists every adopted rule as unevaluated"
    run cat "$REVIEW_LOG"
    assert_output --partial ' body=absent result=absent'
    run cat "$EVAL_REQUESTS"
    assert_output '{"cases": []}'
    run cat "$GH_BODY"
    refute_output --partial previous
}

# 選別の claude の代わり。採用の commit に加えて、TOUCH_DIR(リポジトリ内のパス)にファイルを置いて commit する
review_touching_records() {
    review_commits
    mkdir -p "$TOUCH_DIR"
    printf '{}\n' >"$TOUCH_DIR/x.json"
    git add -A
    git commit -qm "harness: touch $TOUCH_DIR"
}

@test "選別の結果: 選別の commit がこのジョブの記録の置き場に触れたら、評価も PR の作成もせずに失敗する" {
    review_fixture
    init_real
    local dir
    for dir in docs/harness/failure-pattern-rates docs/harness/rule-ledger; do
        rm -rf "$EVAL_LOG"
        git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
        git -C "$REPO" branch -q -D "$BRANCH" 2>/dev/null || true
        TOUCH_DIR=$dir run review_with review_touching_records
        assert_failure 1
        assert_line "harness-weekly: review commits touched $dir (only this job writes $([[ $dir == *rates ]] && echo 'the weekly failure rate records' || echo 'the Rule Ledger')); no PR created"
        refute_published
        refute_evaluated
        assert [ -d "$WT" ]
        assert [ -s "$BODY" ]
    done
}

@test "選別の結果: 記録を commit して push し、評価の節を足した本文で draft PR を作って判定の記録を PR の URL に置き換え、片付ける" {
    review_fixture
    local_record 2026-10-10
    init_real
    # 選別の claude が Eval Case の依頼を書く
    write_eval_requests() {
        printf '{"cases":[]}\n' >"$EVAL_REQUESTS"
        review_commits
    }
    run review_with write_eval_requests
    assert_success
    assert_line 'harness-weekly: committed 1 weekly failure rate record(s)'
    # commit の件数は選別の commit だけを数える
    assert_line 'harness-weekly: opened draft PR https://github.com/example/dotfiles/pull/42 (1 commit(s))'
    assert_line 'harness-weekly: recorded the PR URL on 1 verdict(s)'
    refute_output --partial 'eval requests'
    run grep '^pr create' "$GH_LOG"
    assert_output "pr create --draft --base main --head ${BRANCH} --title harness: 週次レビュー 2026-10-17 --body-file ${BODY}"
    # 評価は初期化で受け取った依頼・日付・予算で走り、この run の採用の見出しで節を作る
    run cat "$EVAL_LOG"
    assert_line --index 0 "run --requests ${EVAL_REQUESTS} --date 2026-10-17 --out ${EVAL_RESULTS} budget=1.5"
    assert_line --index 1 --regexp "^section --results ${EVAL_RESULTS} --adopted .* budget=$"
    # 選別が書いた本文の後ろに、評価の節を含む節が足される(節の順序と中身は test/harness-pr-body.bats の範囲)
    run cat "$GH_BODY"
    assert_line --index 0 '本文'
    assert_line '## ルールの効果'
    assert_line '評価した採用: [2026-10-03] entry'
    assert_line '## 純増'
    assert_line '## Rule Ledger'
    # 封印した評価の結果を Rule Ledger の記録に渡す
    run grep '^record ' "$LEDGER_LOG"
    assert_output "record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly --results ${EVAL_RESULTS}"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Failure Pattern の再発率の週の記録を足す' 'harness: add rule')"
    run grep -c 'adopted (PR https://github.com/example/dotfiles/pull/42)' "$HDIR/queue-archive.md"
    assert_output 1
    assert [ ! -e "$WT" ]
    assert [ ! -e "$BODY" ]
    assert [ ! -e "$RESULT" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_failure
}

# 選別の claude の代わり。新しいファイル(3 行)と README.md の 1 行の書き換えを 1 つの commit にする
review_commits_lines() {
    printf 'a\nb\nc\n' >new.md
    printf 'keep\n' >README.md
    git add -A
    git commit -qm 'harness: add rule'
    printf '本文\n' >"$BODY"
    printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
}

@test "選別の結果: 本文の純増は、選別の commit だけを数える(ジョブが足す記録の commit を数えない)" {
    review_fixture
    local_record 2026-10-10
    init_real
    run review_with review_commits_lines
    assert_success
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_line 'harness: Failure Pattern の再発率の週の記録を足す'
    run cat "$GH_BODY"
    assert_line '合計: +4 / -1(純増 +3 行)'
}

@test "選別の結果: origin/main に無い週の記録が無ければ、記録の commit を作らずに PR を作る" {
    review_fixture
    init_real
    run review_with review_commits
    assert_success
    refute_output --partial 'weekly failure rate record(s)'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
}

@test "選別の結果: 選別の工程の照合の後に週の記録が書き換えられていたら、WARN で続けずに PR を作らずに失敗し、予約コードを外に出さない" {
    review_fixture
    local_record 2026-10-10
    init_real
    # 評価の工程(選別の工程の照合の後、記録の commit の前)の最中に週の記録を書き換える
    STUB_EVAL_TAMPER="$RATES/2026-10-10.json" run review_with review_commits
    assert_failure 1
    assert_output --partial "changed: $RATES/2026-10-10.json"
    assert_line "harness-weekly: no PR created; check ${RATES} by hand"
    refute_output --partial 'WARN'
    refute_published
    run grep -c "adopted (${BRANCH} run 0f0e)" "$HDIR/queue-archive.md"
    assert_output 1
}

@test "選別の結果: 週の記録をほかの理由で commit できなければ、WARN を出し、写しかけを戻して PR を作る" {
    review_fixture
    local_record 2026-10-10
    init_real
    # 週の記録を含む commit だけを拒む commit フック。写しかけを戻さないと、後の Rule Ledger の commit も拒まれる
    printf '#!/usr/bin/env bash\n! git diff --cached --name-only | grep -q "^docs/harness/failure-pattern-rates/"\n' >"$REPO/.git/hooks/pre-commit"
    chmod +x "$REPO/.git/hooks/pre-commit"
    STUB_LEDGER_EXPORT=1 run review_with review_commits
    assert_success
    assert_line "harness-weekly: WARN failed to commit the weekly failure rate records; they stay in ${RATES} for the next PR"
    assert_line 'harness-weekly: opened draft PR https://github.com/example/dotfiles/pull/42 (1 commit(s))'
    assert_line 'harness-weekly: committed 1 Rule Ledger record(s) to https://github.com/example/dotfiles/pull/42'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Rule Ledger の記録を足す' 'harness: add rule')"
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/failure-pattern-rates
    assert_output ''
}

@test "選別の結果: 週の記録の commit の後に実行物が書き換えられたら、push の直前の関門で止まる" {
    review_fixture
    local_record 2026-10-10
    init_real
    # 週の記録の oxfmt(記録の commit の途中。データの照合の後)の最中に実行物を書き換える
    cat >"$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
[[ "$*" != 'exec oxfmt docs/harness/failure-pattern-rates' ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-verdict.sh"
EOF
    run review_with review_commits
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-verdict.sh"
    assert_line "harness-weekly: stopped before push on ${BRANCH}; no PR created, because the scripts the job runs could not be trusted"
    refute_published
}

@test "選別の結果: push の後に実行物が書き換えられたら、PR の作成の直前の関門で止まり、ブランチを消すよう案内する" {
    review_fixture
    init_real
    printf '#!/usr/bin/env bash\nprintf "# tampered\\n" >>"%s"\n' "$HOME/.claude/scripts/harness-verdict.sh" >"$ORIGIN/hooks/post-receive"
    chmod +x "$ORIGIN/hooks/post-receive"
    run review_with review_commits
    assert_failure 1
    assert_line "harness-weekly: stopped before gh pr create on ${BRANCH}; no PR created, because the scripts the job runs could not be trusted"
    assert_line "harness-weekly: ${BRANCH} is already on origin; do not open a PR from it as it is. Find what changed the scripts, then delete the branch (git push origin --delete ${BRANCH})"
    refute_pr_create
}

@test "選別の結果: push に失敗したら、手で公開するコマンドを出して失敗し、worktree・ローカルブランチ・本文・結果ファイル・評価の依頼と結果を残す" {
    review_fixture
    init_real
    printf '#!/usr/bin/env bash\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
    chmod +x "$ORIGIN/hooks/pre-receive"
    run review_with review_commits
    assert_failure 1
    assert_line "harness-weekly: push of ${BRANCH} failed; no PR created. To publish by hand: git -C ${REPO} push origin ${BRANCH}, then gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}"
    refute_published
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
    assert [ -s "$RESULT" ]
    assert [ -s "$EVAL_REQUESTS" ]
    assert [ -s "$EVAL_RESULTS" ]
    run git -C "$REPO" rev-list --count "origin/main..refs/heads/$BRANCH"
    assert_output 1
}

@test "選別の結果: PR の作成に失敗したら、手で PR を作って URL を記録するコマンドを出して失敗し、判定の記録を置き換えない" {
    review_fixture
    init_real
    STUB_GH_FAIL=1 run review_with review_commits
    assert_failure 1
    assert_line "harness-weekly: pushed ${BRANCH} but gh pr create failed; open the PR by hand with gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}, then record its URL with bash ~/.claude/scripts/harness-verdict.sh publish --run '${BRANCH} run 0f0e' --pr-url <PR URL>"
    run git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
    run grep -c "adopted (${BRANCH} run 0f0e)" "$HDIR/queue-archive.md"
    assert_output 1
}

@test "選別の結果: 判定の記録にこの run の採用が無ければ、陳腐化の修正だけなら正常と添えて知らせ、成功する" {
    review_fixture
    printf -- '## [2026-10-03] entry\n\n- **Verdict:** adopted (other run)\n' >"$HDIR/queue-archive.md"
    init_real
    run review_with review_commits
    assert_success
    assert_line "harness-weekly: no verdict adopted in run \"${BRANCH} run 0f0e\" in $HDIR/queue-archive.md; PR URL not recorded (normal if the PR only fixes stale rules; otherwise the review did not record its verdicts with the settle command)"
    refute_output --partial 'WARN'
}

@test "選別の結果: 同じ日の前の run が残した採用は、この run の PR の URL に置き換えない" {
    review_fixture
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (%s)\n\n## [2026-10-03] entry\n\n- **Verdict:** adopted (%s run 0f0e)\n' \
        "$BRANCH" "$BRANCH" >"$HDIR/queue-archive.md"
    init_real
    run review_with review_commits
    assert_success
    assert_line 'harness-weekly: recorded the PR URL on 1 verdict(s)'
    run grep -cF "adopted (${BRANCH})" "$HDIR/queue-archive.md"
    assert_output 1
    run grep -c 'adopted (PR https://github.com/example/dotfiles/pull/42)' "$HDIR/queue-archive.md"
    assert_output 1
}

@test "選別の結果: 判定の記録を PR の URL に置き換えられなければ WARN にとどめ、Rule Ledger の記録まで進む" {
    review_fixture
    # publish だけを失敗させる Verdict の CLI(スナップショットの前に置くので書き換えではない)
    cat >"$HOME/.claude/scripts/harness-verdict.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    init_real
    STUB_LEDGER_EXPORT=1 run review_with review_commits
    assert_success
    assert_line "harness-weekly: WARN failed to record the PR URL in $HDIR/queue-archive.md; finish_run reports the unpublished verdicts"
    assert_line 'harness-weekly: committed 1 Rule Ledger record(s) to https://github.com/example/dotfiles/pull/42'
}

@test "選別の結果: Verdict の CLI の adopted が失敗しても、評価の節の見出しを省いて PR を作り、Rule Ledger まで記録する" {
    review_fixture
    # adopted だけを失敗させる Verdict の CLI(スナップショットの前に置くので書き換えではない)
    mv "$HOME/.claude/scripts/harness-verdict.sh" "$HOME/.claude/scripts/harness-verdict-real.sh"
    cat >"$HOME/.claude/scripts/harness-verdict.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" != adopted ]] || exit 1
exec bash "$HOME/.claude/scripts/harness-verdict-real.sh" "$@"
EOF
    init_real
    STUB_LEDGER_EXPORT=1 run review_with review_commits
    assert_success
    assert_line "harness-weekly: WARN could not read the adopted verdicts from $HDIR/queue-archive.md for the eval section"
    assert_line 'harness-weekly: opened draft PR https://github.com/example/dotfiles/pull/42 (1 commit(s))'
    assert_line 'harness-weekly: committed 1 Rule Ledger record(s) to https://github.com/example/dotfiles/pull/42'
    refute_output --partial 'could not be trusted'
}

@test "選別の結果: PR を作った後に実行物が書き換えられたら、片付けたうえで PR を残して失敗する" {
    review_fixture
    init_real
    STUB_GH_TAMPER="$HOME/.claude/scripts/harness-verdict.sh" run review_with review_commits
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-verdict.sh"
    assert_line 'harness-weekly: opened https://github.com/example/dotfiles/pull/42, but the scripts or records the job uses after it could not be trusted; check the PR and the Rule Ledger by hand'
    run grep -c '^pr create' "$GH_LOG"
    assert_output 1
    run grep -c "adopted (${BRANCH} run 0f0e)" "$HDIR/queue-archive.md"
    assert_output 1
    assert [ ! -e "$LEDGER_LOG" ]
    assert [ ! -e "$WT" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_failure
}

@test "選別の結果: PR を作った後にローカルの記録が書き換えられたら、Rule Ledger を記録せずに PR を残して失敗する" {
    review_fixture
    local_record 2026-10-10
    init_real
    STUB_GH_TAMPER="$RATES/2026-10-10.json" run review_with review_commits
    assert_failure 1
    assert_line 'harness-weekly: recorded the PR URL on 1 verdict(s)'
    assert_line 'harness-weekly: opened https://github.com/example/dotfiles/pull/42, but the scripts or records the job uses after it could not be trusted; check the PR and the Rule Ledger by hand'
    assert [ ! -e "$LEDGER_LOG" ]
    assert [ ! -e "$WT" ]
}

@test "選別の結果: PR を作った後に、この run の採用を PR の URL で Rule Ledger に記録・封印し、PR 番号付きで書き出して push し直す" {
    review_fixture
    init_real
    STUB_LEDGER_RECORD='pr42-aaaaaaaa' STUB_LEDGER_EXPORT=1 run review_with review_commits
    assert_success
    assert_line 'harness-rule-ledger: recorded pr42-aaaaaaaa'
    assert_line 'harness-weekly: committed 1 Rule Ledger record(s) to https://github.com/example/dotfiles/pull/42'
    run cat "$LEDGER_LOG"
    assert_line "record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly --results ${EVAL_RESULTS}"
    assert_line --regexp '^export --base [0-9a-f]+ --worktree .* --pr 42$'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Rule Ledger の記録を足す' 'harness: add rule')"
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output docs/harness/rule-ledger/pr42-1.json
}

@test "選別の結果: Rule Ledger に記録できなければ、手で記録するコマンドを WARN で出して成功する" {
    review_fixture
    init_real
    STUB_LEDGER_RECORD_FAIL=1 run review_with review_commits
    assert_success
    assert_line "harness-weekly: WARN failed to record the adoptions of https://github.com/example/dotfiles/pull/42 in the Rule Ledger $HDIR/rule-ledger; record them by hand with bash $HOME/.claude/scripts/harness-rule-ledger.sh record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly"
}

@test "選別の結果: Rule Ledger の記録を commit できなければ、写しかけを戻して WARN にとどめ、成功する" {
    review_fixture
    init_real
    STUB_LEDGER_FAIL=1 run review_with review_commits
    assert_success
    assert_line "harness-weekly: WARN failed to commit the Rule Ledger records; they stay in $HDIR/rule-ledger for a later PR"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
}

@test "選別の結果: Rule Ledger の記録の push に失敗しても、PR を残して WARN にとどめ、成功する" {
    review_fixture
    init_real
    cat >"$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
    ! git ls-tree -r --name-only "$new" | grep -q '^docs/harness/rule-ledger/' || exit 1
done
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
    STUB_LEDGER_EXPORT=1 run review_with review_commits
    assert_success
    assert_line "harness-weekly: WARN push of the Rule Ledger records to ${BRANCH} failed; they stay in $HDIR/rule-ledger for a PR after this one merges"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
    assert [ ! -e "$WT" ]
}

@test "選別の結果: Rule Ledger の記録の commit の後に実行物が書き換えられたら、再 push せずに PR を残して失敗する" {
    review_fixture
    init_real
    # Rule Ledger の oxfmt(export の後、再 push の前)の最中に実行物を書き換える。依存のインストールなどほかの呼び出しは成功させる
    cat >"$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
[[ "$*" != 'exec oxfmt docs/harness/rule-ledger' ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-verdict.sh"
EOF
    STUB_LEDGER_EXPORT=1 run review_with review_commits
    assert_failure 1
    assert_line 'harness-weekly: opened https://github.com/example/dotfiles/pull/42, but the scripts or records the job uses after it could not be trusted; check the PR and the Rule Ledger by hand'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
}

# 選別の claude の代わり。採用の commit に加えて、得点を偽った評価の結果を置く
review_with_fake_results() {
    review_commits
    printf '{"cases":[{"delta":1}]}\n' >"$EVAL_RESULTS"
}

@test "選別の結果: 評価の工程が失敗したら PR は作り、本文に効果を測っていないことを書き、選別が置いた結果も評価が書きかけた結果も Rule Ledger に渡さない" {
    review_fixture
    init_real
    # 評価は結果を書いてから失敗する
    STUB_EVAL_FAIL_AFTER_WRITE=1 run review_with review_with_fake_results
    assert_success
    assert_line "harness-weekly: WARN evaluating the eval cases with $HOME/.claude/scripts/harness-eval-cases.sh failed; the PR body says so"
    assert_line 'harness-weekly: opened draft PR https://github.com/example/dotfiles/pull/42 (1 commit(s))'
    run cat "$GH_BODY"
    assert_output --partial '評価の工程が失敗したため、この PR のルールの効果は測っていない'
    run grep '^record ' "$LEDGER_LOG"
    assert_output 'record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly'
}

@test "選別の結果: 評価が結果を書かずに成功したら、選別が置いた結果を封印せず、評価を信頼できないとして PR を作らずに失敗する" {
    review_fixture
    init_real
    STUB_EVAL_NO_OUT=1 run review_with review_with_fake_results
    assert_failure 1
    assert_line "harness-integrity: could not hash ${EVAL_RESULTS}; not sealed"
    assert_line 'harness-weekly: no PR created; the evaluation could not be trusted'
    refute_published
    assert [ ! -e "$LEDGER_LOG" ]
}

@test "選別の結果: 選別が Eval Case の依頼を書かなければ、空の依頼で評価して、採用を測っていないものとして節に出す" {
    review_fixture
    init_real
    run review_with review_commits
    assert_success
    assert_line "harness-weekly: review wrote no eval requests ${EVAL_REQUESTS}; the PR body lists every adopted rule as unevaluated"
    run cat "$EVAL_REQUESTS"
    assert_output '{"cases": []}'
    run cat "$GH_BODY"
    assert_line '評価した採用: [2026-10-03] entry'
}

@test "選別の結果: 選別の claude が評価のスクリプトを書き換えたら、評価も PR の作成もせずに失敗し、予約コードを外に出さない" {
    review_fixture
    init_real
    run review_with rewriting "$HOME/.claude/scripts/harness-eval-cases.sh" review_commits
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-eval-cases.sh"
    assert_line 'harness-weekly: no PR created; the evaluation could not be trusted'
    refute_evaluated
    assert [ ! -e "$EVAL_RESULTS" ]
    refute_published
    run grep -c "adopted (${BRANCH} run 0f0e)" "$HDIR/queue-archive.md"
    assert_output 1
}

@test "選別の結果: 選別の claude が公開の後に使うスクリプトか Failure Pattern の一覧を書き換えたら、PR を作らずに失敗し、変わったパスだけを出す" {
    review_fixture
    printf '{}\n' >"$HOME/.claude/scripts/harness-failure-patterns.json"
    local file hash
    for file in harness-rule-ledger.sh harness-verdict.sh harness-failure-rates.sh harness-failure-patterns.json; do
        cp "$HOME/.claude/scripts/$file" "$BATS_TEST_TMPDIR/$file.orig"
    done
    for file in harness-rule-ledger.sh harness-verdict.sh harness-failure-rates.sh harness-failure-patterns.json; do
        git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
        git -C "$REPO" branch -q -D "$BRANCH" 2>/dev/null || true
        rm -f "$GH_LOG"
        cp "$BATS_TEST_TMPDIR/$file.orig" "$HOME/.claude/scripts/$file"
        init_real
        run review_with rewriting "$HOME/.claude/scripts/$file" review_commits
        assert_failure 1
        assert_output --partial "changed: $HOME/.claude/scripts/$file"
        hash=$(git hash-object -- "$HOME/.claude/scripts/$file")
        refute_output --partial "$hash"
        refute_published
    done
}

@test "選別の結果: 選別の claude がローカルの Rule Ledger の記録を書き換えたら、PR を作らずに失敗する" {
    review_fixture
    mkdir -p "$HDIR/rule-ledger"
    printf '{"id":"pr30-aaaaaaaa"}\n' >"$HDIR/rule-ledger/pr30-aaaaaaaa.json"
    init_real
    run review_with rewriting "$HDIR/rule-ledger/pr30-aaaaaaaa.json" review_commits
    assert_failure 1
    assert_output --partial "changed: $HDIR/rule-ledger/pr30-aaaaaaaa.json"
    refute_published
    assert [ ! -e "$LEDGER_LOG" ]
}

# 選別の claude の代わり。採用の commit を作ってから、週の記録をハッシュを取れなくする
review_hiding_record() {
    review_commits
    chmod 000 "$RATES/2026-10-10.json"
}

@test "選別の結果: ハッシュを取れなくなった週の記録は、照合できないとして PR を作らずに失敗する(WARN で公開を続けない)" {
    review_fixture
    local_record 2026-10-10
    init_real
    run review_with review_hiding_record
    chmod 644 "$RATES/2026-10-10.json"
    assert_failure 1
    assert_output --partial "could not hash $RATES/2026-10-10.json"
    refute_output --partial 'WARN failed to commit the weekly failure rate records'
    refute_published
}

@test "選別が何も commit しなかった週: Metrics-only PR が要らなければ、その旨を出して片付けて成功する" {
    review_fixture
    init_real
    run review_with review_no_commits
    assert_success
    assert_output "$(printf '%s\n' "$START_LINE" \
        "harness-weekly: 0 weekly failure rate record(s) not on origin/main; carried over in $RATES (a metrics-only PR needs 4)" \
        'harness-weekly: review committed no changes; no PR created')"
    refute_evaluated
    assert_discarded
}

@test "選別が何も commit しなかった週: 前の run が残した別の run の採用の印は、この run の commit が無いことの失敗に数えない" {
    review_fixture
    init_real
    # 選別は何も記録しない。判定の記録には前の run の採用だけが残っている
    printf -- '## [2026-01-01] old\n\n- **Verdict:** adopted (%s run old)\n' "$BRANCH" >"$HDIR/queue-archive.md"
    commit_nothing() {
        printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
    }
    run review_with commit_nothing
    assert_success
    assert_line 'harness-weekly: review committed no changes; no PR created'
    refute_output --partial 'but the review committed nothing'
}

@test "選別が何も commit しなかった週: 記録がたまっていれば、依存を入れ直さずに Metrics-only PR を作る" {
    review_fixture
    four_local_records
    init_real
    run review_with review_no_commits
    assert_success
    assert_line --index 1 'harness-weekly: review committed no changes; opening a metrics-only PR'
    assert_line 'harness-weekly: opened metrics-only draft PR https://github.com/example/dotfiles/pull/42 (4 weekly record(s))'
    run grep '^pr create' "$GH_LOG"
    assert_output "pr create --draft --base main --head ${BRANCH} --title harness: 週次の指標 2026-10-17 --body-file ${BODY}"
    run cat "$GH_BODY"
    assert_line --index 0 "$(metrics_only_counts 4)"
    refute_output --partial 'reason'
    run cat "$PNPM_LOG"
    assert_output "$(printf '%s\n' "$WT install --frozen-lockfile --prefer-offline" "$WT exec oxfmt docs/harness/failure-pattern-rates")"
    refute_evaluated
}

@test "選別が何も commit しなかった週: 記録がたまっていても、Loop PR が開いていれば件数と URL を出して片付けて成功する" {
    review_fixture
    four_local_records
    init_real
    STUB_GH_OPEN_PRS='[{"headRefName":"test/loop-2026-10-10","url":"https://github.com/example/dotfiles/pull/40"}]' \
        run review_with review_no_commits
    assert_success
    assert_line 'harness-weekly: 4 weekly failure rate record(s) not on origin/main, but loop PR https://github.com/example/dotfiles/pull/40 is open; carried over'
    assert_line 'harness-weekly: review committed no changes; no PR created'
    assert_discarded
}

@test "選別が何も commit しなかった週: 開いている PR を調べられなければ WARN を出して片付けて成功する" {
    review_fixture
    four_local_records
    init_real
    STUB_GH_LIST_FAIL=1 run review_with review_no_commits
    assert_success
    assert_line 'harness-weekly: WARN listing open loop PRs failed; no metrics-only PR this week'
    assert_discarded
}

@test "選別の結果: commit されていない変更が残っていたら、PR を作らずに失敗する" {
    review_fixture
    init_real
    run review_with leave_uncommitted
    assert_failure 1
    assert_line "harness-weekly: review left uncommitted changes in ${WT}; no PR created"
    refute_published
}

@test "選別の結果: commit があり deploy-only の修正もあれば、本文に節が入り deploy-only.md にも残る(本文に絶対パスを書かない)" {
    review_fixture
    init_real
    with_deploy_only() {
        review_commits
        printf '{"dropped":[],"deploy_only":["複数行の\\n説明"]}\n' >"$RESULT"
    }
    run review_with with_deploy_only
    assert_success
    run cat "$GH_BODY"
    assert_output --partial '## deploy-only の修正'
    assert_output --partial '- 複数行の 説明'
    refute_output --partial '## 落とした変更'
    assert_output --partial '~/.claude/harness/deploy-only.md にも記録した'
    refute_output --partial "$HOME"
    run cat "$HDIR/deploy-only.md"
    assert_output --partial '- 複数行の 説明'
}

@test "選別の結果: 結果ファイルを書かなければ、同じ日の前の run の結果ファイルを読まずに、評価も PR の作成もせずに失敗し、調べるための worktree と本文を残す" {
    review_fixture
    init_real
    printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
    without_result() {
        printf 'rule\n' >rule.md
        git add rule.md
        git commit -qm 'harness: add rule'
        printf '本文\n' >"$BODY"
    }
    run review_with without_result
    assert_failure 1
    assert_line "harness-weekly: review did not write a valid result file ${RESULT} (a JSON object with string arrays \"dropped\" and \"deploy_only\"); no PR created"
    refute_evaluated
    refute_published
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
}

# 選別の claude の代わり。採用を記録したのに commit せず、Verdict の CLI の採用の列挙(adopted)だけが空を返すように書き換える
hide_adoptions() {
    local cli="$HOME/.claude/scripts/harness-verdict.sh"
    printf -- '## [2026-10-03] entry\n\n- **Verdict:** adopted (%s)\n' "$HARNESS_REVIEW_RUN" >"$HDIR/queue-archive.md"
    printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
    cp "$cli" "$cli.orig"
    cat >"$cli" <<EOF
#!/usr/bin/env bash
[[ "\$1" == adopted ]] && exit 0
exec bash "$cli.orig" "\$@"
EOF
}

@test "選別が何も commit しなかった週に選別の claude が Verdict の CLI に採用を隠させたら、変更なしの成功ではなく PR を作らずに失敗し、予約コードを外に出さない" {
    review_fixture
    init_real
    run review_with hide_adoptions
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-verdict.sh"
    assert_line 'harness-weekly: no PR created; the Verdict CLI could not be trusted'
    refute_output --partial 'committed no changes'
    refute_published
}

@test "選別の claude が commit の後に失敗したら、手で作る PR の本文に節を足し、残った commit を手で公開する手順を出して失敗する" {
    review_fixture
    init_real
    run review_with then_fail review_commits
    assert_failure 1
    assert_line "harness-weekly: review failed after 1 commit(s) on local branch ${BRANCH} (worktree ${WT}, PR body ${BODY}); verdicts adopted in this run may already be in $HDIR/queue-archive.md. To publish by hand: git -C ${REPO} push origin ${BRANCH}, then gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}, then bash ~/.claude/scripts/harness-verdict.sh publish --run '${BRANCH} run 0f0e' --pr-url <PR URL>"
    run cat "$BODY"
    assert_line --index 0 '本文'
    assert_line '## 推移'
    refute_evaluated
    refute_published
    assert [ -d "$WT" ]
    assert [ -s "$RESULT" ]
}

# 選別の claude の代わり。採用の commit に加えて、落とした変更と deploy-only の修正を結果ファイルに書く
review_with_dropped() {
    review_commits
    printf '{"dropped":["harness: other(prek で失敗)"],"deploy_only":["v を適用する"]}\n' >"$RESULT"
}

@test "選別の claude が commit と結果ファイルを書いた後に失敗したら、手で作る PR の本文に結果の節と検出の節を足す" {
    review_fixture
    init_real
    run review_with then_fail review_with_dropped
    assert_failure 1
    assert_line --partial 'harness-weekly: review failed after 1 commit(s)'
    run cat "$BODY"
    assert_output --partial '## 落とした変更'
    assert_output --partial '- harness: other(prek で失敗)'
    assert_output --partial '## deploy-only の修正'
    assert_output --partial '- v を適用する'
    assert_output --partial '~/.claude/harness/deploy-only.md にも記録した'
    refute_output --partial "$HOME"
    assert_line '## 失敗の検出'
    assert_line '2026-10-17 の Weekly Rate Record の期間'
}

@test "選別の claude が commit の後に失敗した run で再発率のスクリプトが書き換えられていたら、失敗の検出と推移の節を足さず、手で公開する手順を案内しない" {
    review_fixture
    init_real
    run review_with then_fail rewriting "$HOME/.claude/scripts/harness-failure-rates.sh" review_commits
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-failure-rates.sh"
    assert_output --partial 'the failure detection counts could not be trusted'
    assert_output --partial 'do not publish the branch as it is'
    refute_output --partial 'To publish by hand'
    run cat "$BODY"
    refute_line '## 失敗の検出'
    refute_line '## 推移'
}

@test "選別の claude が commit の前に失敗したら、その旨を出して失敗する" {
    review_fixture
    init_real
    run review_with then_fail review_no_commits
    assert_failure 1
    assert_line "harness-weekly: review failed before committing; worktree ${WT} kept; verdicts already moved to $HDIR/queue-archive.md stay there"
    refute_output --partial 'the records the job uses were changed'
    refute_published
    assert [ -d "$WT" ]
}

@test "照合に落ちた選別が commit を残していたら、手で公開する手順の代わりにそのまま公開しないよう案内し、予約コードを外に出さない" {
    review_fixture
    local_record 2026-10-10
    printf '{"session_id":"s1","run":"r1","date":"2026-10-17","epoch":%s,"counts":{"tool_error":3}}\n' "$(date +%s)" >"$HDIR/detections.jsonl"
    local stage
    # 選別の claude が成功した run と失敗した run のどちらも
    for stage in rewriting 'then_fail rewriting'; do
        git -C "$REPO" worktree remove --force "$WT" 2>/dev/null || true
        git -C "$REPO" branch -q -D "$BRANCH" 2>/dev/null || true
        printf '{"date":"2026-10-10"}\n' >"$RATES/2026-10-10.json"
        init_real
        # shellcheck disable=SC2086 # 工程の語を分けて渡す
        run review_with $stage "$RATES/2026-10-10.json" review_commits
        assert_failure 1
        assert_output --partial "changed: $RATES/2026-10-10.json"
        assert_line "harness-weekly: review failed after 1 commit(s) on local branch ${BRANCH} (worktree ${WT}), and the scripts or records the job uses were changed (or could not be checked) after the claude runs started; do not publish the branch as it is. Restore them, find what changed them, and review the commits before publishing them by hand"
        refute_output --partial 'To publish by hand'
        run cat "$BODY"
        refute_line '## 推移'
        refute_line '## 失敗の検出'
        refute_evaluated
        refute_published
        assert [ -d "$WT" ]
        assert [ -s "$RESULT" ]
    done
}

# 選別の claude の代わり。commit せずに、追跡されていないファイルを残す
leave_uncommitted() {
    review_no_commits
    printf 'x\n' >stray.md
}

@test "照合に落ちた選別が commit を残していなければ、記録が書き換えられたことを告げて失敗し、予約コードを外に出さない" {
    review_fixture
    local_record 2026-10-10
    local stage
    # 選別の claude が失敗した run と、成功して commit されていない変更を残した run のどちらも(未 commit の確認より照合が先)
    for stage in 'then_fail rewriting' rewriting; do
        printf '{"date":"2026-10-10"}\n' >"$RATES/2026-10-10.json"
        init_real
        # shellcheck disable=SC2086 # 工程の語を分けて渡す
        run review_with $stage "$RATES/2026-10-10.json" leave_uncommitted
        assert_failure 1
        assert_output --partial "changed: $RATES/2026-10-10.json"
        assert_line "harness-weekly: review made no commits, and the records the job uses were changed (or could not be checked) after the claude runs started; restore them and find what changed them. Worktree ${WT} kept; verdicts already moved to $HDIR/queue-archive.md stay there"
        refute_output --partial 'review failed before committing'
        refute_output --partial 'uncommitted changes'
        refute_published
    done
}

@test "選別の経路の入口は、開始の行かコマンドが無ければ使い方の誤りとして失敗する" {
    review_fixture
    init_real
    run harness_loop_pr_run_review "$START_LINE"
    assert_failure 1
    assert_output 'harness-loop-pr: harness_loop_pr_run_review needs <start line> and the command that runs the review'
    run harness_loop_pr_run_review '' review_commits
    assert_failure 1
    assert_output 'harness-loop-pr: harness_loop_pr_run_review needs <start line> and the command that runs the review'
    refute_reviewed
    refute_published
}
