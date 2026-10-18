#!/usr/bin/env bats
# scripts/chezmoi-source-snapshot.sh と、それを --source に使う描画の seam(test/helpers/render.bash)のテスト。
#
# 各ケースは $BATS_TEST_TMPDIR に使い捨ての git リポジトリを組む。GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を潰すのは、このマシンの ~/.gitconfig の commit 署名を引き継ぐと
# 「スクリプトの挙動」ではなく「署名鍵が使えるか」で結果が変わるため。
#
# 一時ファイルを作っては消すループ(churn)は、並列に走る別のレシピの pnpm が
# リポジトリに作る一時ファイルの代わり。生きたリポジトリでは回さない: 並列の lint の
# secretlint や scan-sensitive も、リポジトリを辿るので同じ競合で落ちうる。
# そのため seam のケースは、競合を起こす代わりに描画の source がリポジトリの外にあることを見る。

setup() {
    load 'helpers/setup'
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/chezmoi-source-snapshot.sh"

    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null
    : >"$GIT_CONFIG_GLOBAL"

    REPO="$BATS_TEST_TMPDIR/repo"
    DEST="$BATS_TEST_TMPDIR/snapshot"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    git -C "$REPO" config user.email test@example.com
    git -C "$REPO" config user.name test
    printf 'node_modules/\n' >"$REPO/.gitignore"
    printf 'committed\n' >"$REPO/tracked.txt"
    printf '#!/bin/sh\n' >"$REPO/run.sh"
    chmod +x "$REPO/run.sh"
    mkdir -p "$REPO/dir"
    printf 'nested\n' >"$REPO/dir/nested.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m init
    CHURN_PIDS=()
}

teardown() {
    local pid
    for pid in ${CHURN_PIDS[@]+"${CHURN_PIDS[@]}"}; do
        kill "$pid" 2>/dev/null || true
    done
}

# start_churn DIR: DIR に一時ファイルを作っては消すループを 2 本、背景で回す
start_churn() {
    local dir=$1 i
    for i in 1 2; do
        (while :; do
            f="$dir/_tmp_$RANDOM$RANDOM"
            : >"$f"
            rm -f "$f"
        done) &
        CHURN_PIDS+=("$!")
        disown "$!"
    done
}

