# 週次ジョブの公開の module(lib/harness-publish.bash)の interface の検査。lib を直接 source する。
# 公開の分岐(入口ごとの失敗の扱い・要否の判定・片付け)はここで検査する。週次ジョブがこの lib を読み込めないときに
# 止まることと、各案内文が綴りを使う配線、採用のある PR と Metrics-only PR を開く配線、公開の失敗で run が失敗して
# heartbeat を書かない配線は test/harness-weekly.bats が検査する。
setup() {
    load 'helpers/setup'
    LIB="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-publish.bash"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude/scripts"
    # 公開の手順は Integrity Snapshot の照合と関門を使うので、週次ジョブと同じくその lib の後に読む
    # shellcheck source=../dot_claude/scripts/lib/harness-integrity.bash
    source "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-integrity.bash"
    # shellcheck source=../dot_claude/scripts/lib/harness-publish.bash
    source "$LIB"
}

@test "push のコマンドは、リポジトリを渡せば -C 付き、渡さなければ -C 無しで綴る" {
    run harness_publish_push_command harness/review-2026-10-17 /work/repo
    assert_success
    assert_output 'git -C /work/repo push origin harness/review-2026-10-17'
    run harness_publish_push_command '<branch>'
    assert_success
    assert_output 'git push origin <branch>'
}

@test "draft PR の作成のコマンドは、本文を渡せば --body-file 付き、渡さなければ無しで綴る" {
    run harness_publish_pr_command harness/review-2026-10-17 /h/review-pr-body-2026-10-17.md
    assert_success
    assert_output 'gh pr create --draft --base main --head harness/review-2026-10-17 --body-file /h/review-pr-body-2026-10-17.md'
    run harness_publish_pr_command '<branch>'
    assert_success
    assert_output 'gh pr create --draft --base main --head <branch>'
}

