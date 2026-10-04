bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-briefing.sh"
    export HOME="$BATS_TEST_TMPDIR"
    HDIR="$HOME/.claude/harness"
    mkdir -p "$HDIR"
    # 週次ジョブの plist が無いときの判定は OS で変わるので、既定は launchd の無い OS にする
    stub_uname Linux
}

# ホストの OS に依存しないよう uname をスタブにする
stub_uname() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/uname" <<EOF
#!/usr/bin/env bash
printf '%s\\n' $1
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/uname"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
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

# 週次ジョブの健全性。判定の場合分けは test/harness-health.bats にあり、ここでは level の表示への
# 写し方(ok は OK の行の値、warn と fail は ATTENTION)だけを見る
weekly_installed() {
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.claude/scripts"
    : >"$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    printf '#!/usr/bin/env bash\n' >"$HOME/.claude/scripts/harness-weekly.sh"
    chmod +x "$HOME/.claude/scripts/harness-weekly.sh"
    printf '{"version":1,"last_review_epoch":%s}' "$(date +%s)" >"$HDIR/state.json"
}

@test "weekly: ok なら OK の行に lib の値を出す" {
    weekly_installed
    printf '%s\n' "$(( $(date +%s) - 2*86400 ))" >"$HDIR/weekly-heartbeat"
    run briefing
    assert_success
    assert_output 'Harness: OK | queue: 0 | pending: 0 | last review: 0d ago | weekly: 2d ago'
}

@test "weekly: fail は対処付きの ATTENTION にする" {
    weekly_installed
    printf '%s\n' "$(( $(date +%s) - 10*86400 ))" >"$HDIR/weekly-heartbeat"
    run briefing
    assert_success
    assert_line --index 0 'Harness: ATTENTION'
    assert_line --partial ' - weekly job last succeeded 10d ago — check '
}

@test "weekly: warn(macOS で plist が無い)も ATTENTION にする" {
    stub_uname Darwin
    run briefing
    assert_success
    assert_line --index 0 'Harness: ATTENTION'
    assert_line --partial ' - weekly job not installed'
}

@test "weekly: launchd の無い OS で plist が無ければ weekly を出さない" {
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
    refute_output --partial 'weekly'
}

# 判定の lib が無い・空・構文エラーでも黙らず、ATTENTION と対処を出して exit 0 で終わる
copy_briefing() {
    local dir="$BATS_TEST_TMPDIR/scripts"
    mkdir -p "$dir"
    cp "$SCRIPT" "$dir/harness-briefing.sh"
    [[ $1 == missing ]] || mkdir -p "$dir/lib"
    case $1 in
    missing) ;;
    empty) : >"$dir/lib/harness-health.bash" ;;
    syntax) printf '%s\n' 'harness_health_weekly() {' >"$dir/lib/harness-health.bash" ;;
    esac
    printf '%s\n' "$dir/harness-briefing.sh"
}

@test "lib が無い・空・構文エラーなら ATTENTION と chezmoi apply を出して exit 0" {
    local kind script
    for kind in missing empty syntax; do
        script=$(copy_briefing "$kind")
        run bash "$script"
        assert_success
        assert_line --index 0 'Harness: ATTENTION'
        assert_line --index 1 --partial "lib/harness-health.bash is missing or broken — run 'chezmoi apply'"
        rm -rf "$BATS_TEST_TMPDIR/scripts"
    done
}

@test "状態ディレクトリに書けなければ、lib の破損ではなく doctor を案内して exit 0" {
    chmod 555 "$HDIR"
    run --separate-stderr briefing
    chmod 755 "$HDIR"
    assert_success
    assert_line --index 0 'Harness: ATTENTION'
    assert_line --index 1 --partial "could not create the state files in $HDIR"
    assert_line --index 1 --partial 'harness-doctor.sh'
    refute_output --partial 'missing or broken'
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

@test "deploy-only.md に項目が無く見出しだけなら警告しない" {
    printf '## 2026-10-04\n\n' >"$HDIR/deploy-only.md"
    run briefing
    assert_success
    assert_output --partial 'Harness: OK'
    refute_output --partial 'deploy-only'
}
