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
    install_stub claude
}

# install_stub NAME: 自分の名前と受け取った引数を 1 行で ARGV_LOG に追記するスタブを置く。
# 引数は 1 つずつ [] で囲み、空白を含む引数や空の引数の境界がログに残るようにする
install_stub() {
    install_exec "$STUBS/$1" <<'EOF'
#!/bin/sh
printf '%s' "$(basename "$0")" >>"$ARGV_LOG"
for a in "$@"; do printf ' [%s]' "$a" >>"$ARGV_LOG"; done
printf '\n' >>"$ARGV_LOG"
EOF
}

# run_zsh SNIPPET: sandbox.zsh を source した zsh で SNIPPET を実行する
run_zsh() {
    run env -i HOME="$BATS_TEST_TMPDIR" PATH="$STUBS:/usr/bin:/bin" ARGV_LOG="$ARGV_LOG" \
        "$ZSH_BIN" -f -c "source '$SANDBOX_ZSH'; $1"
}

@test "claude は関数ではなく PATH 上の実行ファイルに解決される" {
    # nono があっても素の claude が nono を経由しないことを見るため、nono も置く
    install_stub nono
    run_zsh 'whence -w claude; claude --version'
    assert_success
    assert_line 'claude: command'
    run cat "$ARGV_LOG"
    assert_output 'claude [--version]'
}

@test "claude-nono は nono の内側で、入れ子のサンドボックスを切った claude を起動する" {
    install_stub nono
    # 空白を含む引数と空の引数を混ぜ、引数が分割も結合もされずに渡ることを見る
    run_zsh "claude-nono 'fix the bug' ''"
    assert_success
    run cat "$ARGV_LOG"
    assert_output 'nono [run] [--profile] [claude-seal] [--allow-cwd] [--] [claude] [--settings] [{"sandbox":{"enabled":false}}] [--dangerously-skip-permissions] [fix the bug] []'
}

@test "nono が無いとき claude-nono は素の claude に落ちずに失敗する" {
    # 関数が無いことによる 127 で通らないよう、定義されていることを先に確かめる
    run_zsh 'whence -w claude-nono && claude-nono --version'
    assert_failure 1
    assert_line 'claude-nono: function'
    assert_output --partial 'nono が見つからない'
    [ ! -e "$ARGV_LOG" ]
}
