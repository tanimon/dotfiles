# dot_config/zsh/sandbox.zsh の起動関数の検査。
#
# 実物の nono も claude も使わない。どちらも PATH 上のスタブで置き換え、受け取った引数を
# 記録させる。zsh は -f で起動し、このマシンの ~/.zshrc を読ませない。PATH はスタブの
# ディレクトリと /usr/bin:/bin だけにするので、Homebrew の実物の nono は見えない。
setup() {
    load 'helpers/setup'
    load 'helpers/exec-cache'
    SANDBOX_ZSH="$BATS_TEST_DIRNAME/../dot_config/zsh/sandbox.zsh"
    ZSH_BIN=$(command -v zsh) || fail "zsh が見つからない"
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    export ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
    install_exec "$STUBS/claude" <<'EOF'
#!/bin/sh
printf 'claude' >>"$ARGV_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$ARGV_LOG"; done
printf '\n' >>"$ARGV_LOG"
EOF
}

install_nono_stub() {
    install_exec "$STUBS/nono" <<'EOF'
#!/bin/sh
printf 'nono' >>"$ARGV_LOG"
for a in "$@"; do printf ' %s' "$a" >>"$ARGV_LOG"; done
printf '\n' >>"$ARGV_LOG"
EOF
}

# run_zsh SNIPPET: sandbox.zsh を source した zsh で SNIPPET を実行する
run_zsh() {
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="$STUBS:/usr/bin:/bin" ARGV_LOG="$ARGV_LOG" \
        "$ZSH_BIN" -f -c "source '$SANDBOX_ZSH'; $1"
}

@test "claude は関数ではなく PATH 上の実行ファイルに解決される" {
    install_nono_stub
    run_zsh 'whence -w claude; claude --version'
    assert_success
    assert_line 'claude: command'
    run cat "$ARGV_LOG"
    assert_output 'claude --version'
}

@test "claude-nono は nono の内側で、入れ子のサンドボックスを切った claude を起動する" {
    install_nono_stub
    run_zsh 'claude-nono --resume abc'
    assert_success
    run cat "$ARGV_LOG"
    assert_output "nono run --profile claude-seal --allow-cwd -- claude --settings {\"sandbox\":{\"enabled\":false}} --dangerously-skip-permissions --resume abc"
}

@test "nono が無いとき claude-nono は素の claude に落ちずに失敗する" {
    # 関数が無いことによる 127 で通らないよう、定義されていることを先に確かめる
    run_zsh 'whence -w claude-nono && claude-nono --version'
    assert_failure 1
    assert_line 'claude-nono: function'
    assert_output --partial 'nono が見つからない'
    [ ! -e "$ARGV_LOG" ]
}
