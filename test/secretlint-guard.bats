setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_secretlint-guard.sh"
    # secretlint 本体には依存しない。$PATH の先頭に偽の secretlint を置き、
    # 引数に "leak" を含むパスなら失敗、それ以外は成功させる。
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$FAKE_BIN"
    cat >"$FAKE_BIN/secretlint" <<'FAKE'
#!/usr/bin/env bash
printf 'called:%s\n' "$1" >>"${FAKE_LOG:?}"
case "$1" in *leak*) echo "fake finding"; exit 1 ;; *) exit 0 ;; esac
FAKE
    chmod +x "$FAKE_BIN/secretlint"
    export PATH="$FAKE_BIN:$PATH"
    export FAKE_LOG="$BATS_TEST_TMPDIR/calls.log"
    : >"$FAKE_LOG"
}

# Claude Code と同じ形で呼ぶ: 判断材料は stdin の PostToolUse ペイロードだけ。
hook() {
    jq -n --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p}}' | bash "$SCRIPT"
}

# --- 対で書く: 出るべきケースと出ないべきケース ---------------------------

@test "対象パスで secretlint が失敗したら exit 2 と stderr" {
    run hook "$BATS_TEST_TMPDIR/leak.env"
    assert_failure 2
    assert_output --partial 'potential secret detected in'
    assert_output --partial 'fake finding'
}

@test "対象パスで secretlint が通れば無出力 exit 0" {
    run hook "$BATS_TEST_TMPDIR/clean.env"
    assert_success
    assert_output ''
    run cat "$FAKE_LOG"
    assert_output --partial 'called:'
}

@test "対象外パスでは secretlint を呼ばず無出力 exit 0" {
    run hook "$BATS_TEST_TMPDIR/leak.ts"
    assert_success
    assert_output ''
    run cat "$FAKE_LOG"
    assert_output ''
}

@test "credentials / secret を含むパスも対象" {
    run hook "$BATS_TEST_TMPDIR/config/leak-credentials.json"
    assert_failure 2
    run hook "$BATS_TEST_TMPDIR/leak_secret.yaml"
    assert_failure 2
}

@test "tool_input.file_path が無ければ無出力 exit 0" {
    run bash -c "jq -n '{tool_name:\"Write\",tool_input:{}}' | bash '$SCRIPT'"
    assert_success
    assert_output ''
}

@test "\$CLAUDE_FILE は読まない(空の stdin + 環境変数だけでは発火しない)" {
    CLAUDE_FILE="$BATS_TEST_TMPDIR/leak.env" run bash -c "jq -n '{tool_input:{}}' | bash '$SCRIPT'"
    assert_success
    assert_output ''
}
