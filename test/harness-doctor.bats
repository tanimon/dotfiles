setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-doctor.sh"
    export HOME="$BATS_TEST_TMPDIR"
    mkdir -p "$HOME/.claude/scripts" "$HOME/.claude/skills/harness-reflect" \
        "$HOME/.claude/skills/harness-review" "$HOME/.claude/harness"
    printf '{"hooks":{"x":"harness-reflect-trigger.sh and harness-briefing.sh"}}' > "$HOME/.claude/settings.json"
    printf '#!/usr/bin/env bash\n' > "$HOME/.claude/scripts/harness-reflect-trigger.sh"
    printf '#!/usr/bin/env bash\n' > "$HOME/.claude/scripts/harness-briefing.sh"
    chmod +x "$HOME/.claude/scripts/harness-reflect-trigger.sh" "$HOME/.claude/scripts/harness-briefing.sh"
    printf -- '---\nname: harness-reflect\n---\n' > "$HOME/.claude/skills/harness-reflect/SKILL.md"
    printf -- '---\nname: harness-review\n---\n' > "$HOME/.claude/skills/harness-review/SKILL.md"
    printf '{"version":1,"last_trigger_epoch":%s}' "$(date +%s)" > "$HOME/.claude/harness/state.json"
    printf '{"session_id":"s1","transcript_path":"/tmp/t","cwd":"/tmp","recorded_epoch":1}\n' > "$HOME/.claude/harness/pending.jsonl"
    printf '# Harness improvement queue\n' > "$HOME/.claude/harness/queue.md"
}

doctor() {
    bash "$SCRIPT"
}

@test "healthy fixture passes with no FAIL lines" {
    run doctor
    assert_success
    refute_output --partial 'FAIL:'
}

@test "unwired hook is detected" {
    printf '{"hooks":{}}' > "$HOME/.claude/settings.json"
    run doctor
    assert_failure
}

@test "corrupt pending.jsonl is detected" {
    printf 'not json\n' >> "$HOME/.claude/harness/pending.jsonl"
    run doctor
    assert_failure
}
