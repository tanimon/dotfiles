# 自己改善ループの健全性の判定(lib/harness-health.bash)の interface の検査。
# briefing と doctor は、ここで検査する level と文言を表示するだけなので、
# 判定の場合分けはこのファイルにだけ書く。
setup() {
    load 'helpers/setup'
    LIB="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/harness-health.bash"
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    PLIST="$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    mkdir -p "$HDIR"
    stub_uname Darwin
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

weekly_installed() {
    mkdir -p "$(dirname "$PLIST")" "$HOME/.claude/scripts"
    : >"$PLIST"
    printf '#!/usr/bin/env bash\n' >"$HOME/.claude/scripts/harness-weekly.sh"
    chmod +x "$HOME/.claude/scripts/harness-weekly.sh"
}

heartbeat_days_ago() {
    printf '%s\n' "$(($(date +%s) - $1 * 86400))" >"$HDIR/weekly-heartbeat"
}

weekly() {
    # shellcheck source=../dot_claude/scripts/lib/harness-health.bash
    source "$LIB"
    harness_health_weekly
}

@test "状態ディレクトリは ~/.claude/harness" {
    source "$LIB"
    run harness_health_dir
    assert_success
    assert_output "$HDIR"
}

@test "初期化は state.json / pending.jsonl / queue.md を作り、既にあれば上書きしない" {
    rm -rf "$HDIR"
    source "$LIB"
    run harness_health_bootstrap
    assert_success
    assert_equal "$(cat "$HDIR/state.json")" '{"version":1}'
    assert [ -f "$HDIR/pending.jsonl" ]
    assert [ ! -s "$HDIR/pending.jsonl" ]
    run grep -c '^## ' "$HDIR/queue.md"
    assert_output 0
    printf '{"version":1,"last_review_epoch":1}\n' >"$HDIR/state.json"
    printf 'x\n' >"$HDIR/pending.jsonl"
    run harness_health_bootstrap
    assert_success
    assert_equal "$(cat "$HDIR/state.json")" '{"version":1,"last_review_epoch":1}'
    assert_equal "$(cat "$HDIR/pending.jsonl")" 'x'
}

@test "heartbeat が新しければ ok で、OK の行に経過日数を出す" {
    weekly_installed
    heartbeat_days_ago 2
    run weekly
    assert_success
    assert_line "$(printf 'ok\tweekly job last succeeded 2d ago')"
    assert_line "$(printf 'summary\tweekly: 2d ago')"
    refute_line --regexp '^(warn|fail)'
}

@test "heartbeat が 1 周期(8 日)より古ければ fail で、対処を添える" {
    weekly_installed
    heartbeat_days_ago 8
    run weekly
    assert_success
    assert_line --regexp '^fail	weekly job last succeeded 8d ago — check ~/Library/Logs/harness-weekly\.log'
    assert_output --partial 'launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly'
}

@test "heartbeat が 7 日前なら まだ ok" {
    weekly_installed
    heartbeat_days_ago 7
    run weekly
    assert_line "$(printf 'ok\tweekly job last succeeded 7d ago')"
}

@test "heartbeat が数値でなければ fail で、消して再実行するよう添える" {
    weekly_installed
    printf 'oops\n' >"$HDIR/weekly-heartbeat"
    run weekly
    assert_success
    assert_line --regexp "^fail	weekly-heartbeat is not a number — delete ${HDIR}/weekly-heartbeat and check "
    refute_line --regexp '^ok	weekly'
}

@test "heartbeat が先頭 0 付きでも 10 進数として判定する(8 進数として落ちない)" {
    weekly_installed
    printf '0899\n' >"$HDIR/weekly-heartbeat"
    run weekly
    assert_success
    assert_line --regexp '^fail	weekly job last succeeded [0-9]+d ago — '
}

@test "heartbeat が無く、plist を置いてから 1 周期経っていなければ ok(初回がまだ)で never と出す" {
    weekly_installed
    run weekly
    assert_success
    assert_line --regexp '^ok	weekly job has not run yet'
    assert_line "$(printf 'summary\tweekly: never')"
    refute_line --regexp '^(warn|fail)'
}

@test "heartbeat が無く、plist を置いてから 1 周期経っていれば fail" {
    weekly_installed
    touch -t 202001010000 "$PLIST"
    run weekly
    assert_success
    assert_line --regexp '^fail	weekly job has never succeeded since it was installed — check '
}

@test "plist があるのに入口スクリプトが無ければ fail" {
    weekly_installed
    rm "$HOME/.claude/scripts/harness-weekly.sh"
    heartbeat_days_ago 0
    run weekly
    assert_success
    assert_line --regexp "^fail	harness-weekly\.sh is not deployed or not executable — run 'chezmoi apply'"
}

@test "macOS で plist が無ければ warn で、chezmoi apply を案内する" {
    run weekly
    assert_success
    assert_output "$(printf "warn\tweekly job not installed (%s missing) — run 'chezmoi apply'" "$PLIST")"
}

@test "launchd の無い OS では plist が無ければ何も出さない" {
    stub_uname Linux
    heartbeat_days_ago 30
    run weekly
    assert_success
    assert_output ''
}
