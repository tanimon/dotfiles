setup() {
    load 'helpers/setup'
    PROFILE="$BATS_TEST_DIRNAME/../dot_config/nono/profiles/claude-seal.json"
}

@test "claude-seal.json validates against the nono profile schema" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    run nono profile validate "$PROFILE"
    assert_success
}
