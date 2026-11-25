# dot_config/zsh/claude-code.zsh の検査。
#
# Claude Code の Bash ツールで実際に失敗した bash の書き方のコマンドを、CLAUDECODE を立てた zsh と
# 立てない zsh で流し、前者では bash と同じに通り、後者(人の対話シェル)では zsh の既定のまま止まることを見る。
# zsh は -f で起動し、このマシンの ~/.zshrc を読ませない。
setup() {
    load 'helpers/setup'
    CLAUDE_CODE_ZSH="$BATS_TEST_DIRNAME/../dot_config/zsh/claude-code.zsh"
    ZSH_BIN=$(command -v zsh) || fail "zsh が見つからない"
    cd "$BATS_TEST_TMPDIR"
}

# run_zsh CLAUDECODE SNIPPET: claude-code.zsh を source した zsh で SNIPPET を実行する。CLAUDECODE が空なら立てない
run_zsh() {
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="/usr/bin:/bin" CLAUDECODE="$1" \
        "$ZSH_BIN" -f -c "source '$CLAUDE_CODE_ZSH'; $2"
}

@test "Claude Code の内側では、コマンドを入れた文字列変数をクォートせずに実行できる" {
    run_zsh 1 'G="printf %s- a b"; $G'
    assert_success
    assert_output 'a-b-'
}

@test "Claude Code の内側では、一致しない glob を含む引数がそのまま渡る" {
    run_zsh 1 'printf "%s\n" --include=*.vue https://x.example/?a=1'
    assert_success
    assert_line --index 0 '--include=*.vue'
    assert_line --index 1 'https://x.example/?a=1'
}

@test "Claude Code の内側では、=cmd 展開と波括弧の無い修飾子が効かない" {
    run_zsh 1 'H=/h; arr=(x y); echo === "$H:scripts" "${arr[0]}"'
    assert_success
    assert_output '=== /h:scripts x'
}

@test "Claude Code の外では zsh の既定のまま変えない" {
    run_zsh '' 'G="printf %s- a b"; $G; echo "rc=$?"'
    assert_output --partial 'rc=127'
    run_zsh '' 'printf "%s\n" --include=*.vue'
    assert_failure
    assert_output --partial 'no matches found'
}
