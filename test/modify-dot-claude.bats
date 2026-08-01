setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/modify_claude.json"
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

modify() {
    printf '%s' "$1" | bash "$SCRIPT" 2>/dev/null
}

@test "preserves existing data and replaces mcpServers" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    run modify '{"existingKey":"value","mcpServers":{}}'
    assert_success
    assert jq -e '.existingKey == "value"' <<< "$output"
    assert jq -e '.mcpServers | has("codex")' <<< "$output"
}

@test "empty stdin produces valid JSON with mcpServers" {
    export CHEZMOI_SOURCE_DIR="$REPO_ROOT"
    run modify ''
    assert_success
    assert jq -e 'has("mcpServers")' <<< "$output"
}

@test "missing source file passes through stdin" {
    export CHEZMOI_SOURCE_DIR="/tmp/nonexistent-dir"
    input='{"existingKey":"keep","mcpServers":{"old":"data"}}'
    run modify "$input"
    assert_success
    assert_equal "$output" "$input"
}
