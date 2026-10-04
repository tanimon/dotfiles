# ticket スキルの照合スクリプト。gh をスタブにして、検出する場合としない場合を対で確かめる。
bats_require_minimum_version 1.5.0
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/skills/ticket/scripts/executable_audit.sh"
    export GH_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$GH_FIXTURES" "$BATS_TEST_TMPDIR/bin"
    for name in open closed merged; do printf '[]' >"$GH_FIXTURES/$name.json"; done
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
"repo view --json nameWithOwner") printf '{"nameWithOwner":"tanimon/sample"}' ;;
"issue list --state open"*) cat "$GH_FIXTURES/open.json" ;;
"issue list --state closed"*) cat "$GH_FIXTURES/closed.json" ;;
"pr list --state merged"*) cat "$GH_FIXTURES/merged.json" ;;
"api repos/tanimon/sample/issues/"*/dependencies/blocked_by)
    n=${2#repos/tanimon/sample/issues/}
    n=${n%%/*}
    cat "$GH_FIXTURES/blocked_by-$n.json" 2>/dev/null || printf '[]'
    ;;
"api repos/tanimon/sample/issues/"*/timeline*)
    n=${2#repos/tanimon/sample/issues/}
    n=${n%%/*}
    cat "$GH_FIXTURES/timeline-$n.json" 2>/dev/null || printf '[]'
    ;;
"api repos/tanimon/sample/issues/"*)
    n=${2##*/}
    cat "$GH_FIXTURES/issue-$n.json" 2>/dev/null || printf '{}'
    ;;
*)
    echo "unexpected gh $*" >&2
    exit 1
    ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# open issue を 1 件置く。$1 = 番号、$2 = 本文
open_issue() {
    jq -n --argjson n "$1" --arg b "$2" '[{number:$n, body:$b}]' >"$GH_FIXTURES/open.json"
}

# --- blocked-by(#450 の形) ---

@test "本文に Blocked by があり API に無ければ blocked-by-missing" {
    open_issue 450 $'## Parent\n\n#397\n\n## Blocked by\n\n#401\n'
    printf '{"parent_issue_url":"https://api.github.com/repos/tanimon/sample/issues/397"}' >"$GH_FIXTURES/issue-450.json"
    run bash "$SCRIPT"
    assert_success
    assert_output $'blocked-by-missing\t450\t#401'
}

@test "Blocked by が別リポジトリの owner/repo#N だけなら何も出さない" {
    open_issue 450 $'## Blocked by\n\n- tanimon/other#5 (別リポジトリ)\n'
    run bash "$SCRIPT"
    assert_success
    assert_output ''
}

@test "Blocked by が同じリポジトリの #N なら blocked-by-missing" {
    open_issue 450 $'## Blocked by\n\n- #5 (同じリポジトリ)\n'
    run bash "$SCRIPT"
    assert_success
    assert_output $'blocked-by-missing\t450\t#5'
}

@test "本文の Blocked by が API にもあれば何も出さない" {
    open_issue 450 $'## Parent\n\n#397\n\n## Blocked by\n\n#401\n'
    printf '{"parent_issue_url":"https://api.github.com/repos/tanimon/sample/issues/397"}' >"$GH_FIXTURES/issue-450.json"
    printf '[{"number":401}]' >"$GH_FIXTURES/blocked_by-450.json"
    run bash "$SCRIPT"
    assert_success
    assert_output ''
}

# --- parent ---

@test "本文に Parent があり API の parent が無ければ parent-missing" {
    open_issue 12 $'## Parent\n\n#3\n'
    run bash "$SCRIPT"
    assert_output $'parent-missing\t12\t#3'
}

@test "Parent 節の 2 件目以降は比べない" {
    open_issue 12 $'## Parent\n\n#3 の下で #9 も参照\n'
    printf '{"parent_issue_url":"https://api.github.com/repos/tanimon/sample/issues/3"}' >"$GH_FIXTURES/issue-12.json"
    run bash "$SCRIPT"
    assert_success
    assert_output ''
}

@test "API に別の親があれば parent-missing ではなく parent-mismatch" {
    open_issue 12 $'## Parent\n\n#3\n'
    printf '{"parent_issue_url":"https://api.github.com/repos/tanimon/sample/issues/4"}' >"$GH_FIXTURES/issue-12.json"
    run bash "$SCRIPT"
    assert_output $'parent-mismatch\t12\t#3(本文) / #4(API)'
}

@test "Parent 節の外の #N は relationship として扱わない" {
    open_issue 12 $'## 関連\n\n#3 を参照\n'
    run bash "$SCRIPT"
    assert_output ''
}

# --- open-after-merge ---

@test "マージ済み PR が close するはずの issue が open なら open-after-merge" {
    open_issue 5 'body'
    printf '[{"number":10,"closingIssuesReferences":[{"number":5,"url":"https://github.com/tanimon/sample/issues/5"}]}]' >"$GH_FIXTURES/merged.json"
    run bash "$SCRIPT"
    assert_output $'open-after-merge\t5\tPR #10'
}

@test "close するはずの issue が close 済みなら何も出さない" {
    printf '[{"number":10,"closingIssuesReferences":[{"number":5,"url":"https://github.com/tanimon/sample/issues/5"}]}]' >"$GH_FIXTURES/merged.json"
    run bash "$SCRIPT"
    assert_output ''
}

@test "別リポジトリの issue への参照は対象にしない" {
    open_issue 5 'body'
    printf '[{"number":10,"closingIssuesReferences":[{"number":5,"url":"https://github.com/other/repo/issues/5"}]}]' >"$GH_FIXTURES/merged.json"
    run bash "$SCRIPT"
    assert_output ''
}

# --- ac-unchecked ---

@test "PR で close された issue の AC に [ ] が残れば ac-unchecked" {
    jq -n '[{number:7, body:"## Acceptance criteria\n\n- [x] a\n- [ ] b を満たす\n", closedByPullRequestsReferences:[{number:20}]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output $'ac-unchecked\t7\tPR #20: b を満たす'
}

@test "close した PR が複数あれば全件を根拠に出す" {
    jq -n '[{number:7, body:"## Acceptance criteria\n\n- [ ] b\n", closedByPullRequestsReferences:[{number:20},{number:22}]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output $'ac-unchecked\t7\tPR #20, PR #22: b'
}

@test "AC がすべて [x] なら何も出さない" {
    jq -n '[{number:7, body:"## Acceptance criteria\n\n- [x] a\n- [x] b\n", closedByPullRequestsReferences:[{number:20}]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output ''
}

@test "PR を経ずに close された issue の AC は対象にしない" {
    jq -n '[{number:7, body:"## Acceptance criteria\n\n- [ ] b\n", closedByPullRequestsReferences:[]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output ''
}

@test "完了条件(案) の見出しも AC として扱う" {
    jq -n '[{number:8, body:"## 完了条件(案)\n\n- [ ] c\n\n## メモ\n\n- [ ] AC ではない\n", closedByPullRequestsReferences:[{number:21}]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output $'ac-unchecked\t8\tPR #21: c'
}

# --- mentioned-by-merged ---

@test "マージ済み PR からの言及がある open issue は mentioned-by-merged" {
    open_issue 5 'body'
    printf '[{"event":"cross-referenced","source":{"issue":{"number":30,"pull_request":{"merged_at":"2026-10-01T00:00:00Z"},"repository":{"full_name":"tanimon/sample"}}}}]' >"$GH_FIXTURES/timeline-5.json"
    run bash "$SCRIPT"
    assert_output $'mentioned-by-merged\t5\tPR #30'
}

@test "未マージの PR・issue・別リポジトリからの言及は候補にしない" {
    open_issue 5 'body'
    printf '%s' '[
      {"event":"cross-referenced","source":{"issue":{"number":30,"pull_request":{"merged_at":null},"repository":{"full_name":"tanimon/sample"}}}},
      {"event":"cross-referenced","source":{"issue":{"number":31,"repository":{"full_name":"tanimon/sample"}}}},
      {"event":"cross-referenced","source":{"issue":{"number":32,"pull_request":{"merged_at":"2026-10-01T00:00:00Z"},"repository":{"full_name":"other/repo"}}}},
      {"event":"labeled"}
    ]' >"$GH_FIXTURES/timeline-5.json"
    run bash "$SCRIPT"
    assert_output ''
}

