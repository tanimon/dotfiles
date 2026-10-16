setup() {
    load 'helpers/setup'
    PROFILE="$BATS_TEST_DIRNAME/../dot_config/nono/profiles/claude-seal.json"
    # nono はローカル専用(CI runner には無い)。この suite の全テストが nono に
    # 依存するので、ガードは各 @test に貼らず setup() で一括して skip する。
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    # nono の内側(claude-seal が INSIDE_NONO_SANDBOX を注入する。普段の Claude Code
    # セッションもここ)では、入れ子の nono が profile の存在しないパス
    # (~/Library/Application Support/orca/codex-accounts 等)を canonicalize する際に
    # ENOENT ではなく EPERM を受け、`nono why` が判定前に失敗する(実測)。EPERM になる
    # 原因は未確認で、外側の境界が親ディレクトリを grant していないためと推定している。
    # `nono profile validate` は内側でも通る(nono 0.79.0 で実測。理由は未確認)。
    # 内側でも通ると実測したテストだけを tag 付けで残し、それ以外は skip する。
    # tag の無い新しいテストは内側で skip される側に倒れる。tag の綴り違いや付け忘れも
    # 黙って skip になるので、skip 理由に判定に使う tag 名を出して確かめられるようにする。
    # CI にも nono は無いため、skip されたテストは素のターミナルから実行しない限り走らない。
    if [[ -n "${INSIDE_NONO_SANDBOX:-}" ]] && [[ " ${BATS_TEST_TAGS[*]} " != *" runs-inside-nono "* ]]; then
        skip "INSIDE_NONO_SANDBOX が設定されている(nono の内側)ため入れ子の nono を検証できない(tag runs-inside-nono なし)。素のターミナルで実行すること"
    fi
}

# `nono why` は -s (--silent) でもALLOWED/DENIED の判定行と Reason は出す。
# 付けないと毎回アップデート確認のバナーが出て 1 呼び出しあたり約 3 倍遅い。
why() {
    nono why -s --path "$1" --op read --profile "$PROFILE"
}

# bats test_tags=runs-inside-nono
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

# --- 週次ジョブの plist ------------------------------------------------------
# briefing と doctor は plist の有無で「週次ジョブが導入済みか」を判定し、無ければ
# heartbeat を検査しない。普段の claude は nono の内側で動くので、plist が読めない
# と停止の警告が黙って消える(nono 内で `test -f` が exit 1 になることを実測)。

@test "claude-seal profile allows read on the weekly job plist" {
    run why "$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile denies write on the weekly job plist (contrast pair)" {
    # plist は境界の外で無人実行される。内側から書けると境界の外へ出られる
    # (dot_config/nono/CLAUDE.md の「境界の外で無人実行するもの」)。
    run nono why -s --path "$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist" --op write --profile "$PROFILE"
    assert_success
    assert_output --partial "DENIED"
}

# --- web-verify の個人設定 ---------------------------------------------------
# web-verify skill は ~/.config/web-verify/config.json の default を検証資産の既定の
# 保存場所として読む。読めないと「設定が無い」と区別できず、nono の内側では毎回
# 質問するか blocked で止まる。書き込みは許さない(エージェントが自分の既定値を変えられないように)。
# nono は存在しないパスの grant を評価しない(grant があっても path_not_granted。実測)ので、
# 実在の ~/.config/web-verify の有無に左右されないよう、XDG_CONFIG_HOME を一時ディレクトリに
# 差し替えて判定する。一時ディレクトリは grant の外に置く必要がある($TMPDIR は pack が許可しているので、
# そこに置くと grant を外しても ALLOWED になり対照にならない)ため $HOME 直下に作る。Claude Code の
# Bash サンドボックスの内側では $HOME に書けないので、そのときは skip する。nono は pack を
# $XDG_CONFIG_HOME/nono から解決するので、実物への symlink を置く。

web_verify_probe_home() {
    WEB_VERIFY_XDG="$(mktemp -d "$HOME/.nono-web-verify-probe.XXXXXX" 2>/dev/null)" ||
        skip "\$HOME に一時ディレクトリを作れない(Bash サンドボックスの内側)。素のターミナルで実行すること"
    mkdir -p "$WEB_VERIFY_XDG/web-verify"
    : >"$WEB_VERIFY_XDG/web-verify/config.json"
    ln -s "${XDG_CONFIG_HOME:-$HOME/.config}/nono" "$WEB_VERIFY_XDG/nono"
}

teardown() {
    if [[ -n "${WEB_VERIFY_XDG:-}" ]]; then
        rm -rf "$WEB_VERIFY_XDG"
    fi
}

web_verify_why() {
    XDG_CONFIG_HOME="$WEB_VERIFY_XDG" nono why -s --path "$WEB_VERIFY_XDG/web-verify/config.json" --op "$1" --profile "$2"
}

@test "claude-seal profile allows read on the web-verify personal config" {
    web_verify_probe_home
    run web_verify_why read "$PROFILE"
    assert_success
    assert_output --partial "ALLOWED"
}

@test "claude-seal profile denies read on the web-verify personal config without the grant (contrast pair)" {
    web_verify_probe_home
    jq '.filesystem.read -= ["$XDG_CONFIG_HOME/web-verify"]' "$PROFILE" >"$BATS_TEST_TMPDIR/no-grant.json"
    run web_verify_why read "$BATS_TEST_TMPDIR/no-grant.json"
    assert_success
    assert_output --partial "DENIED"
}

@test "claude-seal profile denies write on the web-verify personal config" {
    web_verify_probe_home
    run web_verify_why write "$PROFILE"
    assert_success
    assert_output --partial "DENIED"
}
