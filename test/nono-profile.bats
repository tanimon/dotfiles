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

@test "claude-seal profile denies read on SSH private key" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    # --profile はプロファイル名だけでなくファイルパスも受け付ける。名前解決だと
    # ~/.config/nono/profiles/claude-seal.json (chezmoi apply でデプロイされた側)
    # を見てしまい、このリポジトリの編集内容を検証できないため、$PROFILE (リポジトリ
    # 内のソース) をパスとして直接渡す。
    run nono why --path "$HOME/.ssh/id_rsa" --op read --profile "$PROFILE"
    assert_success
    assert_output --partial "DENIED"
}

@test "claude-seal profile allows read on \$HOME/ghq (contrast pair)" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    run nono why --path "$HOME/ghq" --op read --profile "$PROFILE"
    assert_success
    assert_output --partial "ALLOWED"
}
