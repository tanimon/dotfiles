# MCP の配布先(#312)の振る舞いテスト。
# 決定と実測の根拠: docs/adr/0006-apm-owns-only-the-mcp-servers-table-of-codex-config.md
#
# 前半は Source(dot_apm/apm.yml と install スクリプト)の静的検査で、apm が無くても走る。
# 後半は偽 HOME に対して実際に `apm install --global` を走らせ、APM が Target に
# 何を書き・何を残し・何を消すかを検査する。apm が無い環境では skip するが、
# bats が `# skip <理由>` を必ず出力するので、緑の実行が「検査した」と詐称しない。
#
# 配布先の宣言は apm.yml の `targets:` と install スクリプトの `--target` に二重化
# されている(ADR 0006)。「claude と codex に入っている」という下限だけを見ると、
# 片方の宣言が壊れて auto-detect にフォールバックした状態でも緑になる — 実際に
# `targets:` を改名すると kiro まで配られた。そのため配布先の検査は
#   A: `targets:` だけが効いている経路
#   B: `--target` だけが効いている経路(= 本番のコマンド)
#   C: 両方欠けた negative control(A/B のアサーションが破れることを示す)
# の 3 本を Contrast Pair として持ち、lock の配布先集合が claude と codex 「だけ」
# であることを上限つきでアサートする。
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

# このリポジトリの apm.yml を配って install する(= 変更後の状態)。
# 配布先は apm.yml の `targets:` だけで決まる経路。
install_repo_manifest() {
    cp "$APM_YML" "$HOME/.apm/apm.yml"
    (cd "$HOME" && apm install --global 2>&1)
}

# `targets:` キーを改名して無効化し、install スクリプトと同じ `--target` で配る。
# 二重宣言のうち CLI 側だけが効いている状態 = 本番のコマンドそのもの。
install_repo_manifest_via_cli_target() {
    sed 's/^targets:/targetz:/' "$APM_YML" >"$HOME/.apm/apm.yml"
    (cd "$HOME" && apm install --global --target claude,codex 2>&1)
}

# 二重宣言が両方とも効いていない状態。APM は auto-detect にフォールバックする。
install_repo_manifest_with_neither_declaration() {
    sed 's/^targets:/targetz:/' "$APM_YML" >"$HOME/.apm/apm.yml"
    (cd "$HOME" && apm install --global 2>&1)
}

# apm.yml の `targets:` と install スクリプトの `--target` を、それぞれ
# 正規化した配布先リスト(ソート済みのカンマ区切り)として取り出す。
# 二重宣言は「片方が壊れても fan out しない」ための冗長化なので、2 つが食い違うと
# fail-safe ではなく silent divergence になる: `apm install --help` の解決順は
# `--target` > apm.yml `targets:` > auto-detect なので、apm.yml 側にだけ足した
# 配布先は本番では一切効かない。apm を必要としない静的検査なので CI でも走る。
yml_targets() {
    sed -n '/^targets:/,/^[^[:space:]#-]/p' "$APM_YML" |
        sed -n 's/^[[:space:]]*-[[:space:]]*//p' | sort | paste -sd, -
}

script_targets() {
    sed -n "s/^apm_targets='\(.*\)'\$/\1/p" "$INSTALL_SCRIPT" |
        tr ',' '\n' | sort | paste -sd, -
}

# lock の deployments に載った配布先ランタイムを重複なく取り出して照合する。
# ファイルシステムの副作用(`~/.kiro` が生えたか)より安定する — 検出される
# 第 3 のランタイムがマシンごとに違っても、この集合の上限は変わらない。
assert_distributed_to_claude_and_codex_only() {
    run bash -c "grep '^  runtime: ' \"\$HOME/.apm/apm.lock.yaml\" | sort -u"
    assert_success
    assert_output $'  runtime: claude\n  runtime: codex'
}

@test "apm.yml は claude と codex 「だけ」を配布先に宣言する" {
    # 下限(claude と codex が居る)だけを見ると、4 つ目の配布先が足された状態でも
    # 緑になる。上限つきで照合する。
    run yml_targets
    assert_success
    assert_output 'claude,codex'
}

