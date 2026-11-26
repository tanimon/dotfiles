#!/usr/bin/env bats
# scripts/check-md-links.mjs のテスト。
#
# 「リンク先が無ければ落とす」ケースと「あれば通す」ケースを対で持つ。片方だけだと、
# 何でも通す(または何でも落とす)検査でも緑になる。

setup() {
    load 'helpers/setup'
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-md-links.mjs"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO/docs/solutions" "$REPO/harness/modules/project" "$REPO/dot_apm"
    git -C "$REPO" init -q
}

# track PATH CONTENT: REPO にファイルを書いて git add する
track() {
    mkdir -p "$(dirname "$REPO/$1")"
    printf '%s\n' "$2" >"$REPO/$1"
    git -C "$REPO" add "$1"
}

@test "相対リンクの先が git 管理下にあれば通る" {
    track docs/solutions/a.md 'see [b](b.md) and [dir](../solutions/) and [top](/docs/solutions/b.md#anchor)'
    track docs/solutions/b.md 'b'
    run node "$SCRIPT" "$REPO"
    assert_success
}

@test "リンク先の文書を消してリンクを残すと、リンク元とリンク先を出して落ちる" {
    track docs/solutions/a.md 'see [b](b.md)'
    track docs/solutions/b.md 'b'
    git -C "$REPO" rm -qf docs/solutions/b.md
    run node "$SCRIPT" "$REPO"
    assert_failure
    assert_output --partial 'docs/solutions/a.md: b.md -> docs/solutions/b.md'
}

@test "harness/modules のリンクはルートから解決し、nested CLAUDE.md に写すとファイルから解決する" {
    track docs/adr/0001-x.md 'adr'
    track harness/modules/project/50-pitfalls.md 'see [adr](docs/adr/0001-x.md)'
    run node "$SCRIPT" "$REPO"
    assert_success

    track dot_apm/CLAUDE.md 'see [adr](docs/adr/0001-x.md)'
    run node "$SCRIPT" "$REPO"
    assert_failure
    assert_output --partial 'dot_apm/CLAUDE.md: docs/adr/0001-x.md -> dot_apm/docs/adr/0001-x.md'
}

@test "URL・アンカーだけのリンク・コードの中のリンクは見ない" {
    track README.md "$(printf '%s\n' '[u](https://example.com/x) [a](#top) `[c](missing.md)`' '```' '[d](missing.md)' '```')"
    run node "$SCRIPT" "$REPO"
    assert_success
}

@test "git 管理下に無いファイルへのリンクは、ファイルが手元にあっても落ちる" {
    track README.md '[local](local.md)'
    printf 'x\n' >"$REPO/local.md"
    run node "$SCRIPT" "$REPO"
    assert_failure
    assert_output --partial 'README.md: local.md -> local.md'
}

@test "リンク先を git rm せずに作業ツリーから消しただけでも落ちる" {
    track docs/solutions/a.md 'see [b](b.md)'
    track docs/solutions/b.md 'b'
    rm "$REPO/docs/solutions/b.md"
    run node "$SCRIPT" "$REPO"
    assert_failure
    assert_output --partial 'docs/solutions/a.md: b.md -> docs/solutions/b.md'
}

@test "括弧を含むパス・<> で囲んだパス・ルートを指すリンク・% を含むパスは、実在すれば通る" {
    track 'docs/foo_(bar).md' 'x'
    track 'docs/a b.md' 'x'
    track 'docs/50%-off.md' 'x'
    track docs/a.md '[p](foo_(bar).md) [s](<a b.md>) [up](../) [top](/) [pct](50%-off.md)'
    run node "$SCRIPT" "$REPO"
    assert_success
}

@test "括弧を含むパス・<> で囲んだパス・% を含むパスも、無ければ落ちる" {
    track docs/a.md '[p](gone_(x).md) [s](<gone b.md>) [pct](99%-gone.md)'
    run node "$SCRIPT" "$REPO"
    assert_failure
    assert_output --partial 'docs/a.md: gone_(x).md -> docs/gone_(x).md'
    assert_output --partial 'docs/a.md: gone b.md -> docs/gone b.md'
    assert_output --partial 'docs/a.md: 99%-gone.md -> docs/99%-gone.md'
}

@test "参照形式の定義のリンク先も見る。脚注の定義は見ない" {
    track docs/a.md "$(printf '%s\n' '[r][ok] [m][gone] [^1]' '' '[ok]: b.md' '[gone]: missing.md' '[^1]: 脚注の本文')"
    track docs/b.md 'b'
    run node "$SCRIPT" "$REPO"
    assert_failure
    assert_output --partial 'docs/a.md: missing.md -> docs/missing.md'
    refute_output --partial 'docs/b.md'
    refute_output --partial '脚注'
}

@test "リストの中でインデントしたコードブロックのリンクは見ない" {
    track README.md "$(printf '%s\n' '- item' '' '  ```sh' '  [x](nope.md)' '  ```')"
    run node "$SCRIPT" "$REPO"
    assert_success
}
