# ticket スキルとガードの適用範囲(origin の owner の許可リスト)の判定。
setup() {
    load 'helpers/setup'
    LIB="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/ticket-scope.bash"
    unset TICKET_GUARD_OWNERS
    REPO_DIR="$BATS_TEST_TMPDIR/repo"
    git init -q "$REPO_DIR"
}

set_origin() {
    git -C "$REPO_DIR" remote add origin "$1"
}

@test "許可リストの owner の https origin は範囲内" {
    set_origin https://github.com/tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "許可リストの owner の ssh origin は範囲内" {
    set_origin git@github.com:tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "owner の大文字小文字は区別しない" {
    set_origin https://github.com/Tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "許可リストに無い owner は範囲外" {
    set_origin https://github.com/someone-else/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "origin が無いリポジトリは範囲外" {
    run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "GitHub 以外の origin は範囲外" {
    set_origin https://gitlab.com/tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "git リポジトリでないディレクトリは範囲外" {
    run bash "$LIB" "$BATS_TEST_TMPDIR"
    assert_failure
}

@test "repo 引数があれば origin より優先する(範囲外の指定)" {
    set_origin https://github.com/tanimon/sample.git
    run bash "$LIB" "$REPO_DIR" someone-else/sample
    assert_failure
}

@test "repo 引数があれば origin より優先する(範囲内の指定)" {
    set_origin https://github.com/someone-else/sample.git
    run bash "$LIB" "$REPO_DIR" https://github.com/tanimon/sample
    assert_success
}

@test "TICKET_GUARD_OWNERS で許可リストを上書きできる" {
    set_origin https://github.com/someone-else/sample.git
    TICKET_GUARD_OWNERS="other someone-else" run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "TICKET_GUARD_OWNERS を空にするとすべて範囲外" {
    set_origin https://github.com/tanimon/sample.git
    TICKET_GUARD_OWNERS="" run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "source して関数として呼べる" {
    set_origin https://github.com/tanimon/sample.git
    run bash -c 'source "$1" && ticket_scope_in_scope "$2"' _ "$LIB" "$REPO_DIR"
    assert_success
}