@test "apm.yml は codex MCP サーバーを宣言しない" {
    # サーバー単位の target 指定が APM 非対応のため配布は all-or-nothing で、
    # codex サーバーを残すと Codex 自身に再帰的に配られる(ADR 0006)。
    # 見るのはサーバーの宣言そのもの(name)で、command の綴りではない —
    # `command` が別物の `- name: codex` も同じ再帰を起こすため。
    # `assert_failure 1` は「マッチしなかった」だけを受け付ける。status を
    # 指定しないと、読めないファイルに対する grep の 2 でも緑になる。
    run grep -nE '^[[:space:]]*- name: codex[[:space:]]*$' "$APM_YML"
    assert_failure 1
}

@test "install スクリプトは apm.yml と同じ配布先を --target に渡す" {
    # 二重宣言の一致を CI(apm 不在)でも強制する。宣言が食い違っていても
    # 「A: targets: だけ」「B: --target だけ」の実測ケースは両方とも緑になる
    # ため(どちらも単独では正しく限定できてしまう)、静的な照合が唯一の検出点。
    run script_targets
    assert_success
    assert_output 'claude,codex'

    run yml_targets
    assert_success
    assert_output 'claude,codex'

    # 変数を宣言しただけでコマンドに渡し忘れる形を塞ぐ
    run grep -F -- '--target "${apm_targets}"' "$INSTALL_SCRIPT"
    assert_success
}

@test "install スクリプトは targets: との二重宣言の理由を残している" {
    # --target を省略すると auto-detect にフォールバックして検出された全ランタイムへ
    # fan out する。宣言が 1 箇所だけだと、その罠にフェイルオープンで落ちる
    run grep -qE 'fan out|fan-out|auto-detect' "$INSTALL_SCRIPT"
    assert_success
}

@test "A: apm.yml の targets: だけで配布先が claude と codex に限定される" {
    require_apm
    seed_current_machine_state
    install_repo_manifest

    assert_distributed_to_claude_and_codex_only
}

@test "B: targets: が壊れても --target が配布先を claude と codex に限定する" {
    require_apm
    seed_current_machine_state
    install_repo_manifest_via_cli_target

    assert_distributed_to_claude_and_codex_only
}

@test "C: 宣言が両方欠けると auto-detect にフォールバックして fan out する" {
    require_apm
    seed_current_machine_state
    install_repo_manifest_with_neither_declaration

    # A/B のアサーションが「どんな配り方でも緑になる空虚な検査」ではないことを
    # 示す negative control。何が余分に検出されるかはマシンに何が入っているかに
    # 依存するので(実測では kiro)、余分が出なかった場合は緑にせず skip する。
    run bash -c "grep '^  runtime: ' \"\$HOME/.apm/apm.lock.yaml\" | sort -u"
    assert_success
    if [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -le 2 ]; then
        skip "このマシンには claude / codex 以外の global-capable ランタイムが無く、fan out を観測できない"
    fi
    refute_output $'  runtime: claude\n  runtime: codex'
}

@test "配布後、両製品に deepwiki が入り、宣言を外した code-review-graph は prune される" {
    require_apm
    seed_current_machine_state
    install_repo_manifest

    # code-review-graph は /doctor(2026-09-18)で全トランスクリプト 0 回と判定して
    # apm.yml から外した。fixture の旧 apm.yml には残してあるので、この検査は
    # 「宣言を外したサーバーが両 Target から消えること」の負の対照も兼ねる。
    run cat "$HOME/.claude.json"
    assert_success
    assert_output --partial 'deepwiki'
    refute_output --partial 'code-review-graph'

    run cat "$HOME/.codex/config.toml"
    assert_success
    assert_output --partial '[mcp_servers.deepwiki]'
    refute_output --partial '[mcp_servers.code-review-graph]'
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

    # 前提: seed が [mcp_servers.codex] を実際に置いたこと。これが無いと本ケースは
    # 「最初から無かったものが無い」を検査する空虚なケースへ黙って変わる。
    run grep -c '^\[mcp_servers\.codex\]$' "$HOME/.codex/config.toml"
    assert_output '1'

    install_repo_manifest

    # 手で無効化した [mcp_servers.codex] は APM が codex 側へ書いたものではないが、
    # lock に 'codex' という名前が載っているため配布先すべてから削除される。
    # ここでは無効化のためだけに存在していたエントリなので結果は意図どおりだが、
    # 「APM が書いていないものは触らない」ではなく「lock に名前が無いものは触らない」
    # が正しい不変条件であることを固定する(ADR 0006)。
    run grep -c 'mcp_servers.codex' "$HOME/.codex/config.toml"
    assert_output '0'
}
