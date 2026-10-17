#!/usr/bin/env bats
# scripts/chezmoi-source-snapshot.sh のテスト。
#
# 各ケースは $BATS_TEST_TMPDIR に使い捨ての git リポジトリを組む。GIT_CONFIG_GLOBAL /
# GIT_CONFIG_SYSTEM を潰すのは、このマシンの ~/.gitconfig の commit 署名を引き継ぐと
# 「スクリプトの挙動」ではなく「署名鍵が使えるか」で結果が変わるため。
#
# 一時ファイルを作っては消すループ(churn)は、並列に走る別のレシピの pnpm が
# リポジトリに作る一時ファイルの代わり。生きたリポジトリでは回さない: 並列の lint の
# secretlint や scan-sensitive が同じ競合で落ちる。

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