# list_non_snapshot_sources REPO: REPO の justfile と test/ で、chezmoi の source(--source / -S)に
# 写し以外を渡している行を出す。写しとして許すのは、どのファイルでも render.bash の RENDER_SOURCE、
# justfile では check-templates の snapshot、このファイルでは DEST だけ
list_non_snapshot_sources() {
    cd "$1" || return 1
    grep -nE -- '--source[ =]|(^|[[:space:]])-S[ =]*["$./~]' justfile test/*.bats test/helpers/*.bash |
        grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
        grep -vE -- '(--source|-S)[ =]*"\$RENDER_SOURCE"' |
        grep -vE -- '^justfile:[0-9]+:.*(--source|-S)[ =]*"\$snapshot"' |
        grep -vE -- '^test/chezmoi-source-snapshot\.bats:[0-9]+:.*(--source|-S)[ =]*"\$DEST"'
}

@test "作業ツリーの内容を写す(commit していない編集と、無視されていない未追跡ファイルを含む)" {
    printf 'edited\n' >"$REPO/tracked.txt"
    printf 'new\n' >"$REPO/untracked.txt"
    run bash "$SCRIPT" "$REPO" "$DEST"
    assert_success
    assert_equal "$(cat "$DEST/tracked.txt")" edited
    assert_equal "$(cat "$DEST/untracked.txt")" new
    assert_equal "$(cat "$DEST/dir/nested.txt")" nested
}

@test "実行権限を保つ" {
    run bash "$SCRIPT" "$REPO" "$DEST"
    assert_success
    [ -x "$DEST/run.sh" ]
}

@test ".git と .gitignore されたものは写さない" {
    mkdir -p "$REPO/node_modules/.pnpm"
    : >"$REPO/node_modules/.pnpm/lock.yaml"
    run bash "$SCRIPT" "$REPO" "$DEST"
    assert_success
    [ ! -e "$DEST/.git" ]
    [ ! -e "$DEST/node_modules" ]
    [ -f "$DEST/.gitignore" ]
}

@test "作業ツリーで削除した追跡ファイルは写さず、失敗もしない" {
    rm "$REPO/tracked.txt"
    run bash "$SCRIPT" "$REPO" "$DEST"
    assert_success
    [ ! -e "$DEST/tracked.txt" ]
    assert_equal "$(cat "$DEST/dir/nested.txt")" nested
}

@test "写している間にリポジトリで一時ファイルが作られては消えても失敗しない" {
    start_churn "$REPO"
    local i
    for i in $(seq 20); do
        rm -rf "$DEST"
        run bash "$SCRIPT" "$REPO" "$DEST"
        assert_success
        assert_equal "$(cat "$DEST/dir/nested.txt")" nested
    done
}

@test "写しを source にした描画は、リポジトリで一時ファイルが作られては消えても落ちない" {
    command -v chezmoi >/dev/null || fail "chezmoi が必要(skip しない)"
    # chezmoi が一覧を取ってから lstat するまでの間を広げるため、churn の先客を多く置く。
    # この数があれば、写しではなくリポジトリを直接 source に渡すとほぼ毎回落ちる(実測)
    local i
    for i in $(seq 3000); do
        : >"$REPO/dir/a.$i"
    done
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m many
    run bash "$SCRIPT" "$REPO" "$DEST"
    assert_success
    : >"$BATS_TEST_TMPDIR/chezmoi.toml"
    start_churn "$REPO/dir"
    for i in $(seq 10); do
        run chezmoi execute-template --config "$BATS_TEST_TMPDIR/chezmoi.toml" --source "$DEST" '{{ .chezmoi.sourceDir }}'
        assert_success
        assert_output "$DEST"
    done
}

@test "render_template の描画は、リポジトリそのものではなくリポジトリの外の写しを source にする" {
    load 'helpers/render'
    printf '{{ .chezmoi.sourceDir }}' >"$BATS_TEST_TMPDIR/source-dir.tmpl"
    run render_template personal "$BATS_TEST_TMPDIR/source-dir.tmpl"
    assert_success
    local repo
    repo=$(cd "$RENDER_REPO" && pwd -P)
    case "$output/" in
    "$repo"/*) fail "描画の source がリポジトリの中にある: $output" ;;
    esac
}

@test "lint で chezmoi に source state を読ませる箇所は、source に写しを指定する" {
    # リポジトリそのものを渡すと、並列のレシピの一時ファイルで落ちる競合が戻る
    # (scripts/chezmoi-source-snapshot.sh)
    run list_non_snapshot_sources "${BATS_TEST_DIRNAME}/.."
    assert_output ''
}

@test "render.bash を並行して読み込んでも、写しは 1 つだけで中に余計な項目が入らない" {
    # 並列の test は同じ BATS_RUN_TMPDIR で写しを作り合う。後から来た test が写しの中に
    # link を作ると、chezmoi が辿る source に余計な項目が混ざる
    local run_dir="$BATS_TEST_TMPDIR/run" i pid pids=()
    mkdir -p "$run_dir"
    for i in 1 2 3 4 5 6; do
        (
            BATS_RUN_TMPDIR=$run_dir
            # shellcheck source=test/helpers/render.bash
            source "${BATS_TEST_DIRNAME}/helpers/render.bash"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || fail "render.bash の読み込みが失敗した"
    done
    [ -L "$run_dir/chezmoi-source" ] || fail "共有の写しが無い"
    run bash -c 'ls -A "$1" | grep -c "^chezmoi-source\."' _ "$run_dir"
    assert_output 1
    run bash -c 'ls -A "$1/chezmoi-source/" | grep "^chezmoi-source"' _ "$run_dir"
    assert_output ''
}
