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

# 週次ジョブ(harness-weekly.sh)の heartbeat。表示するのは launchd の plist が
# 置かれている(= このマシンでジョブを動かす前提の)ときだけ。
weekly_installed() {
    mkdir -p "$HOME/Library/LaunchAgents"
    : >"$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    printf '{"version":1,"last_review_epoch":%s}' "$(date +%s)" >"$HDIR/state.json"
}

@test "weekly: plist が無ければ heartbeat を表示しない" {
    run briefing
    assert_success
    refute_output --partial 'weekly'
}

@test "weekly: heartbeat が新しければ OK 行に経過日数を出す" {
    weekly_installed
    printf '%s\n' "$(( $(date +%s) - 2*86400 ))" >"$HDIR/weekly-heartbeat"
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
    assert_output --partial 'weekly: 2d ago'
}

@test "weekly: heartbeat が古ければ対処コマンド付きで警告する" {
    weekly_installed
    printf '%s\n' "$(( $(date +%s) - 10*86400 ))" >"$HDIR/weekly-heartbeat"
    run briefing
    assert_success
    assert_output --partial 'ATTENTION'
    assert_output --partial 'weekly job last succeeded 10d ago'
    assert_output --partial 'launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly'
}

@test "weekly: heartbeat が無く plist が新しければ never と出して警告しない" {
    weekly_installed
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
    assert_output --partial 'weekly: never'
}

@test "weekly: heartbeat が無いまま plist が古ければ警告する" {
    weekly_installed
    touch -t 202001010000 "$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    run briefing
    assert_success
    assert_output --partial 'ATTENTION'
    assert_output --partial 'weekly job has never succeeded'
    assert_output --partial 'launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly'
}

@test "weekly: heartbeat が数値でなければ警告する" {
    weekly_installed
    printf 'oops\n' >"$HDIR/weekly-heartbeat"
    run briefing
    assert_success
    assert_output --partial 'ATTENTION'
    assert_output --partial 'weekly-heartbeat is not a number'
}

@test "週次ジョブが残した deploy-only の修正があれば、適用して消すよう警告する" {
    printf '## 2026-10-04\n\n- a を適用する\n- b を適用する\n' >"$HDIR/deploy-only.md"
    run briefing
    assert_success
    assert_output --partial 'ATTENTION'
    assert_output --partial 'deploy-only fix(es) to apply by hand (2)'
    assert_output --partial "$HDIR/deploy-only.md"
    assert_output --partial 'then delete it'
}

@test "deploy-only.md が空か無ければ警告しない" {
    run briefing
    assert_success
    refute_output --partial 'deploy-only'
    : >"$HDIR/deploy-only.md"
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
}