@test "判定の記録に PR の URL を記録するコマンドは、印をシングルクォートで囲んで綴る" {
    run harness_publish_record_command 'harness/review-2026-10-17 run 0f0e'
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
    command=$(harness_publish_record_command "$1")
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

init_publish() { # [<上書きする引数>…]
    harness_publish_init --repo /work/repo --worktree /h/review-worktree \
        --branch harness/review-2026-10-17 --loop-branch-prefix harness/review- \
        --pr-body /h/review-pr-body-2026-10-17.md --review-result /h/review-result-2026-10-17.json --eval-results /h/eval-results-2026-10-17.json \
        --date 2026-10-17 --run 'harness/review-2026-10-17 run 0f0e' "$@"
}

@test "初期化は run ごとの値と Loop PR のブランチの prefix がすべて揃えば成功する" {
    run init_publish
    assert_success
    assert_output ''
}

@test "初期化は値が欠けていれば、欠けた引数の名前を出して失敗する" {
    run harness_publish_init --repo /work/repo --worktree /h/review-worktree \
        --branch harness/review-2026-10-17 --loop-branch-prefix harness/review- \
        --pr-body /h/review-pr-body-2026-10-17.md --review-result /h/review-result-2026-10-17.json --eval-results /h/eval-results-2026-10-17.json \
        --date 2026-10-17
    assert_failure
    assert_output --partial '--run'
    run init_publish --worktree ''
    assert_failure
    assert_output --partial '--worktree'
}

@test "初期化は知らない引数を受け付けない" {
    run init_publish --repository /work/repo
    assert_failure
    assert_output --partial '--repository'
}

@test "初期化はブランチが Loop PR の prefix で始まらなければ失敗する" {
    run init_publish --branch feature/x
    assert_failure
    assert_output --partial 'feature/x'
    assert_output --partial 'harness/review-'
}

@test "Rule Ledger の記録の置き場は、Rule Ledger のスクリプトが書き出す置き場と同じ" {
    run sed -n 's/^LEDGER_REPO_DIR="\(.*\)"$/\1/p' "$REPO_ROOT/dot_claude/scripts/executable_harness-rule-ledger.sh"
    assert_output "$HARNESS_PUBLISH_LEDGER_REPO_DIR"
    assert_equal "$HARNESS_PUBLISH_LEDGER_REPO_DIR" docs/harness/rule-ledger
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
    run guarded dot_claude/scripts/lib/harness-publish.bash "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
    run guarded test/harness-publish.bats "$REPO_ROOT/scripts/guarded-paths.txt"
    assert_success
}

# publish_fixture は Metrics-only PR の要否の判定・公開・片付けの検査の fixture。git は実物を使い、origin は使い捨ての bare リポジトリにする。
# gh と pnpm は PATH に置いた偽物、Rule Ledger のスクリプトは書き出す件数を STUB_LEDGER_EXPORT で決める偽物にする
# (記録の選び方は test/harness-rule-ledger.bats の範囲)。Integrity Snapshot の lib は本物を使う。
#
# 偽の gh:
# - pr list は STUB_GH_OPEN_PRS(既定 [])の JSON に、渡された --jq の式を jq -r で当てて返す(本物の gh と同じく、
#   照会の式そのものを検査に残す)。STUB_GH_LIST_FAIL で失敗する
# - pr create は --body-file を GH_BODY に写し、STUB_GH_FAIL で失敗し、成功時は PR の URL を出す
# 呼び出しはすべて GH_LOG に 1 行ずつ書く
publish_fixture() {
    unset STUB_GH_OPEN_PRS STUB_GH_LIST_FAIL STUB_GH_FAIL STUB_PNPM_FAIL STUB_LEDGER_EXPORT STUB_LEDGER_FAIL
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    printf '[user]\n\tname = test\n\temail = test@example.com\n[commit]\n\tgpgsign = false\n[init]\n\tdefaultBranch = main\n' \
        >"$GIT_CONFIG_GLOBAL"
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log" GH_BODY="$BATS_TEST_TMPDIR/gh-body.md" PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log"
    HDIR="$HOME/.claude/harness"
    RATES="$HDIR/failure-pattern-rates"
    mkdir -p "$RATES"
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    REPO="$BATS_TEST_TMPDIR/repo"
    WT="$HDIR/review-worktree"
    BRANCH=test/loop-2026-10-17
    BODY="$HDIR/review-pr-body-2026-10-17.md"
    RESULT="$HDIR/review-result-2026-10-17.json"
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
    [[ -z "${STUB_GH_LIST_FAIL:-}" ]] || exit 1
    expression=""
    while [[ $# -gt 0 ]]; do
        [[ "$1" == --jq ]] && expression=$2
        shift
    done
    printf '%s\n' "${STUB_GH_OPEN_PRS:-[]}" | jq -r "$expression"
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
[[ -z "${STUB_PNPM_FAIL:-}" ]]
EOF
    chmod +x "$STUBS/gh" "$STUBS/pnpm"
    export PATH="$STUBS:$PATH"
    # 偽の Rule Ledger の export。worktree の置き場に STUB_LEDGER_EXPORT 件の記録を書いて件数を出す。STUB_LEDGER_FAIL なら
    # 1 件だけ書いてから失敗する(写しかけの記録を残して失敗する export の再現)
    cat >"$HOME/.claude/scripts/harness-rule-ledger.sh" <<'EOF'
#!/usr/bin/env bash
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
}

# <日付>: ローカルに週の記録を置く
local_record() {
    printf '{"date":"%s"}\n' "$1" >"$RATES/$1.json"
}

# <日付>: ローカルの週の記録を origin/main にも commit する(マージ済みの記録の再現)
merged_record() {
    mkdir -p "$REPO/docs/harness/failure-pattern-rates"
    cp "$RATES/$1.json" "$REPO/docs/harness/failure-pattern-rates/"
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "record $1"
    git -C "$REPO" push -q origin main
}

# 週次ジョブの prepare_worktree と同じく、origin/main から当日のブランチの worktree を切る
make_worktree() {
    git -C "$REPO" fetch -q origin main
    git -C "$REPO" worktree add -q --no-track -b "$BRANCH" "$WT" origin/main
    BASE=$(git -C "$WT" rev-parse HEAD)
}

# スナップショットを取ってから、実際のパスと既定と違う Loop PR の prefix で初期化する
init_real() {
    harness_integrity_snapshot
    harness_publish_init --repo "$REPO" --worktree "$WT" --branch "$BRANCH" --loop-branch-prefix test/loop- \
        --pr-body "$BODY" --review-result "$RESULT" --eval-results "$HDIR/eval-results-2026-10-17.json" --date 2026-10-17 --run "$BRANCH run 0f0e"
}

four_local_records() {
    local_record 2026-09-26
    local_record 2026-10-03
    local_record 2026-10-10
    local_record 2026-10-17
}

# 本文の lib(lib/harness-pr-body.bash)の Metrics-only PR の入口の代わり。本文の中身はその lib の bats の範囲なので、
# ここでは受け取った件数と、呼ばれた時点で worktree にある commit の数(記録の commit の後に呼ばれたか)を本文に書く。
# BODY_STATUS があればその値で終わり、BODY_TAMPER があれば書いた後に Rule Ledger のスクリプトを書き換える
# (本文を書いた後で push の前に実行物が書き換えられた run の再現)
harness_pr_body_metrics_only() {
    printf 'rates=%s ledger=%s commits=%s\n' "$1" "$2" "$(git -C "$WT" rev-list --count "$BASE..HEAD")" >"$BODY"
    [[ -z "${BODY_TAMPER:-}" ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
    return "${BODY_STATUS:-0}"
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

@test "要否の 1 段目: ローカルの記録が 4 週分に満たなければ、worktree も gh も使わずに件数の上限を出して要らないとする" {
    publish_fixture
    local_record 2026-10-03
    local_record 2026-10-10
    local_record 2026-10-17
    init_real
    run harness_publish_metrics_only_maybe_due
    assert_failure 1
    assert_line "harness-weekly: at most 3 weekly failure rate record(s) not on origin/main; carried over in $RATES (a metrics-only PR needs 4)"
    assert [ ! -e "$GH_LOG" ]
}

@test "要否の 1 段目: ローカルの記録が 4 週分あり、開いている Loop PR が無ければ要るかもしれないとする" {
    publish_fixture
    four_local_records
    init_real
    run harness_publish_metrics_only_maybe_due
    assert_success
    assert_output ''
    assert [ ! -e "$WT" ]
}

@test "要否の 1 段目: 初期化で受け取った prefix のブランチの PR が開いていれば、その URL を出して要らないとする" {
    publish_fixture
    four_local_records
    init_real
    STUB_GH_OPEN_PRS='[{"headRefName":"feature/x","url":"https://github.com/example/dotfiles/pull/39"},{"headRefName":"test/loop-2026-10-10","url":"https://github.com/example/dotfiles/pull/40"}]' \
        run harness_publish_metrics_only_maybe_due
    assert_failure 1
    assert_line 'harness-weekly: loop PR https://github.com/example/dotfiles/pull/40 is open; weekly failure rate records carried over'
}

@test "要否の 1 段目: 開いている PR のブランチが prefix で始まらなければ Loop PR と数えない" {
    publish_fixture
    four_local_records
    init_real
    STUB_GH_OPEN_PRS='[{"headRefName":"harness/review-2026-10-10","url":"https://github.com/example/dotfiles/pull/40"},{"headRefName":"feature/test/loop-x","url":"https://github.com/example/dotfiles/pull/41"}]' \
        run harness_publish_metrics_only_maybe_due
    assert_success
    assert_output ''
}

@test "要否の 1 段目: 開いている PR を調べられなければ WARN を出して要らないとする" {
    publish_fixture
    four_local_records
    init_real
    STUB_GH_LIST_FAIL=1 run harness_publish_metrics_only_maybe_due
    assert_failure 1
    assert_line 'harness-weekly: WARN listing open loop PRs failed; no metrics-only PR this week'
}

@test "要否の 2 段目: origin/main にある週は数えず、4 週分に満たなければ件数を出して要らないとする" {
    publish_fixture
    four_local_records
    merged_record 2026-09-26
    make_worktree
    init_real
    run harness_publish_metrics_only_due "$BASE"
    assert_failure 1
    assert_line "harness-weekly: 3 weekly failure rate record(s) not on origin/main; carried over in $RATES (a metrics-only PR needs 4)"
    assert [ ! -e "$GH_LOG" ]
}

@test "要否の 2 段目: origin/main に無い週が 4 週分あり、開いている Loop PR が無ければ要るとする" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    run harness_publish_metrics_only_due "$BASE"
    assert_success
    assert_output ''
}

@test "要否の 2 段目: Loop PR が開いていれば、件数と URL を出して要らないとする" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_GH_OPEN_PRS='[{"headRefName":"test/loop-2026-10-10","url":"https://github.com/example/dotfiles/pull/40"}]' \
        run harness_publish_metrics_only_due "$BASE"
    assert_failure 1
    assert_line 'harness-weekly: 4 weekly failure rate record(s) not on origin/main, but loop PR https://github.com/example/dotfiles/pull/40 is open; carried over'
}

@test "要否の 2 段目: 開いている PR を調べられなければ WARN を出して要らないとする" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_GH_LIST_FAIL=1 run harness_publish_metrics_only_due "$BASE"
    assert_failure 1
    assert_line 'harness-weekly: WARN listing open loop PRs failed; no metrics-only PR this week'
}

@test "Metrics-only PR: 記録を commit して push し、commit の後に本文の lib に件数を渡して書かせた本文で draft PR を作って片付ける" {
    publish_fixture
    four_local_records
    merged_record 2026-09-26
    local_record 2026-09-19
    make_worktree
    init_real
    run harness_publish_metrics_only "$BASE"
    assert_success
    assert_line 'harness-weekly: opened metrics-only draft PR https://github.com/example/dotfiles/pull/42 (4 weekly record(s))'
    run grep '^pr create' "$GH_LOG"
    assert_output "pr create --draft --base main --head ${BRANCH} --title harness: 週次の指標 2026-10-17 --body-file ${BODY}"
    run cat "$GH_BODY"
    assert_output 'rates=4 ledger=0 commits=1'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: Failure Pattern の再発率の週の記録を足す'
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH"
    assert_output "$(printf 'docs/harness/failure-pattern-rates/%s.json\n' 2026-09-19 2026-10-03 2026-10-10 2026-10-17)"
    run cat "$PNPM_LOG"
    assert_output "$WT exec oxfmt docs/harness/failure-pattern-rates"
    assert [ ! -e "$WT" ]
    assert [ ! -e "$BODY" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_failure
}

@test "記録の commit は、GIT_CONFIG_GLOBAL が無ければ Claude Code の git の設定(~/.config/git/claude-code.inc)で作る" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    mkdir -p "$HOME/.config/git"
    printf '[user]\n\tname = claude-code-agent\n\temail = agent@example.com\n[commit]\n\tgpgsign = false\n' \
        >"$HOME/.config/git/claude-code.inc"
    unset GIT_CONFIG_GLOBAL
    run harness_publish_metrics_only "$BASE"
    assert_success
    run git -C "$ORIGIN" log --format=%an "main..$BRANCH"
    assert_output claude-code-agent
}

@test "Metrics-only PR: 持ち越した Rule Ledger の記録を PR を作る前に commit し、その件数も本文の lib に渡す" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_LEDGER_EXPORT=2 run harness_publish_metrics_only "$BASE"
    assert_success
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Rule Ledger の記録を足す' 'harness: Failure Pattern の再発率の週の記録を足す')"
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output "$(printf 'docs/harness/rule-ledger/%s.json\n' pr30-1 pr30-2)"
    run cat "$GH_BODY"
    assert_output 'rates=4 ledger=2 commits=2'
}

@test "Metrics-only PR: 再発率の記録を commit できなければ、PR を作らずに失敗する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_PNPM_FAIL=1 run harness_publish_metrics_only "$BASE"
    assert_failure 1
    assert_line "harness-weekly: failed to commit the weekly failure rate records in ${WT}; no PR created"
    refute_published
}

@test "Metrics-only PR: スナップショットの後に週の記録が書き換えられていたら、commit も PR もせずに失敗し、予約コードを外に出さない" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    printf '{"tampered":true}\n' >"$RATES/2026-10-10.json"
    run harness_publish_metrics_only "$BASE"
    assert_failure 1
    assert_output --partial "changed: $RATES/2026-10-10.json"
    assert_line "harness-weekly: failed to commit the weekly failure rate records in ${WT}; no PR created"
    run git -C "$WT" rev-list --count "$BASE..HEAD"
    assert_output 0
    refute_published
}

