setup() {
    load 'helpers/setup'
    PROFILE="$BATS_TEST_DIRNAME/../dot_config/nono/profiles/claude-seal.json"
    # nono はローカル専用(CI runner には無い)。この suite の全テストが nono に
    # 依存するので、ガードは各 @test に貼らず setup() で一括して skip する。
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
}

# `nono why` は -s (--silent) でもALLOWED/DENIED の判定行と Reason は出す。
# 付けないと毎回アップデート確認のバナーが出て 1 呼び出しあたり約 3 倍遅い。
why() {
    nono why -s --path "$1" --op read --profile "$PROFILE"
}

@test "claude-seal.json validates against the nono profile schema" {
    run nono profile validate "$PROFILE"
    assert_success
}

@test "claude-seal profile denies read on SSH private key" {
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
    run why "$HOME/.ssh/id_rsa"
    assert_success
    assert_output --partial "DENIED"
}

@test "claude-seal profile allows read on \$HOME/ghq (contrast pair)" {
    run why "$HOME/ghq"
    assert_success
    assert_output --partial "ALLOWED"
}

# --- ~/.config/git 配下: Claude Code の git が辿る設定チェーン ---------------
# settings.json.tmpl の env GIT_CONFIG_GLOBAL は ~/.config/git/claude-code.inc を
# 指し、そこから include ~/.gitconfig → includeIf → ~/.config/git/personal.inc と
# 辿る。git は GIT_CONFIG_GLOBAL・include・includeIf のいずれかが存在するのに
# 読めない(EPERM)と `fatal: unable to access ...: Operation not permitted` で
# あらゆるサブコマンドが失敗する(nono 内で実測、2026-09-11)。~/.config/git は
# git_config グループの grant 対象外なので、プロファイルが filesystem.read で
# ディレクトリごと grant している。チェーン上の各ファイルを個別に確認する。

@test "claude-seal profile allows read on the ~/.config/git directory" {
    run why "$HOME/.config/git"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile allows read on the Claude Code git config override (GIT_CONFIG_GLOBAL)" {
    run why "$HOME/.config/git/claude-code.inc"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile allows read on the Claude Code git credential helper" {
    run why "$HOME/.config/git/claude-code-credential-helper.sh"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile allows read on personal.inc (includeIf target of ~/.gitconfig)" {
    # このリポジトリの worktree (gitdir が ~/.local/share/chezmoi/ 配下) では
    # includeIf が必ず発火する。ここが読めないと claude-code.inc が読めても
    # 1 段深いところで同じ fatal になる。
    run why "$HOME/.config/git/personal.inc"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile allows read on the ai-agent git signing key" {
    # Claude Code の git は claude-code.inc 経由でこの鍵(~/.ssh 外に置いた
    # AI エージェント専用の署名鍵)で commit 署名する。読めないと ssh-keygen -Y sign
    # が `Couldn't load public key` → `fatal: failed to write commit object` になる。
    run why "$HOME/.config/git/signing/ai-agent"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile allows read on ~/.gitignore_personal (core.excludesfile via personal.inc)" {
    # personal.inc が core.excludesfile を ~/.gitignore_personal に差し替える。
    # $HOME 直下なので ~/.config/git のディレクトリ grant の外。読めないと git は
    # warning を出したうえで global excludes を 1 件も適用しなくなる。
    run why "$HOME/.gitignore_personal"
    assert_success
    assert_output --partial "ALLOWED"
}
