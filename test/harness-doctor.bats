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

weekly_installed() {
    mkdir -p "$HOME/Library/LaunchAgents"
    : >"$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    printf '#!/usr/bin/env bash\n' >"$HOME/.claude/scripts/harness-weekly.sh"
    chmod +x "$HOME/.claude/scripts/harness-weekly.sh"
}

# ホストの OS に依存しないよう uname をスタブにする
stub_uname() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$1" >"$BATS_TEST_TMPDIR/bin/uname"
    chmod +x "$BATS_TEST_TMPDIR/bin/uname"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# 週次ジョブの健全性。判定の場合分けは test/harness-health.bats にあり、ここでは level の
# PASS / WARN / FAIL と exit code への写し方だけを見る
@test "weekly: ok は PASS" {
    weekly_installed
    printf '%s\n' "$(date +%s)" >"$HOME/.claude/harness/weekly-heartbeat"
    run doctor
    assert_success
    assert_line 'PASS: weekly job last succeeded 0d ago'
}

@test "weekly: warn は WARN で、exit 0 のまま" {
    stub_uname Darwin
    run doctor
    assert_success
    assert_line --partial 'WARN: weekly job not installed'
}

@test "weekly: fail は FAIL で exit 1" {
    weekly_installed
    printf '%s\n' "$(( $(date +%s) - 10*86400 ))" >"$HOME/.claude/harness/weekly-heartbeat"
    run doctor
    assert_failure
    assert_line --partial 'FAIL: weekly job last succeeded 10d ago — check '
}

# 判定の lib が無い・空・構文エラーなら FAIL して exit 1 で終わる
copy_doctor() {
    local dir="$BATS_TEST_TMPDIR/scripts"
    mkdir -p "$dir"
    cp "$SCRIPT" "$dir/harness-doctor.sh"
    [[ $1 == missing ]] || mkdir -p "$dir/lib"
    case $1 in
    missing) ;;
    empty) : >"$dir/lib/harness-health.bash" ;;
    syntax) printf '%s\n' 'harness_health_weekly() {' >"$dir/lib/harness-health.bash" ;;
    esac
    printf '%s\n' "$dir/harness-doctor.sh"
}

@test "lib が無い・空・構文エラーなら FAIL して exit 1" {
    local kind script
    for kind in missing empty syntax; do
        script=$(copy_doctor "$kind")
        run bash "$script"
        assert_failure 1
        assert_line --partial "FAIL: lib/harness-health.bash deployed and loadable"
        assert_line --partial "— run 'chezmoi apply'"
        rm -rf "$BATS_TEST_TMPDIR/scripts"
    done
}