@test "Metrics-only PR: Rule Ledger のスクリプトが書き換えられていたら、Rule Ledger を信頼できないとして PR を作らずに失敗する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
    run harness_publish_metrics_only "$BASE"
    assert_failure 1
    assert_line 'harness-weekly: the Rule Ledger records could not be trusted; no PR created'
    refute_published
}

@test "Metrics-only PR: Rule Ledger の記録を commit できなければ、写しかけを戻して Metrics-only PR を作る" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_LEDGER_FAIL=1 run harness_publish_metrics_only "$BASE"
    assert_success
    assert_line "harness-weekly: WARN failed to commit the Rule Ledger records; they stay in $HDIR/rule-ledger for a later PR"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: Failure Pattern の再発率の週の記録を足す'
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output ''
    run cat "$GH_BODY"
    assert_output 'rates=4 ledger=0 commits=1'
}

@test "Metrics-only PR: 本文の lib が失敗したら、push も PR の作成もせずに失敗する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    BODY_STATUS=1 run harness_publish_metrics_only "$BASE"
    assert_failure 1
    refute_published
}

@test "Metrics-only PR: 本文の lib が照合に落ちたら、予約コードを外に出さずに PR を作らずに失敗する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    BODY_STATUS=$HARNESS_INTEGRITY_FAILED run harness_publish_metrics_only "$BASE"
    assert_failure 1
    refute_published
}

