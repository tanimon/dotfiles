# pr-body-review の writeback.sh: 書く前後に本文を取り直して照らす。gh はスタブにし、PR の本文を 1 つのファイルで持つ。
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/skills/pr-body-review/scripts/executable_writeback.sh"
    PR='https://github.com/tanimon/sample/pull/7'
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    export REMOTE_BODY="$BATS_TEST_TMPDIR/remote-body.md"
    : >"$GH_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
"pr view")
    [[ -n "${GH_FAIL_VIEW:-}" ]] && exit 1
    jq -Rs '{body: .}' <"$REMOTE_BODY"
    ;;
"pr edit")
    [[ -n "${GH_FAIL_EDIT:-}" ]] && exit 1
    cp "$5" "$REMOTE_BODY"
    # GitHub が本文を書き換えて保存した場合を模す。
    [[ -n "${GH_MANGLE:-}" ]] && printf '\n' >>"$REMOTE_BODY"
    exit 0
    ;;
*)
    echo "unexpected gh $*" >&2
    exit 1
    ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    ORIGINAL="$BATS_TEST_TMPDIR/original.md"
    EDITED="$BATS_TEST_TMPDIR/edited.md"
    printf '## Summary\n\n古い記述\n' >"$ORIGINAL"
    printf '## Summary\n\n新しい記述\n' >"$EDITED"
    cp "$ORIGINAL" "$REMOTE_BODY"
}

@test "本文が original.md のままなら書き戻し、照らして 0 で終わる" {
    run bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_success
    cmp "$EDITED" "$REMOTE_BODY"
    run cat "$GH_LOG"
    assert_line --index 0 "pr view $PR --json body"
    assert_line --index 1 "pr edit $PR --body-file $EDITED"
    assert_line --index 2 "pr view $PR --json body"
}

@test "末尾に改行の無い本文も 1 バイトも変えずに照らす" {
    printf '## Summary\n\n古い記述' >"$ORIGINAL"
    printf '## Summary\n\n新しい記述' >"$EDITED"
    cp "$ORIGINAL" "$REMOTE_BODY"
    run bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_success
    cmp "$EDITED" "$REMOTE_BODY"
}

@test "取り直した本文が original.md と食い違えば書かずに 1 で終わる" {
    printf '## Summary\n\n他の人が直した記述\n' >"$REMOTE_BODY"
    run bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_failure 1
    assert_output --partial '他の人が直した記述'
    run grep -c 'pr edit' "$GH_LOG"
    assert_output '0'
}

@test "本文を取得できなければ書かずに 1 で終わる" {
    run env GH_FAIL_VIEW=1 bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_failure 1
    run grep -c 'pr edit' "$GH_LOG"
    assert_output '0'
}

@test "書いた後の本文が edited.md と食い違えば差分を出して 2 で終わる" {
    run env GH_MANGLE=1 bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_failure 2
    assert_output --partial "$ORIGINAL"
    run grep -c 'pr edit' "$GH_LOG"
    assert_output '1'
}

@test "gh pr edit が失敗して本文が変わらなければ 2 で終わり、再試行しない" {
    run env GH_FAIL_EDIT=1 bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_failure 2
    cmp "$ORIGINAL" "$REMOTE_BODY"
    run grep -c 'pr edit' "$GH_LOG"
    assert_output '1'
}

@test "PR を番号で渡すと gh を呼ばずに 1 で終わる" {
    run bash "$SCRIPT" 7 "$ORIGINAL" "$EDITED"
    assert_failure 1
    [ ! -s "$GH_LOG" ]
}

@test "引数が足りなければ gh を呼ばずに 1 で終わる" {
    run bash "$SCRIPT" "$PR" "$ORIGINAL"
    assert_failure 1
    [ ! -s "$GH_LOG" ]
}

@test "edited.md が読めなければ gh を呼ばずに 1 で終わる" {
    run bash "$SCRIPT" "$PR" "$ORIGINAL" "$BATS_TEST_TMPDIR/missing.md"
    assert_failure 1
    [ ! -s "$GH_LOG" ]
}
