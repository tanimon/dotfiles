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
    # このDENIEDは継承元claude-codeパックの組み込みdeny_credentialsグループに由来し、
    # claude-seal.json固有の記述を検証しているわけではない。claude-seal.json側が
    # 将来この保護を弱めた場合(例: $HOME/.ssh を filesystem.bypass_protection と
    # filesystem.allow の両方に追加した場合)の回帰検知として機能する。allow への
    # 追加だけでは deny_credentials グループが優先されて DENIED のままなので、
    # このテストが検知するのは bypass_protection を伴う明示的な緩和に限られる。
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

@test "claude-seal profile allows read on the ai-agent git signing key" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    # Claude Code の git は claude-code.inc 経由でこの鍵(~/.ssh 外に置いた
    # AI エージェント専用の署名鍵)で commit 署名する。~/.config/git 自体は
    # プロファイルで grant されていない(path_not_granted)ため、read_file への
    # 明示追加が無いと ssh-keygen -Y sign が鍵を読めず署名に失敗する。
    run nono why --path "$HOME/.config/git/signing/ai-agent" --op read --profile "$PROFILE"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile allows read on the Claude Code git config override (GIT_CONFIG_GLOBAL)" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    # settings.json.tmpl の env GIT_CONFIG_GLOBAL は ~/.config/git/claude-code.inc を
    # 指す。git はこのファイルを読めないと(存在するのに EPERM)
    # `fatal: unable to access '.../claude-code.inc': Operation not permitted` で
    # あらゆるサブコマンドが失敗する(nono 内で実測、2026-09-11)。~/.config/git は
    # git_config グループの grant 対象外なので、ファイル単位の read_file が必要。
    run nono why --path "$HOME/.config/git/claude-code.inc" --op read --profile "$PROFILE"
    assert_success
    assert_output --partial "ALLOWED"
    run nono why --path "$HOME/.config/git/claude-code-credential-helper.sh" --op read --profile "$PROFILE"
    assert_success
    assert_output --partial "ALLOWED"
}