@test "Metrics-only PR: 本文を書いた後に実行物が書き換えられたら、push の直前の関門で止まる" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    BODY_TAMPER=1 run harness_publish_metrics_only "$BASE"
    assert_failure 1
    assert_line "harness-weekly: stopped before push on ${BRANCH}; no PR created, because the scripts the job runs could not be trusted"
    refute_published
}

@test "Metrics-only PR: push の後に実行物が書き換えられたら、PR の作成の直前の関門で止まり、ブランチを消すよう案内する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    # push を受けた origin のフックが実行物を書き換える
    printf '#!/usr/bin/env bash\nprintf "# tampered\\n" >>"%s"\n' "$HOME/.claude/scripts/harness-rule-ledger.sh" >"$ORIGIN/hooks/post-receive"
    chmod +x "$ORIGIN/hooks/post-receive"
    run harness_publish_metrics_only "$BASE"
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
    make_worktree
    init_real
    printf '#!/usr/bin/env bash\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
    chmod +x "$ORIGIN/hooks/pre-receive"
    run harness_publish_metrics_only "$BASE"
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
    make_worktree
    init_real
    STUB_GH_FAIL=1 run harness_publish_metrics_only "$BASE"
    assert_failure 1
    assert_line "harness-weekly: pushed ${BRANCH} but gh pr create failed; open the PR by hand with gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}"
    run git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
}

