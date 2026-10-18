#!/usr/bin/env bats

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-instruction-size-merged.sh"
    ORIGIN="$BATS_TEST_TMPDIR/origin.git"
    REPO="$BATS_TEST_TMPDIR/repo"
    OTHER="$BATS_TEST_TMPDIR/other"
    git init -q --bare -b main "$ORIGIN"
    git clone -q "$ORIGIN" "$REPO" 2>/dev/null
    configure "$REPO"
    # 測る側のスクリプトはマージ後の tree から呼ばれるので、fixture にも置く
    mkdir -p "$REPO/scripts"
    cp "$BATS_TEST_DIRNAME/../scripts/check-instruction-size.sh" "$REPO/scripts/"
    # CLAUDE.md は 10 行 / 40 バイトまで。ブランチと基準が離れた行を変えれば衝突しない
    put "$REPO" scripts/instruction-size-limits.txt $'* 3 20\nCLAUDE.md 10 40'
    put "$REPO" CLAUDE.md $'a\nm\nm\nz'
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m base
    git -C "$REPO" push -q origin main
    git -C "$REPO" switch -q -c feature
    git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
    configure "$OTHER"
    unset INSTRUCTION_SIZE_SKIP_FETCH
}

configure() {
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name t
    git -C "$1" config commit.gpgsign false
}

put() {
    mkdir -p "$1/$(dirname "$2")"
    printf '%s\n' "$3" >"$1/$2"
}

# ブランチ側で 1 行目を伸ばす(CLAUDE.md は 8 → 25 バイト)
branch_grows() {
    put "$REPO" CLAUDE.md $'aaaaaaaaaaaaaaaaaa\nm\nm\nz'
    git -C "$REPO" commit -q -am grow
}

# 基準(リモートの main)側で 4 行目を伸ばす。手元の origin/main は fetch するまで古いまま
base_grows() {
    put "$OTHER" CLAUDE.md $'a\nm\nm\nzzzzzzzzzzzzzzzzzz'
    git -C "$OTHER" commit -q -am grow
    git -C "$OTHER" push -q origin main
}

check() {
    (cd "$REPO" && bash scripts/check-instruction-size.sh)
}

merged() {
    (cd "$REPO" && bash "$SCRIPT" "$@")
}

@test "ブランチ単体は上限内でも、リモートの基準とマージした結果が上限を超えたら落ちる" {
    branch_grows
    base_grows
    run check
    assert_success
    run merged
    assert_failure 1
    assert_output --partial 'CLAUDE.md: 42 バイト(上限 40、+2 バイト)'
    assert_output --partial 'origin/main とマージした結果で上限を超える'
}

@test "基準が進んでいなければ通る" {
    branch_grows
    run merged
    assert_success
}

@test "fetch を飛ばすと手元の古い基準と比べ、飛ばしたことを出す" {
    branch_grows
    base_grows
    INSTRUCTION_SIZE_SKIP_FETCH=1 run merged
    assert_success
    assert_output --partial 'fetch を飛ばした'
}

@test "fetch に失敗しても手元の基準で測り、失敗を出す" {
    branch_grows
    git -C "$REPO" remote set-url origin "$BATS_TEST_TMPDIR/missing.git"
    run merged
    assert_success
    assert_output --partial 'fetch できなかった'
}

@test "マージ後の上限の一覧で測る" {
    branch_grows
    put "$OTHER" scripts/instruction-size-limits.txt $'* 3 20\nCLAUDE.md 10 50'
    put "$OTHER" CLAUDE.md $'a\nm\nm\nzzzzzzzzzzzzzzzzzz'
    git -C "$OTHER" commit -q -am raise
    git -C "$OTHER" push -q origin main
    run merged
    assert_success
}

@test "commit していない変更は測らない" {
    branch_grows
    put "$REPO" CLAUDE.md "$(printf 'x%.0s' {1..60})"
    run merged
    assert_success
}

@test "マージが衝突したら exit 2 にする" {
    put "$REPO" CLAUDE.md $'a\nm\nm\nbranch'
    git -C "$REPO" commit -q -am branch
    put "$OTHER" CLAUDE.md $'a\nm\nm\nbase'
    git -C "$OTHER" commit -q -am base
    git -C "$OTHER" push -q origin main
    run merged
    assert_failure 2
    assert_output --partial 'マージが衝突する'
}

@test "基準を解決できなければ exit 2 にする" {
    run merged no-such-ref
    assert_failure 2
    assert_output --partial '基準を解決できない: no-such-ref'
}
