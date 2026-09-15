setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-briefing.sh"
    export HOME="$BATS_TEST_TMPDIR"
    HDIR="$HOME/.claude/harness"
    mkdir -p "$HDIR" "$HOME/.codex"
    # harness 所有のグローバル Target(#311)。既定では「在る」状態にしておく —
    # 不在は下の専用ケースだけが作る。ここで作らないと、グローバル指示とは無関係な
    # 既存ケースまで ATTENTION 側に落ちて、別の理由で落ちるテストになる。
    : >"$HOME/.claude/CLAUDE.md"
    : >"$HOME/.codex/AGENTS.md"
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

# ---------- グローバル instructions の不在(#311 / #324 までの空白) ----------

@test "missing ~/.claude/CLAUDE.md warns with remedy" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    rm "$HOME/.claude/CLAUDE.md"
    run briefing
    assert_success
    assert_output --partial 'ATTENTION'
    assert_output --partial 'global instructions missing'
    assert_output --partial '~/.claude/CLAUDE.md'
    assert_output --partial 'just harness-sync-global'
    # 在るほうは名指ししない
    refute_output --partial '~/.codex/AGENTS.md'
}

@test "missing ~/.codex/AGENTS.md warns with remedy" {
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    rm "$HOME/.codex/AGENTS.md"
    run briefing
    assert_success
    assert_output --partial 'global instructions missing'
    assert_output --partial '~/.codex/AGENTS.md'
    refute_output --partial '~/.claude/CLAUDE.md'
}

@test "both global Targets present: no global-instructions warning" {
    # Contrast Pair。上2件は「常に警告する」実装でも通ってしまう。
    now=$(date +%s)
    printf '{"version":1,"last_review_epoch":%s}' "$now" > "$HDIR/state.json"
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
    refute_output --partial 'global instructions missing'
}