@test "open-after-merge で出した issue には mentioned-by-merged を重ねない" {
    open_issue 5 'body'
    printf '[{"number":10,"closingIssuesReferences":[{"number":5,"url":"https://github.com/tanimon/sample/issues/5"}]}]' >"$GH_FIXTURES/merged.json"
    printf '[{"event":"cross-referenced","source":{"issue":{"number":10,"pull_request":{"merged_at":"2026-10-01T00:00:00Z"},"repository":{"full_name":"tanimon/sample"}}}}]' >"$GH_FIXTURES/timeline-5.json"
    run bash "$SCRIPT"
    assert_output $'open-after-merge\t5\tPR #10'
}

@test "gh が失敗したら非 0 で終わる" {
    printf 'not json' >"$GH_FIXTURES/open.json"
    run bash "$SCRIPT"
    assert_failure
}

@test "issue 単位の API が失敗しても残りを検査し、最後に 1 で終わる" {
    jq -n '[{number:450, body:"## Blocked by\n\n#401\n"}, {number:451, body:"## Blocked by\n\n#402\n"}]' >"$GH_FIXTURES/open.json"
    printf 'not json' >"$GH_FIXTURES/blocked_by-450.json"
    run --separate-stderr bash "$SCRIPT"
    assert_failure 1
    assert_output $'blocked-by-missing\t451\t#402'
    [[ "$stderr" == *'#450 の dependencies'* ]]
}

@test "件数が上限に達したら stderr に知らせ、stdout は変えない" {
    open_issue 450 'no relationship'
    run --separate-stderr env TICKET_AUDIT_LIMIT=1 bash "$SCRIPT"
    assert_success
    assert_output ''
    [[ "$stderr" == *'audit.sh: open の issue が上限 1 件に達した'* ]]
}

@test "件数が上限に達していなければ stderr は空" {
    open_issue 450 'no relationship'
    run --separate-stderr bash "$SCRIPT"
    assert_success
    [ -z "$stderr" ]
}
