# 週次ジョブの公開の module(lib/harness-publish.bash)の interface の検査。lib を直接 source する。
# 週次ジョブがこの lib を読み込めないときに止まることと、各案内文が綴りを使う配線は test/harness-weekly.bats が検査する。
setup() {
    load 'helpers/setup'
    LIB="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-publish.bash"
    REPO_ROOT="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.claude/scripts"
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
        --pr-body /h/review-pr-body-2026-10-17.md --review-result /h/review-result-2026-10-17.json \
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
        --pr-body /h/review-pr-body-2026-10-17.md --review-result /h/review-result-2026-10-17.json \
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
