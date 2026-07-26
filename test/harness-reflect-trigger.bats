setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-reflect-trigger.sh"
    unset HARNESS_DISABLE
    export HOME="$BATS_TEST_TMPDIR"
    TRANSCRIPT="$BATS_TEST_TMPDIR/big.jsonl"
    for i in $(seq 1 12); do
        printf '{"type":"assistant","message":{"id":"msg_%s"}}\n' "$i" >> "$TRANSCRIPT"
    done
    PENDING="$HOME/.claude/harness/pending.jsonl"
    STATE="$HOME/.claude/harness/state.json"
}

trigger() {
    printf '%s' "$1" | bash "$SCRIPT"
}

@test "substantial session is recorded in pending.jsonl" {
    payload=$(printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    run trigger "$payload"
    assert_success
    assert [ -f "$PENDING" ]
    assert jq -e 'select(.session_id == "sess-big") | .transcript_path and .recorded_epoch' "$PENDING"
}

@test "state.json records last_trigger_epoch" {
    payload=$(printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    run trigger "$payload"
    assert_success
    assert jq -e '.last_trigger_epoch > 0' "$STATE"
}

@test "duplicate session_id is not appended twice" {
    payload=$(printf '{"session_id":"sess-big","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    trigger "$payload"
    trigger "$payload"
    count=$(grep -c 'sess-big' "$PENDING")
    assert_equal "$count" 1
}

@test "short session is skipped" {
    short="$BATS_TEST_TMPDIR/short.jsonl"
    printf '{"type":"assistant","message":{}}\n' > "$short"
    payload=$(printf '{"session_id":"sess-short","transcript_path":"%s","cwd":"/tmp"}' "$short")
    run trigger "$payload"
    assert_success
    refute grep -q 'sess-short' "$PENDING"
}

@test "malformed stdin exits 0" {
    run trigger 'not json at all'
    assert_success
}

@test "missing transcript file exits 0 without recording" {
    payload=$(printf '{"session_id":"sess-gone","transcript_path":"%s/nonexistent.jsonl","cwd":"/tmp"}' "$BATS_TEST_TMPDIR")
    run trigger "$payload"
    assert_success
    refute grep -q 'sess-gone' "$PENDING"
}

@test "HARNESS_DISABLE=1 skips recording" {
    export HARNESS_DISABLE=1
    payload=$(printf '{"session_id":"sess-disabled","transcript_path":"%s","cwd":"/tmp"}' "$TRANSCRIPT")
    run trigger "$payload"
    assert_success
    refute grep -q 'sess-disabled' "$PENDING"
}
