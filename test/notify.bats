setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_notify.sh"
    unset ORCA_PANE_KEY ORCA_AGENT_HOOK_PORT ORCA_AGENT_HOOK_TOKEN
    export HOME="$BATS_TEST_TMPDIR"
    export CLAUDE_NOTIFY_DRY_RUN=1
}

notify() {
    printf '%s' "$1" | bash "$SCRIPT"
}

setup_fake_terminal_notifier() {
    FAKEBIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKEBIN"
    TN_ARGS="$BATS_TEST_TMPDIR/tn-args.txt"
    export TN_ARGS
    cat > "$FAKEBIN/terminal-notifier" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$TN_ARGS"
EOF
    chmod +x "$FAKEBIN/terminal-notifier"
}

setup_fake_osascript() {
    FAKEBIN="${FAKEBIN:-$BATS_TEST_TMPDIR/bin}"
    mkdir -p "$FAKEBIN"
    OSA_MARKER="$BATS_TEST_TMPDIR/osa-called.txt"
    export OSA_MARKER
    cat > "$FAKEBIN/osascript" <<'EOF'
#!/bin/sh
echo called > "$OSA_MARKER"
EOF
    chmod +x "$FAKEBIN/osascript"
}

# --- suppression gates -------------------------------------------------

@test "all three orca env vars suppress the notification" {
    export ORCA_PANE_KEY=pane ORCA_AGENT_HOOK_PORT=1234 ORCA_AGENT_HOOK_TOKEN=tok
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output ''
}

@test "ORCA_PANE_KEY alone does not suppress" {
    export ORCA_PANE_KEY=pane
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
}

# --- classification -----------------------------------------------------

@test "permission_prompt classifies as 許可待ち with Glass sound" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "worker_permission_prompt also classifies as 許可待ち" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"worker_permission_prompt","message":"worker needs network access to example.com","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "idle_prompt classifies as 入力待ち and is silent" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
    assert_line 'sound='
}

@test "agent_needs_input classifies as 入力待ち and is silent" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"agent_needs_input","message":"reviewer needs your input","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
    assert_line 'sound='
}

@test "unrecognized notification_type degrades to 入力待ち rather than silence" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"future_unknown_type","message":"something new","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
    assert_line 'sound='
}

@test "absent notification_type falls back to the message regex" {
    payload=$(printf '{"hook_event_name":"Notification","message":"Claude needs your permission to use Bash","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "message-regex fallback matches approval, not just permission" {
    payload=$(printf '{"hook_event_name":"Notification","message":"Claude Code needs your approval for the plan","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=許可待ち'
    assert_output --partial 'sound=Glass'
}

@test "StopFailure without error classifies as エラー停止 with the fixed body" {
    payload=$(printf '{"hook_event_name":"StopFailure","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=エラー停止'
    assert_output --partial 'sound=Basso'
    assert_output --partial 'message=ターンが異常終了しました'
}

@test "StopFailure surfaces its error in the body" {
    payload=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=エラー停止'
    assert_line --partial 'message='
    assert_output --partial 'rate_limit'
}

@test "unknown event degrades to 入力待ち rather than silence" {
    payload=$(printf '{"hook_event_name":"SomeFutureEvent","message":"whatever","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial 'subtitle=入力待ち'
}

# --- input edge cases -----------------------------------------------------

@test "empty stdin exits 0 with no output" {
    run notify ''
    assert_success
    assert_output ''
}

@test "malformed JSON exits 0 with no output" {
    run notify 'not json at all'
    assert_success
    assert_output ''
}

@test "group carries the session_id" {
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"sess-abc","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_line 'group=claude-sess-abc'
}

@test "title carries the cwd basename" {
    base=$(basename "$HOME")
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    run notify "$payload"
    assert_success
    assert_output --partial "$base"
}

@test "diagnostic log records kind, notification_type, and error" {
    payload1=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"logprobe","session_id":"s1","cwd":"%s"}' "$HOME")
    payload2=$(printf '{"hook_event_name":"StopFailure","error":"rate_limit","session_id":"s1","cwd":"%s"}' "$HOME")
    notify "$payload1" >/dev/null
    notify "$payload2" >/dev/null
    notifylog="$HOME/.claude/logs/notify.log"
    assert [ -f "$notifylog" ]
    assert grep -q 'kind=入力待ち.*notification_type=idle_prompt.*message=logprobe' "$notifylog"
    assert grep -q 'kind=エラー停止.*error=rate_limit' "$notifylog"
}

@test "missing cwd falls back to \$PWD" {
    payload='{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1"}'
    run notify "$payload"
    assert_success
    assert_output --partial "$(basename "$PWD")"
}

# --- delivery backends ------------------------------------------------------

@test "terminal-notifier receives group, subtitle, sound, and ghostty click target" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash","session_id":"sess-xyz","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX= TMUX_PANE= run notify "$payload"
    assert_success
    assert [ -f "$TN_ARGS" ]
    assert grep -qx -- '-group' "$TN_ARGS"
    assert grep -qx -- 'claude-sess-xyz' "$TN_ARGS"
    assert grep -qx -- '許可待ち' "$TN_ARGS"
    assert grep -qx -- 'Glass' "$TN_ARGS"
    assert grep -q 'com.mitchellh.ghostty' "$TN_ARGS"
}

@test "silent kinds omit -sound" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX= TMUX_PANE= run notify "$payload"
    assert_success
    refute grep -qx -- '-sound' "$TN_ARGS"
}

@test "tmux click target jumps to the pane" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX=/tmp/fake-tmux TMUX_PANE=%7 run notify "$payload"
    assert_success
    assert grep -q 'select-pane' "$TN_ARGS"
}

@test "CLAUDE_NOTIFY_BACKEND=osascript forces the fallback" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    setup_fake_osascript
    export PATH="$FAKEBIN:$PATH"
    export CLAUDE_NOTIFY_BACKEND=osascript
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX= TMUX_PANE= run notify "$payload"
    assert_success
    assert [ -f "$OSA_MARKER" ]
    assert [ ! -f "$TN_ARGS" ]
}

@test "malformed TMUX_PANE does not reach -execute (injection guard)" {
    unset CLAUDE_NOTIFY_DRY_RUN
    setup_fake_terminal_notifier
    export PATH="$FAKEBIN:$PATH"
    payload=$(printf '{"hook_event_name":"Notification","notification_type":"idle_prompt","message":"hi","session_id":"s1","cwd":"%s"}' "$HOME")
    TERM_PROGRAM=ghostty TMUX=/tmp/fake-tmux TMUX_PANE="%1'; touch $BATS_TEST_TMPDIR/injected #" run notify "$payload"
    assert_success
    refute grep -q 'select-pane' "$TN_ARGS"
    assert grep -q 'com.mitchellh.ghostty' "$TN_ARGS"
}
