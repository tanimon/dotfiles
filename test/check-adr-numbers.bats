#!/usr/bin/env bats
# scripts/check-adr-numbers.sh のテスト。
#
# 「番号が重複していたら落とす」ケースと「重複が無ければ通す」ケースを対で持つ。
# 片方だけだと、何でも通す(または何でも落とす)検査でも緑になる。

setup() {
    load 'helpers/setup'
    SCRIPT="${BATS_TEST_DIRNAME}/../scripts/check-adr-numbers.sh"
    ADR_DIR="$BATS_TEST_TMPDIR/adr"
    mkdir -p "$ADR_DIR"
    touch "$ADR_DIR/README.md"
}

@test "番号がすべて異なれば通る" {
    touch "$ADR_DIR/0001-first.md" "$ADR_DIR/0002-second.md"
    run bash "$SCRIPT" "$ADR_DIR"
    assert_success
}

@test "同じ番号の ADR が 2 つあれば、その番号と両方のファイルを出して落ちる" {
    touch "$ADR_DIR/0001-first.md" "$ADR_DIR/0002-second.md" "$ADR_DIR/0002-other.md"
    run bash "$SCRIPT" "$ADR_DIR"
    assert_failure
    assert_output --partial "0002"
    assert_output --partial "0002-second.md"
    assert_output --partial "0002-other.md"
    refute_output --partial "0001-first.md"
}

@test "重複した番号が複数あれば、すべての番号を出す" {
    touch "$ADR_DIR/0001-a.md" "$ADR_DIR/0001-b.md" "$ADR_DIR/0003-c.md" "$ADR_DIR/0003-d.md"
    run bash "$SCRIPT" "$ADR_DIR"
    assert_failure
    assert_output --partial "0001-a.md"
    assert_output --partial "0003-d.md"
}

@test "番号付きの ADR が 1 つも無いディレクトリは通る" {
    run bash "$SCRIPT" "$ADR_DIR"
    assert_success
}

@test "ディレクトリが無ければ通さずに落ちる" {
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/missing"
    assert_failure
    assert_output --partial "is not a directory"
}

@test "引数を省くとカレントディレクトリの docs/adr を検査する" {
    mkdir -p "$BATS_TEST_TMPDIR/repo/docs/adr"
    touch "$BATS_TEST_TMPDIR/repo/docs/adr/0001-a.md" "$BATS_TEST_TMPDIR/repo/docs/adr/0001-b.md"
    cd "$BATS_TEST_TMPDIR/repo"
    run bash "$SCRIPT"
    assert_failure
    assert_output --partial "0001-b.md"
}
