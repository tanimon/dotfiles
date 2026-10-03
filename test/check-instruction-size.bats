#!/usr/bin/env bats

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-instruction-size.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q -b main
    # 既定値は 3 行 / 20 バイト。個別の上限は 5 行 / 40 バイト
    put scripts/instruction-size-limits.txt $'# コメント行\n\n* 3 20\nCLAUDE.md 5 40'
    lines CLAUDE.md 1
}

put() {
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s\n' "$2" >"$REPO/$1"
    git -C "$REPO" add -- "$1"
}

# n 行・各行 1 バイト + 改行 = 2n バイトのファイルを作る
lines() {
    local i content=''
    for ((i = 1; i <= $2; i++)); do
        content+="x"$'\n'
    done
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s' "$content" >"$REPO/$1"
    git -C "$REPO" add -- "$1"
}

check() {
    (cd "$REPO" && bash "$SCRIPT")
}

@test "上限内のファイルは通る" {
    lines .claude/rules/a.md 2
    run check
    assert_success
}

@test "行数が上限ちょうどのファイルは通る" {
    lines .claude/rules/a.md 3
    run check
    assert_success
}

@test "行数が上限を超えたら落ち、ファイル名と超過量を表示する" {
    lines .claude/rules/a.md 4
    run check
    assert_failure 1
    assert_output --partial '.claude/rules/a.md: 4 行(上限 3、+1 行)'
}

@test "末尾に改行の無い最終行も 1 行と数える" {
    mkdir -p "$REPO/.claude/rules"
    printf 'x\nx\nx\nx' >"$REPO/.claude/rules/a.md"
    git -C "$REPO" add -- .claude/rules/a.md
    run check
    assert_failure 1
    assert_output --partial '.claude/rules/a.md: 4 行(上限 3、+1 行)'
}

@test "バイト数が上限ちょうどのファイルは通る" {
    put dot_claude/rules/common/a.md '0123456789012345678'
    run check
    assert_success
}

@test "バイト数が上限を超えたら落ち、ファイル名と超過量を表示する" {
    put dot_claude/rules/common/a.md '01234567890123456789'
    run check
    assert_failure 1
    assert_output --partial 'dot_claude/rules/common/a.md: 21 バイト(上限 20、+1 バイト)'
}

@test "個別の上限は既定値より優先される" {
    lines CLAUDE.md 5
    run check
    assert_success
    lines CLAUDE.md 6
    run check
    assert_failure 1
    assert_output --partial 'CLAUDE.md: 6 行(上限 5、+1 行)'
}

@test "違反はすべて表示してから落ちる" {
    lines .claude/rules/a.md 4
    lines dot_config/x/CLAUDE.md 4
    run check
    assert_failure 1
    assert_output --partial '.claude/rules/a.md: 4 行'
    assert_output --partial 'dot_config/x/CLAUDE.md: 4 行'
}

@test "対象はルールと指示のファイルだけで、それ以外は大きくても判定しない" {
    lines docs/long.md 10
    lines .claude/rules/sub/not-loaded.txt 10
    run check
    assert_success
}

@test "git に追加していない新しいルールも判定する" {
    mkdir -p "$REPO/.claude/rules"
    printf 'x\nx\nx\nx\n' >"$REPO/.claude/rules/new.md"
    run check
    assert_failure 1
    assert_output --partial '.claude/rules/new.md: 4 行'
}

@test "作業ツリーから消したファイルは判定しない" {
    lines .claude/rules/a.md 4
    rm "$REPO/.claude/rules/a.md"
    run check
    assert_success
}

@test "上限の一覧に対象のファイルとして存在しないパスがあれば落ちる" {
    lines docs/long.md 10
    put scripts/instruction-size-limits.txt $'* 3 20\nCLAUDE.md 5 40\ndocs/long.md 100 1000'
    run check
    assert_failure 2
    assert_output --partial 'docs/long.md'
}

@test "既定値の行が無ければ落ちる" {
    put scripts/instruction-size-limits.txt 'CLAUDE.md 5 40'
    run check
    assert_failure 2
}

@test "数値でない上限があれば落ちる" {
    put scripts/instruction-size-limits.txt $'* 3 20\nCLAUDE.md 5 forty'
    run check
    assert_failure 2
    assert_output --partial 'CLAUDE.md 5 forty'
}
