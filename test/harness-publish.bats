# 週次ジョブの公開の module(lib/harness-publish.bash)の interface の検査。lib を直接 source する。
# 週次ジョブがこの lib を読み込めないときに止まることと、各案内文が綴りを使う配線、Metrics-only PR を開く配線は
# test/harness-weekly.bats が検査する。
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

@test "再発率の記録の置き場・Metrics-only PR を作る週数・署名用の git 設定を定数で持つ" {
    assert_equal "$HARNESS_PUBLISH_RATES_REPO_DIR" docs/harness/failure-pattern-rates
    assert_equal "$HARNESS_PUBLISH_METRICS_ONLY_WEEKS" 4
    assert_equal "$HARNESS_PUBLISH_AGENT_GIT_CONFIG" "$HOME/.config/git/claude-code.inc"
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

# 以下は Metrics-only PR の要否の判定・公開・片付けの検査。git は実物を使い、origin は使い捨ての bare リポジトリにする。
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

# 週次ジョブが渡す、本文に節を足す関数の代わり。SECTIONS_FAIL で失敗し、SECTIONS_TAMPER があれば足した後に
# Rule Ledger のスクリプトを書き換える(節を書いた後で push の前に実行物が書き換えられた run の再現)
sections() {
    printf '\n## 推移\n' >>"$BODY"
    [[ -z "${SECTIONS_TAMPER:-}" ]] || printf '# tampered\n' >>"$HOME/.claude/scripts/harness-rule-ledger.sh"
    [[ -z "${SECTIONS_FAIL:-}" ]]
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

@test "Metrics-only PR: 記録を commit して push し、件数の文の後に週次ジョブの節を載せた draft PR を作って片付ける" {
    publish_fixture
    four_local_records
    merged_record 2026-09-26
    local_record 2026-09-19
    make_worktree
    init_real
    printf 'claude が書いた本文\n' >"$BODY"
    run harness_publish_metrics_only "$BASE" sections
    assert_success
    assert_line 'harness-weekly: opened metrics-only draft PR https://github.com/example/dotfiles/pull/42 (4 weekly record(s))'
    run grep '^pr create' "$GH_LOG"
    assert_output "pr create --draft --base main --head ${BRANCH} --title harness: 週次の指標 2026-10-17 --body-file ${BODY}"
    run cat "$GH_BODY"
    assert_output "$(printf '%s\n' '採用した変更は無い。origin/main に無い週の Failure Pattern の再発率の記録が 4 週分たまったので、記録だけを commit した。' '' '## 推移')"
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

@test "Metrics-only PR: 持ち越した Rule Ledger の記録を PR を作る前に commit し、件数の文に続けて本文に書く" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_LEDGER_EXPORT=2 run harness_publish_metrics_only "$BASE" sections
    assert_success
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output "$(printf '%s\n' 'harness: Rule Ledger の記録を足す' 'harness: Failure Pattern の再発率の週の記録を足す')"
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output "$(printf 'docs/harness/rule-ledger/%s.json\n' pr30-1 pr30-2)"
    run sed -n 3p "$GH_BODY"
    assert_output 'マージ済みの PR の Rule Ledger の記録のうち、まだ載っていなかった 2 件も足した(docs/harness/rule-ledger)。'
    run tail -n 1 "$GH_BODY"
    assert_output '## 推移'
}

@test "Metrics-only PR: 再発率の記録を commit できなければ、PR を作らずに失敗する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_PNPM_FAIL=1 run harness_publish_metrics_only "$BASE" sections
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
    run harness_publish_metrics_only "$BASE" sections
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
    run harness_publish_metrics_only "$BASE" sections
    assert_failure 1
    assert_line 'harness-weekly: the Rule Ledger records could not be trusted; no PR created'
    refute_published
}

@test "Metrics-only PR: Rule Ledger の記録を commit できなければ、写しかけを戻して記録だけの PR を作る" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    STUB_LEDGER_FAIL=1 run harness_publish_metrics_only "$BASE" sections
    assert_success
    assert_line "harness-weekly: WARN failed to commit the Rule Ledger records; they stay in $HDIR/rule-ledger for a later PR"
    run git -C "$ORIGIN" log --format=%s "main..$BRANCH"
    assert_output 'harness: Failure Pattern の再発率の週の記録を足す'
    run git -C "$ORIGIN" diff --name-only "main..$BRANCH" -- docs/harness/rule-ledger
    assert_output ''
    run cat "$GH_BODY"
    refute_output --partial 'Rule Ledger'
}

@test "Metrics-only PR: 本文の節を足せなければ、push も PR の作成もせずに失敗する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    SECTIONS_FAIL=1 run harness_publish_metrics_only "$BASE" sections
    assert_failure 1
    refute_published
}

@test "Metrics-only PR: 節を書いた後に実行物が書き換えられたら、push の直前の関門で止まる" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    SECTIONS_TAMPER=1 run harness_publish_metrics_only "$BASE" sections
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
    run harness_publish_metrics_only "$BASE" sections
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
    run harness_publish_metrics_only "$BASE" sections
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
    STUB_GH_FAIL=1 run harness_publish_metrics_only "$BASE" sections
    assert_failure 1
    assert_line "harness-weekly: pushed ${BRANCH} but gh pr create failed; open the PR by hand with gh pr create --draft --base main --head ${BRANCH} --body-file ${BODY}"
    run git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
    assert [ -d "$WT" ]
    assert [ -s "$BODY" ]
    run git -C "$REPO" rev-parse --verify --quiet "refs/heads/$BRANCH"
    assert_success
}

@test "Metrics-only PR: 本文の節を足す関数を渡さなければ、何もせずに失敗する" {
    publish_fixture
    four_local_records
    make_worktree
    init_real
    run harness_publish_metrics_only "$BASE" no_such_function
    assert_failure 1
    assert_output --partial 'harness-publish:'
    run git -C "$WT" rev-list --count "$BASE..HEAD"
    assert_output 0
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