@test "公開しないで片付けると、本文・結果ファイル・worktree を消し、ローカルブランチは残す" {
    publish_fixture
    make_worktree
    init_real
    printf 'body\n' >"$BODY"
    printf '{}\n' >"$RESULT"
    run harness_publish_discard
    assert_success
    assert [ ! -e "$WT" ]
    assert [ ! -e "$BODY" ]
    assert [ ! -e "$RESULT" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
}

# review_fixture は選別の結果の公開(harness_publish_review)の検査の fixture。publish_fixture に選別の commit・
# 判定の記録・Rule Ledger の record を足す。Verdict の CLI は本物を置き(判定の記録の書き換えを検査に残す)、Rule Ledger の
# record は偽物にする(記録の作り方は test/harness-rule-ledger.bats の範囲)。
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

# 選別の claude の代わりに、worktree に採用の commit を 1 つ作り、本文を書く
review_commit() {
    printf 'rule\n' >"$WT/rule.md"
    git -C "$WT" add rule.md
    git -C "$WT" commit -qm 'harness: add rule'
    printf '本文\n' >"$BODY"
    printf '{"dropped":[],"deploy_only":[]}\n' >"$RESULT"
}

# 採用の commit のある worktree を作り、スナップショットを取って初期化する
review_ready() {
    make_worktree
    review_commit
    init_real
}

@test "選別の結果: 記録を commit して push し、draft PR を作って判定の記録を PR の URL に置き換え、片付ける" {
    review_fixture
    local_record 2026-10-10
    review_ready
    run harness_publish_review "$BASE"
    assert_success
    assert_line 'harness-weekly: committed 1 weekly failure rate record(s)'
    # commit の件数は選別の commit だけを数える
    assert_line 'harness-weekly: opened draft PR https://github.com/example/dotfiles/pull/42 (1 commit(s))'
    assert_line 'harness-weekly: recorded the PR URL on 1 verdict(s)'
    run grep '^pr create' "$GH_LOG"
    assert_output "pr create --draft --base main --head ${BRANCH} --title harness: 週次レビュー 2026-10-17 --body-file ${BODY}"
    run cat "$GH_BODY"
    assert_output '本文'
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

@test "選別の結果: origin/main に無い週の記録が無ければ、記録の commit を作らずに PR を作る" {
    review_fixture
    review_ready
    run harness_publish_review "$BASE"
    assert_success
    refute_output --partial 'weekly failure rate record(s)'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
}

@test "選別の結果: 当日の記録は origin/main に同じ日付があっても中身が違えば載せ、前の日付の記録は中身が違っても載せない" {
    review_fixture
    local_record 2026-10-10
    local_record 2026-10-17
    merged_record 2026-10-10
    merged_record 2026-10-17
    # origin/main の記録を人が直した後の前の日付と、同じ日の再実行が書き直した当日の記録
    printf '{"date":"2026-10-10","fixed":true}\n' >"$RATES/2026-10-10.json"
    printf '{"date":"2026-10-17","rerun":true}\n' >"$RATES/2026-10-17.json"
    review_ready
    run harness_publish_review "$BASE"
    assert_success
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/failure-pattern-rates
    assert_output docs/harness/failure-pattern-rates/2026-10-17.json
}

@test "選別の結果: 当日の記録が origin/main と JSON として同じなら載せない" {
    review_fixture
    local_record 2026-10-17
    merged_record 2026-10-17
    printf '{ "date": "2026-10-17" }\n' >"$RATES/2026-10-17.json"
    review_ready
    run harness_publish_review "$BASE"
    assert_success
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/failure-pattern-rates
    assert_output ''
}

@test "選別の結果: スナップショットの後に週の記録が書き換えられていたら、WARN で続けずに PR を作らずに失敗し、予約コードを外に出さない" {
    review_fixture
    local_record 2026-10-10
    review_ready
    printf '{"tampered":true}\n' >"$RATES/2026-10-10.json"
    run harness_publish_review "$BASE"
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
    review_ready
    # 週の記録を含む commit だけを拒む commit フック。写しかけを戻さないと、後の Rule Ledger の commit も拒まれる
    printf '#!/usr/bin/env bash\n! git diff --cached --name-only | grep -q "^docs/harness/failure-pattern-rates/"\n' >"$REPO/.git/hooks/pre-commit"
    chmod +x "$REPO/.git/hooks/pre-commit"
    STUB_LEDGER_EXPORT=1 run harness_publish_review "$BASE"
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
    review_ready
    # oxfmt(記録の commit の途中。データの照合の後)の最中に実行物を書き換える
    cat >"$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
printf '# tampered\n' >>"$HOME/.claude/scripts/harness-verdict.sh"
EOF
    run harness_publish_review "$BASE"
    assert_failure 1
    assert_output --partial "changed: $HOME/.claude/scripts/harness-verdict.sh"
    assert_line "harness-weekly: stopped before push on ${BRANCH}; no PR created, because the scripts the job runs could not be trusted"
    refute_published
}

@test "選別の結果: push の後に実行物が書き換えられたら、PR の作成の直前の関門で止まり、ブランチを消すよう案内する" {
    review_fixture
    review_ready
    printf '#!/usr/bin/env bash\nprintf "# tampered\\n" >>"%s"\n' "$HOME/.claude/scripts/harness-verdict.sh" >"$ORIGIN/hooks/post-receive"
    chmod +x "$ORIGIN/hooks/post-receive"
    run harness_publish_review "$BASE"
    assert_failure 1
    assert_line "harness-weekly: stopped before gh pr create on ${BRANCH}; no PR created, because the scripts the job runs could not be trusted"
    assert_line "harness-weekly: ${BRANCH} is already on origin; do not open a PR from it as it is. Find what changed the scripts, then delete the branch (git push origin --delete ${BRANCH})"
    refute_pr_create
}

@test "選別の結果: push に失敗したら、手で公開するコマンドを出して失敗し、worktree・ローカルブランチ・本文を残す" {
    review_fixture
    review_ready
    printf '#!/usr/bin/env bash\nexit 1\n' >"$ORIGIN/hooks/pre-receive"
    chmod +x "$ORIGIN/hooks/pre-receive"
    run harness_publish_review "$BASE"
    assert_failure 1
    assert_line "harness-weekly: push of ${BRANCH} failed; no PR created. To publish by hand: git -C ${REPO} push origin ${BRANCH}, then gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}"
    refute_published
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
    run git -C "$REPO" rev-list --count "origin/main..refs/heads/$BRANCH"
    assert_output 1
}

@test "選別の結果: PR の作成に失敗したら、手で PR を作って URL を記録するコマンドを出して失敗し、判定の記録を置き換えない" {
    review_fixture
    review_ready
    STUB_GH_FAIL=1 run harness_publish_review "$BASE"
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
    review_ready
    printf -- '## [2026-10-03] entry\n\n- **Verdict:** adopted (other run)\n' >"$HDIR/queue-archive.md"
    run harness_publish_review "$BASE"
    assert_success
    assert_line "harness-weekly: no verdict adopted in run \"${BRANCH} run 0f0e\" in $HDIR/queue-archive.md; PR URL not recorded (normal if the PR only fixes stale rules; otherwise the review did not record its verdicts with the settle command)"
    refute_output --partial 'WARN'
}

@test "選別の結果: 判定の記録を PR の URL に置き換えられなければ WARN にとどめ、Rule Ledger の記録まで進む" {
    review_fixture
    # publish だけを失敗させる Verdict の CLI(スナップショットの前に置くので書き換えではない)
    cat >"$HOME/.claude/scripts/harness-verdict.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    review_ready
    STUB_LEDGER_EXPORT=1 run harness_publish_review "$BASE"
    assert_success
    assert_line "harness-weekly: WARN failed to record the PR URL in $HDIR/queue-archive.md; finish_run reports the unpublished verdicts"
    assert_line 'harness-weekly: committed 1 Rule Ledger record(s) to https://github.com/example/dotfiles/pull/42'
}

@test "選別の結果: PR を作った後に実行物が書き換えられたら、片付けたうえで PR を残して失敗する" {
    review_fixture
    review_ready
    STUB_GH_TAMPER="$HOME/.claude/scripts/harness-verdict.sh" run harness_publish_review "$BASE"
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
    review_ready
    STUB_GH_TAMPER="$RATES/2026-10-10.json" run harness_publish_review "$BASE"
    assert_failure 1
    assert_line 'harness-weekly: recorded the PR URL on 1 verdict(s)'
    assert_line 'harness-weekly: opened https://github.com/example/dotfiles/pull/42, but the scripts or records the job uses after it could not be trusted; check the PR and the Rule Ledger by hand'
    assert [ ! -e "$LEDGER_LOG" ]
    assert [ ! -e "$WT" ]
}

@test "選別の結果: PR を作った後に、この run の採用を PR の URL で Rule Ledger に記録・封印し、PR 番号付きで書き出して push し直す" {
    review_fixture
    review_ready
    STUB_LEDGER_RECORD='pr42-aaaaaaaa' STUB_LEDGER_EXPORT=1 run harness_publish_review "$BASE"
    assert_success
    assert_line 'harness-rule-ledger: recorded pr42-aaaaaaaa'
    assert_line 'harness-weekly: committed 1 Rule Ledger record(s) to https://github.com/example/dotfiles/pull/42'
    run cat "$LEDGER_LOG"
    assert_line 'record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly'
    assert_line --regexp '^export --base [0-9a-f]+ --worktree .* --pr 42$'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Rule Ledger の記録を足す' 'harness: add rule')"
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output docs/harness/rule-ledger/pr42-1.json
}

@test "選別の結果: 封印されていない評価の結果は Rule Ledger の記録に渡さない" {
    review_fixture
    review_ready
    printf '{"cases":[]}\n' >"$HDIR/eval-results-2026-10-17.json"
    run harness_publish_review "$BASE"
    assert_success
    run grep '^record ' "$LEDGER_LOG"
    assert_output 'record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly'
}

@test "選別の結果: 封印された評価の結果は Rule Ledger の記録に渡す" {
    review_fixture
    review_ready
    printf '{"cases":[]}\n' >"$HDIR/eval-results-2026-10-17.json"
    harness_integrity_seal "$HDIR/eval-results-2026-10-17.json"
    run harness_publish_review "$BASE"
    assert_success
    run grep '^record ' "$LEDGER_LOG"
    assert_output "record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly --results $HDIR/eval-results-2026-10-17.json"
}

@test "選別の結果: Rule Ledger に記録できなければ、手で記録するコマンドを WARN で出して成功する" {
    review_fixture
    review_ready
    STUB_LEDGER_RECORD_FAIL=1 run harness_publish_review "$BASE"
    assert_success
    assert_line "harness-weekly: WARN failed to record the adoptions of https://github.com/example/dotfiles/pull/42 in the Rule Ledger $HDIR/rule-ledger; record them by hand with bash $HOME/.claude/scripts/harness-rule-ledger.sh record --pr-url https://github.com/example/dotfiles/pull/42 --date 2026-10-17 --via weekly"
}

@test "選別の結果: Rule Ledger の記録を commit できなければ、写しかけを戻して WARN にとどめ、成功する" {
    review_fixture
    review_ready
    STUB_LEDGER_FAIL=1 run harness_publish_review "$BASE"
    assert_success
    assert_line "harness-weekly: WARN failed to commit the Rule Ledger records; they stay in $HDIR/rule-ledger for a later PR"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
}

@test "選別の結果: Rule Ledger の記録の push に失敗しても、PR を残して WARN にとどめ、成功する" {
    review_fixture
    review_ready
    cat >"$ORIGIN/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
    ! git ls-tree -r --name-only "$new" | grep -q '^docs/harness/rule-ledger/' || exit 1
done
HOOK
    chmod +x "$ORIGIN/hooks/pre-receive"
    STUB_LEDGER_EXPORT=1 run harness_publish_review "$BASE"
    assert_success
    assert_line "harness-weekly: WARN push of the Rule Ledger records to ${BRANCH} failed; they stay in $HDIR/rule-ledger for a PR after this one merges"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
    assert [ ! -e "$WT" ]
}

@test "選別の結果: Rule Ledger の記録の commit の後に実行物が書き換えられたら、再 push せずに PR を残して失敗する" {
    review_fixture
    review_ready
    # Rule Ledger の oxfmt(export の後、再 push の前)の最中に実行物を書き換える
    cat >"$STUBS/pnpm" <<'EOF'
#!/usr/bin/env bash
[[ "$*" != 'exec oxfmt docs/harness/rule-ledger' ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-verdict.sh"
EOF
    STUB_LEDGER_EXPORT=1 run harness_publish_review "$BASE"
    assert_failure 1
    assert_line 'harness-weekly: opened https://github.com/example/dotfiles/pull/42, but the scripts or records the job uses after it could not be trusted; check the PR and the Rule Ledger by hand'
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: add rule'
}
