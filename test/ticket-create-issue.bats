# create-issue.sh: issue の作成と native relationship の設定を一度に行う。gh はスタブにして呼び出しを記録する。
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/skills/ticket/scripts/executable_create-issue.sh"
    export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
    : >"$GH_LOG"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    # 新しい issue は #450。database id は番号の 10 倍を返す。
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
"issue create"*) printf 'https://github.com/tanimon/sample/issues/450\n' ;;
"repo view --json nameWithOwner") printf '{"nameWithOwner":"tanimon/sample"}' ;;
*"-X POST"*)
    [[ -n "${GH_FAIL_POST:-}" ]] && exit 1
    printf '{}'
    ;;
"api repos/tanimon/sample/issues/"*)
    n=${2##*/}
    printf '{"id":%s0}' "$n"
    ;;
*)
    echo "unexpected gh $*" >&2
    exit 1
    ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    BODY="$BATS_TEST_TMPDIR/issue-body.md"
}

@test "Parent と Blocked by があれば作成の後に native に張る" {
    printf '## Parent\n\n#397\n\n## Blocked by\n\n#401\n\n<!-- ticket-skill -->\n' >"$BODY"
    run bash "$SCRIPT" --title t --body-file "$BODY"
    assert_success
    assert_output 'https://github.com/tanimon/sample/issues/450'
    run cat "$GH_LOG"
    assert_line --index 0 "issue create --title t --body-file $BODY"
    assert_line 'api repos/tanimon/sample/issues/397/sub_issues -X POST -F sub_issue_id=4500'
    assert_line 'api repos/tanimon/sample/issues/450/dependencies/blocked_by -X POST -F issue_id=4010'
}

@test "節が無ければ relationship の API を呼ばない" {
    printf '本文\n\n<!-- ticket-skill -->\n' >"$BODY"
    run bash "$SCRIPT" --title t --body-file "$BODY"
    assert_success
    run grep -c -- '-X POST' "$GH_LOG"
    assert_output '0'
}

@test "その他の引数は gh issue create にそのまま渡す" {
    printf '<!-- ticket-skill -->\n' >"$BODY"
    run bash "$SCRIPT" --title t --body-file "$BODY" --label 'wayfinder:map'
    assert_success
    run head -n 1 "$GH_LOG"
    assert_output "issue create --title t --body-file $BODY --label wayfinder:map"
}

@test "本文にマーカーが無ければ何も作らずに 2 で終わる" {
    printf '## Parent\n\n#397\n' >"$BODY"
    run bash "$SCRIPT" --title t --body-file "$BODY"
    assert_failure 2
    [ ! -s "$GH_LOG" ]
}

@test "body-file が相対パスなら何も作らずに 2 で終わる" {
    run bash "$SCRIPT" --title t --body-file issue-body.md
    assert_failure 2
    [ ! -s "$GH_LOG" ]
}

@test "body-file が無ければ何も作らずに 2 で終わる" {
    run bash "$SCRIPT" --title t
    assert_failure 2
    [ ! -s "$GH_LOG" ]
}

@test "relationship の設定に失敗したら URL と失敗した関係を出して 1 で終わる" {
    printf '## Blocked by\n\n#401\n\n<!-- ticket-skill -->\n' >"$BODY"
    GH_FAIL_POST=1 run bash "$SCRIPT" --title t --body-file "$BODY"
    assert_failure 1
    assert_output --partial 'https://github.com/tanimon/sample/issues/450'
    assert_output --partial 'blocked-by #401'
}

@test "同じ番号が節に 2 回あっても relationship は 1 回だけ張る" {
    printf '## Blocked by\n\n#401 と #401\n\n<!-- ticket-skill -->\n' >"$BODY"
    run bash "$SCRIPT" --title t --body-file "$BODY"
    assert_success
    run grep -c -- 'dependencies/blocked_by -X POST' "$GH_LOG"
    assert_output '1'
}

@test "Parent 節に #N が複数あれば先頭だけを親にし、警告を出して 0 で終わる" {
    printf '## Parent\n\n#397 の下で #12 も参照\n\n<!-- ticket-skill -->\n' >"$BODY"
    run bash "$SCRIPT" --title t --body-file "$BODY"
    assert_success
    assert_output --partial '先頭の #397 だけを親にした'
    run grep -c 'sub_issues -X POST' "$GH_LOG"
    assert_output '1'
    run grep 'issues/397/sub_issues' "$GH_LOG"
    assert_success
}
