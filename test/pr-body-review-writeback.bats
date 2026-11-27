# pr-body-review の writeback.sh: 書く前後に本文を取り直して照らす。gh はスタブにし、PR の本文を 1 つのファイルで持つ。
setup() {
    load 'helpers/setup'
    unset GH_FAIL_VIEW GH_FAIL_VIEW_AFTER_EDIT GH_FAIL_EDIT GH_EDIT_WRITES_THEN_FAILS GH_EDIT_IGNORED GH_MANGLE
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
    [[ -n "${GH_FAIL_VIEW_AFTER_EDIT:-}" ]] && grep -q '^pr edit' "$GH_LOG" && exit 1
    jq -Rs '{body: .}' <"$REMOTE_BODY"
    ;;
"pr edit")
    [[ -n "${GH_FAIL_EDIT:-}" ]] && exit 1
    # 成功を返したのに保存されていない(読み取りが古い)場合を模す。
    [[ -n "${GH_EDIT_IGNORED:-}" ]] && exit 0
    cp "$5" "$REMOTE_BODY"
    # 保存はされたのに失敗を返した場合を模す。
    [[ -n "${GH_EDIT_WRITES_THEN_FAILS:-}" ]] && exit 1
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

@test "書いた後の本文を取得できなければ 2 で終わる" {
    run env GH_FAIL_VIEW_AFTER_EDIT=1 bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_failure 2
    run grep -c 'pr edit' "$GH_LOG"
    assert_output '1'
}

@test "gh pr edit が失敗して本文が original.md のままなら 1 で終わり、再試行しない" {
    run env GH_FAIL_EDIT=1 bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_failure 1
    cmp "$ORIGINAL" "$REMOTE_BODY"
    run grep -c 'pr edit' "$GH_LOG"
    assert_output '1'
}

@test "gh pr edit が失敗しても本文が edited.md になっていれば 0 で終わる" {
    run env GH_EDIT_WRITES_THEN_FAILS=1 bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_success
    cmp "$EDITED" "$REMOTE_BODY"
}

@test "gh pr edit が成功を返したのに本文が original.md のままなら 2 で終わる" {
    run env GH_EDIT_IGNORED=1 bash "$SCRIPT" "$PR" "$ORIGINAL" "$EDITED"
    assert_failure 2
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
