setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-briefing.sh"
    export HOME="$BATS_TEST_TMPDIR"
    HDIR="$HOME/.claude/harness"
    mkdir -p "$HDIR"
}

briefing() {
    bash "$SCRIPT"
}

@test "fresh install bootstraps and prints OK" {
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
    assert_output --partial 'last review: never'
    assert [ -f "$HDIR/state.json" ]
    assert [ -f "$HDIR/queue.md" ]
}

@test "review overdue with queued work warns with remedy" {
    old=$(( $(date +%s) - 30*86400 ))
    printf '{"version":1,"last_review_epoch":%s}' "$old" > "$HDIR/state.json"
    printf '## [2026-07-01] some candidate\n- **Status:** pending\n' >> "$HDIR/queue.md"
    run briefing
    assert_success
    assert_output --partial 'ATTENTION'
    assert_output --partial 'overdue'
    assert_output --partial '/harness-review'
}

@test "fresh review prints OK with queue count" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    printf '## [2026-07-01] some candidate\n- **Status:** pending\n' >> "$HDIR/queue.md"
    run briefing
    assert_success
    assert_output --partial 'Harness: OK | queue: 1 | pending: 0 | last review: 0d ago'
}

@test "pending pile-up warns" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    for i in 1 2 3 4 5 6; do
        printf '{"session_id":"s%s","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":%s}\n' "$i" "$now" >> "$HDIR/pending.jsonl"
    done
    run briefing
    assert_success
    assert_output --partial 'unreflected sessions'
    assert_output --partial '/harness-reflect'
}

@test "corrupt state.json warns but exits 0" {
    printf 'not json' > "$HDIR/state.json"
    run briefing
    assert_success
    assert_output --partial 'corrupt'
}

@test "non-numeric last_review_epoch warns but exits 0" {
    printf '{"version":1,"last_review_epoch":"not-a-number"}' > "$HDIR/state.json"
    run briefing
    assert_success
    assert_output --partial 'non-numeric'
}

@test "malformed recorded_epoch in pending exits 0" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    printf '{"session_id":"bad","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":"oops"}\n' > "$HDIR/pending.jsonl"
    run briefing
    assert_success
}
