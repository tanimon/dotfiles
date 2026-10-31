#!/usr/bin/env bats
# 描画の module(scripts/chezmoi-render.bash)のテスト。
#
# 観測は module の interface と外から見えるものだけで行う: 描画結果・終了コード・エラーの出力・
# 初期化に渡した作業ディレクトリの中身・PATH に置いた偽の chezmoi が記録した引数。module の内部の変数は読まない。
# chezmoi が無いと初期化が失敗するので、このファイルのケースは chezmoi が無い環境では skip せず fail する
# (chezmoi が無いときの失敗を見るケースは除く)。

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    MODULE="${BATS_TEST_DIRNAME}/../scripts/chezmoi-render.bash"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
}

@test "render_template の描画は、リポジトリそのものではなく作業ディレクトリの中の写しを source にする" {
    # shellcheck source=scripts/chezmoi-render.bash
    source "$MODULE"
    render_init "$WORK"
    printf '{{ .chezmoi.sourceDir }}' >"$BATS_TEST_TMPDIR/source-dir.tmpl"
    run render_template personal "$BATS_TEST_TMPDIR/source-dir.tmpl"
    assert_success
    local work
    work=$(cd "$WORK" && pwd -P)
    case "$output/" in
    "$work"/*) ;;
    *) fail "描画の source が作業ディレクトリの中に無い: $output" ;;
    esac
}

@test "render_template は指定した Machine Profile の fixture で描画し、PATH を狭めても chezmoi を見失わない" {
    # shellcheck source=scripts/chezmoi-render.bash
    source "$MODULE"
    render_init "$WORK"
    printf '{{ .profile }}' >"$BATS_TEST_TMPDIR/profile.tmpl"
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    PATH="$BATS_TEST_TMPDIR/empty" run render_template work "$BATS_TEST_TMPDIR/profile.tmpl"
    assert_success
    assert_output work
}

# 未知の profile を空の描画結果で成功させない(空の結果に対する後続の grep が空振りするため)
@test "render_template は存在しない Machine Profile と省略した Machine Profile で失敗する" {
    # shellcheck source=scripts/chezmoi-render.bash
    source "$MODULE"
    render_init "$WORK"

    run render_template staging "$RENDER_REPO/dot_gitconfig.tmpl"
    assert_failure
    assert_output --partial "profile 'staging'"

    run render_template '' "$RENDER_REPO/dot_gitconfig.tmpl"
    assert_failure
}

@test "render_chezmoi は、その Machine Profile の fixture と作業ディレクトリの中の写しを付けて chezmoi を走らせる" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/chezmoi" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$CHEZMOI_ARGS"
FAKE
    chmod +x "$BATS_TEST_TMPDIR/bin/chezmoi"
    export CHEZMOI_ARGS="$BATS_TEST_TMPDIR/args"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    # shellcheck source=scripts/chezmoi-render.bash
    source "$MODULE"
    render_init "$WORK"
    run render_chezmoi work source-path --destination /home "/home/.claude/x"
    assert_success
    local arg args=()
    while IFS= read -r arg; do
        args+=("$arg")
    done <"$CHEZMOI_ARGS"
    assert_equal "${#args[@]}" 8
    assert_equal "${args[0]}" --config
    assert_equal "${args[1]}" "$RENDER_REPO/test/fixtures/chezmoi-work.toml"
    assert_equal "${args[2]}" --source
    assert_equal "${args[*]:4}" "source-path --destination /home /home/.claude/x"
    # source は作業ディレクトリの中の、リポジトリの写し
    local work
    work=$(cd "$WORK" && pwd -P)
    case "${args[3]}/" in
    "$work"/*) ;;
    *) fail "chezmoi に渡した source が作業ディレクトリの中に無い: ${args[3]}" ;;
    esac
    [ -f "${args[3]}/scripts/chezmoi-render.bash" ] || fail "chezmoi に渡した source がリポジトリの写しではない: ${args[3]}"
}

@test "chezmoi が無いと render_init は失敗し、写しを作らない" {
    mkdir -p "$BATS_TEST_TMPDIR/empty"
    run bash -c 'source "$1" && PATH="$2" && render_init "$3"' _ "$MODULE" "$BATS_TEST_TMPDIR/empty" "$WORK"
    assert_failure
    assert_output --partial 'chezmoi が必要'
    run ls -A "$WORK"
    assert_output ''
}

@test "render_init を同じ作業ディレクトリで並行して呼んでも、写しは 1 つだけで中に余計な項目が入らない" {
    # 並列の test は同じ作業ディレクトリ(bats では BATS_RUN_TMPDIR)で写しを作り合う。後から来た呼び出しが
    # 写しの中に link を作ると、chezmoi が辿る source に余計な項目が混ざる
    local i pid pids=()
    for i in 1 2 3 4 5 6; do
        (
            # shellcheck source=scripts/chezmoi-render.bash
            source "$MODULE"
            render_init "$WORK"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || fail "render_init が失敗した"
    done
    [ -L "$WORK/chezmoi-source" ] || fail "共有の写しが無い"
    run bash -c 'ls -A "$1" | grep -c "^chezmoi-source\."' _ "$WORK"
    assert_output 1
    run bash -c 'ls -A "$1/chezmoi-source/" | grep "^chezmoi-source"' _ "$WORK"
    assert_output ''
}

# fixture の置き場所を interface の引数にしない(module はリポジトリのルートを自分の位置から決める)ので、
# module だけを写した一時リポジトリで fixture の有無を作る
@test "render_profiles は fixture の実ファイルの Machine Profile を 1 行ずつ出し、0 件なら失敗する" {
    local repo="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$repo/scripts" "$repo/test/fixtures"
    cp "$MODULE" "$repo/scripts/"
    run bash -c 'source "$1" && render_profiles' _ "$repo/scripts/chezmoi-render.bash"
    assert_failure
    assert_output --partial 'fixture'

    : >"$repo/test/fixtures/chezmoi-beta.toml"
    : >"$repo/test/fixtures/chezmoi-alpha.toml"
    : >"$repo/test/fixtures/other.toml"
    run --separate-stderr bash -c 'source "$1" && render_profiles' _ "$repo/scripts/chezmoi-render.bash"
    assert_success
    assert_output $'alpha\nbeta'
}
