# pending の選別(harness-select-pending.sh)の振る舞い検査。
#
# 偽の $HOME に検出器と選別のスクリプトを本来の配置先(~/.claude/scripts/)へ置き、
# transcript は検出器の fixture を ~/.claude/projects/ の下に写して使う。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    PROJECTS="$HOME/.claude/projects/-work-repo"
    mkdir -p "$HDIR" "$PROJECTS" "$HOME/.claude/scripts"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-detect-failures.sh" \
        "$HOME/.claude/scripts/harness-detect-failures.sh"
    SCRIPT="$HOME/.claude/scripts/harness-select-pending.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-select-pending.sh" "$SCRIPT"
    FIXTURES="$BATS_TEST_DIRNAME/fixtures/harness-detect-failures"
    PENDING="$HDIR/pending.jsonl"
    LEDGER="$HDIR/detections.jsonl"
}

# add_pending <session_id> <transcript_path>
add_pending() {
    printf '{"session_id":"%s","transcript_path":"%s","cwd":"/work/repo","recorded_epoch":1}\n' "$1" "$2" >>"$PENDING"
}

# add_session <session_id> <fixture>: fixture を transcript として置き、pending に積む
add_session() {
    cp "$FIXTURES/$2.jsonl" "$PROJECTS/$1.jsonl"
    add_pending "$1" "$PROJECTS/$1.jsonl"
}

@test "失敗の無いセッションを pending から外し、失敗のあるセッションを残す" {
    add_session clean1 clean
    add_session err1 tool-error
    add_session ci1 ci-failure
    run --separate-stderr bash "$SCRIPT" --run run-1
    assert_success
    assert_output 'harness-select-pending: scanned=3 selected=2 dropped=1 not_scanned=0'
    run jq -r .session_id "$PENDING"
    assert_output "$(printf '%s\n' err1 ci1)"
}

@test "セッションごとの信号別の件数を、失敗の無いセッションも含めて記録する" {
    add_session clean1 clean
    add_session err1 tool-error
    add_session ci1 ci-failure
    run bash "$SCRIPT" --run run-1
    assert_success
    run jq -c '{session_id, run, counts}' "$LEDGER"
    assert_output "$(printf '%s\n' \
        '{"session_id":"clean1","run":"run-1","counts":{}}' \
        '{"session_id":"err1","run":"run-1","counts":{"tool_error":3}}' \
        '{"session_id":"ci1","run":"run-1","counts":{"ci_failure":2}}')"
    run jq -e --arg today "$(date +%Y-%m-%d)" 'select(.date != $today)' "$LEDGER"
    assert_failure
}

@test "記録済みのセッションは次の run で数え直さない" {
    add_session err1 tool-error
    run bash "$SCRIPT" --run run-1
    assert_success
    add_session err2 repeat
    run bash "$SCRIPT" --run run-2
    assert_success
    run jq -c '[.session_id, .run]' "$LEDGER"
    assert_output "$(printf '%s\n' '["err1","run-1"]' '["err2","run-2"]')"
}

@test "transcript を読めない・projects の外・.. を含むエントリには触れない(reflect が落とす)" {
    add_pending gone "$PROJECTS/gone.jsonl"
    mkdir -p "$BATS_TEST_TMPDIR/outside"
    cp "$FIXTURES/clean.jsonl" "$BATS_TEST_TMPDIR/outside/x.jsonl"
    add_pending outside "$BATS_TEST_TMPDIR/outside/x.jsonl"
    add_pending dotdot "$PROJECTS/../../../outside/x.jsonl"
    cp "$FIXTURES/clean.jsonl" "$PROJECTS/notjsonl.txt"
    add_pending notjsonl "$PROJECTS/notjsonl.txt"
    before=$(cat "$PENDING")
    run --separate-stderr bash "$SCRIPT" --run run-1
    assert_success
    assert_output 'harness-select-pending: scanned=0 selected=0 dropped=0 not_scanned=4'
    assert_equal "$(cat "$PENDING")" "$before"
    assert [ ! -s "$LEDGER" ]
}

@test "projects への symlink を経由したパスも正規化して受け付ける" {
    ln -s "$HOME/.claude/projects" "$BATS_TEST_TMPDIR/link"
    cp "$FIXTURES/clean.jsonl" "$PROJECTS/c.jsonl"
    add_pending c "$BATS_TEST_TMPDIR/link/-work-repo/c.jsonl"
    run --separate-stderr bash "$SCRIPT"
    assert_success
    assert_output 'harness-select-pending: scanned=1 selected=0 dropped=1 not_scanned=0'
}

@test "--run を省くと run は manual になる" {
    add_session err1 tool-error
    run bash "$SCRIPT"
    assert_success
    run jq -r .run "$LEDGER"
    assert_output manual
}

@test "pending が無ければ何もせずに成功する" {
    run --separate-stderr bash "$SCRIPT" --run run-1
    assert_success
    assert_output 'harness-select-pending: scanned=0 selected=0 dropped=0 not_scanned=0'
    assert [ ! -e "$PENDING" ]
}

@test "検出器が無ければ pending を変えずに失敗する" {
    add_session clean1 clean
    rm "$HOME/.claude/scripts/harness-detect-failures.sh"
    before=$(cat "$PENDING")
    run --separate-stderr bash "$SCRIPT" --run run-1
    assert_failure 1
    [[ "$stderr" == *harness-detect-failures.sh* ]]
    assert_equal "$(cat "$PENDING")" "$before"
}

@test "選別の間に追記された pending の行を失わない" {
    add_session clean1 clean
    # 検出器を、呼ばれたときに pending へ 1 行追記するものに差し替える(SessionEnd hook の並行追記の再現)
    cat >"$HOME/.claude/scripts/harness-detect-failures.sh" <<'EOF'
#!/usr/bin/env bash
printf '{"session_id":"late","transcript_path":"/x","cwd":"/","recorded_epoch":2}\n' >>"$HOME/.claude/harness/pending.jsonl"
EOF
    run bash "$SCRIPT" --run run-1
    assert_success
    run jq -r .session_id "$PENDING"
    assert_output late
}
