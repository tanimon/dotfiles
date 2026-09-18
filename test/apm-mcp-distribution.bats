# MCP の配布先(#312)の振る舞いテスト。
# 決定と実測の根拠: docs/adr/0006-apm-owns-only-the-mcp-servers-table-of-codex-config.md
#
# 前半は Source(dot_apm/apm.yml と install スクリプト)の静的検査で、apm が無くても走る。
# 後半は偽 HOME に対して実際に `apm install --global` を走らせ、APM が Target に
# 何を書き・何を残し・何を消すかを検査する。apm が無い環境では skip するが、
# bats が `# skip <理由>` を必ず出力するので、緑の実行が「検査した」と詐称しない。
setup() {
    load 'helpers/setup'
    REPO="$BATS_TEST_DIRNAME/.."
    APM_YML="$REPO/dot_apm/apm.yml"
    INSTALL_SCRIPT="$REPO/.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$HOME/.apm" "$HOME/.codex" "$TMPDIR"
}

require_apm() {
    command -v apm >/dev/null 2>&1 || skip "apm CLI が見つからないため配布の実測を省略した(Source の静的検査のみ実行済み)"
}

# 今日の実機の状態を偽 HOME に再現する:
#   - ~/.codex/config.toml には Codex 自身が入れた node_repl、手で無効化した
#     [mcp_servers.codex](enabled = false)、[projects.*] の trust 記録がある
#   - lock には claude Target の codex サーバーが載っている(= 旧 apm.yml で install 済み)
seed_current_machine_state() {
    cat >"$HOME/.codex/config.toml" <<'EOF'
model = "gpt-5.2-codex"

[mcp_servers.node_repl]
args = []
command = "/opt/fixture/node_repl"
startup_timeout_sec = 120

[mcp_servers.codex]
command = "codex"
args = [
    "-m",
    "gpt-5.2-codex",
    "mcp-server",
]
enabled = false

[projects."/fixture/project"]
trust_level = "trusted"
EOF
    # 旧 apm.yml (target: claude / codex サーバーあり) で 1 度 install し、lock に
    # claude Target の codex を載せる。これが無いと prune の検査が空振りする
    # (APM は lock に無いエントリを消さない)。
    cat >"$HOME/.apm/apm.yml" <<'EOF'
name: tanimon-global
version: 1.0.0
target: claude

dependencies:
  mcp:
    - name: code-review-graph
      registry: false
      transport: stdio
      command: uvx
      args: ["code-review-graph", "serve"]
    - name: codex
      registry: false
      transport: stdio
      command: codex
      args: ["-m", "gpt-5.2-codex", "mcp-server"]
    - name: deepwiki
      registry: false
      transport: http
      url: https://mcp.deepwiki.com/mcp
EOF
    (cd "$HOME" && apm install --global >/dev/null 2>&1)
}

# このリポジトリの apm.yml を配って install する(= 変更後の状態)
install_repo_manifest() {
    cp "$APM_YML" "$HOME/.apm/apm.yml"
    (cd "$HOME" && apm install --global 2>&1)
}

@test "apm.yml は claude と codex を配布先に宣言する" {
    run grep -A3 '^targets:' "$APM_YML"
    assert_success
    assert_output --partial '- claude'
    assert_output --partial '- codex'
}

@test "apm.yml は codex MCP サーバーを宣言しない" {
    # サーバー単位の target 指定が APM 非対応のため配布は all-or-nothing で、
    # codex サーバーを残すと Codex 自身に再帰的に配られる(ADR 0006)
    run grep -n '^      command: codex$' "$APM_YML"
    assert_failure
}

@test "install スクリプトは --target claude,codex を渡す" {
    run grep -F -- '--target claude,codex' "$INSTALL_SCRIPT"
    assert_success
}

@test "install スクリプトは targets: との二重宣言の理由を残している" {
    # --target を省略すると auto-detect にフォールバックして検出された全ランタイムへ
    # fan out する。宣言が 1 箇所だけだと、その罠にフェイルオープンで落ちる
    run grep -c 'fan out\|fan-out\|auto-detect' "$INSTALL_SCRIPT"
    assert_success
    [ "$output" -ge 1 ]
}

@test "配布後、両製品に code-review-graph と deepwiki が入る" {
    require_apm
    seed_current_machine_state
    install_repo_manifest

    run cat "$HOME/.claude.json"
    assert_success
    assert_output --partial 'code-review-graph'
    assert_output --partial 'deepwiki'

    run cat "$HOME/.codex/config.toml"
    assert_success
    assert_output --partial '[mcp_servers.code-review-graph]'
    assert_output --partial '[mcp_servers.deepwiki]'
}

@test "配布後、claude から codex サーバーが prune される" {
    require_apm
    seed_current_machine_state
    install_repo_manifest

    run grep -c '"codex"' "$HOME/.claude.json"
    assert_output '0'
}

@test "配布は lock に名前の無いエントリと Runtime State を壊さない" {
    require_apm
    seed_current_machine_state
    install_repo_manifest

    run cat "$HOME/.codex/config.toml"
    assert_success
    # Codex 自身が入れたサーバー(lock に名前が無い)
    assert_output --partial '[mcp_servers.node_repl]'
    # trust 記録は Runtime State であり APM の所有外
    assert_output --partial '[projects."/fixture/project"]'
}

@test "prune は APM が書いていない同名エントリも消す" {
    require_apm
    seed_current_machine_state
    install_repo_manifest

    # 手で無効化した [mcp_servers.codex] は APM が codex 側へ書いたものではないが、
    # lock に 'codex' という名前が載っているため配布先すべてから削除される。
    # ここでは無効化のためだけに存在していたエントリなので結果は意図どおりだが、
    # 「APM が書いていないものは触らない」ではなく「lock に名前が無いものは触らない」
    # が正しい不変条件であることを固定する(ADR 0006)。
    run grep -c 'mcp_servers.codex' "$HOME/.codex/config.toml"
    assert_output '0'
}
