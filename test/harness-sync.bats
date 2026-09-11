# harness/bin/harness.sh の振る舞いテスト。
# すべて harness.sh を外部コマンドとして呼び、内部関数は直接呼ばない(spec「テスト方針」)。
setup() {
    load 'helpers/setup'
    HARNESS="$BATS_TEST_DIRNAME/../harness/bin/harness.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    ROOT="$BATS_TEST_TMPDIR/root"
    SRC="$BATS_TEST_TMPDIR/src"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
    export HARNESS_ADAPTER_DIR="$BATS_TEST_TMPDIR/adapters"
    mkdir -p "$HOME" "$TMPDIR" "$ROOT" "$SRC" "$STUB_BIN" "$HARNESS_ADAPTER_DIR"
    # stub を本物の claude / codex / cursor / apm より先に解決させる
    export PATH="$STUB_BIN:$PATH"
    unset HARNESS_FIXTURE_FAIL
    make_flaky_adapter
}

# make_stub NAME VERSION [HELP_TEXT]: --version と --help の出力を制御する stub 実行ファイルを作る
make_stub() {
    local name=$1 version=$2 help=${3:-usage}
    cat >"$STUB_BIN/$name" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    --version) echo "$name version $version" ;;
    --help) printf '%s\n' "$help" ;;
    *) exit 64 ;;
esac
EOF
    chmod +x "$STUB_BIN/$name"
}

# stub_all: 4 runtime すべてを write_manifest の範囲内のバージョンで用意する。
# bin 名は fixture-* にする: "codex" のままだと stub を消しても PATH 上の本物の codex が
# 見つかって「欠落」を再現できない(ローカルでは失敗し CI では通る、というテストになる)
stub_all() {
    make_stub fixture-claude 2.1.268 "  --settings <file>  Load settings"
    make_stub fixture-codex 0.147.0
    make_stub fixture-cursor 3.17.21
    make_stub fixture-apm 0.30.0
}

# write_manifest [TARGETS_JSON]: 4 runtime を宣言した manifest を書く(targets は引数、既定は空)
write_manifest() {
    cat >"$MANIFEST" <<EOF
{
  "version": 1,
  "runtimes": {
    "claude": {
      "bin": "fixture-claude", "minVersion": "2.0.0", "maxVerifiedVersion": "2.5.0",
      "capabilities": [ { "name": "settings", "args": ["--help"], "pattern": "--settings" } ]
    },
    "codex":  { "bin": "fixture-codex",  "minVersion": "0.100.0", "maxVerifiedVersion": "0.200.0" },
    "cursor": { "bin": "fixture-cursor", "minVersion": "3.0.0",   "maxVerifiedVersion": "3.99.0" },
    "apm":    { "bin": "fixture-apm",    "minVersion": "0.30.0",  "maxVerifiedVersion": "0.30.0" }
  },
  "targets": ${1:-[]}
}
EOF
}

# make_flaky_adapter: fixture adapter。HARNESS_FIXTURE_FAIL=1 なら exit 7、
# それ以外は target の content フィールドを Target 内容として書く
make_flaky_adapter() {
    cat >"$HARNESS_ADAPTER_DIR/flaky.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${HARNESS_FIXTURE_FAIL:-0}" != 1 ] || { echo "flaky: 強制失敗" >&2; exit 7; }
jq -r .content <<<"$3" >"$2"
EOF
    chmod +x "$HARNESS_ADAPTER_DIR/flaky.sh"
}

harness() {
    bash "$HARNESS" "$@"
}

# ---------- Task 1: 入口と manifest 検証 ----------

@test "コマンド無しは使い方を出して exit 64" {
    run harness
    assert_failure 64
    assert_output --partial '使い方'
}

@test "不明なコマンドは exit 64" {
    run harness frobnicate
    assert_failure 64
    assert_output --partial '不明なコマンド'
}

@test "init と update は未実装として exit 64" {
    stub_all
    write_manifest
    run harness init --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 64
    assert_output --partial '未実装'
    assert_output --partial '#322'
    run harness update --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 64
    assert_output --partial '#323'
}

@test "manifest ファイルが無ければ exit 2" {
    run harness check --manifest "$BATS_TEST_TMPDIR/nope.json" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'manifest: ファイルがありません'
}

@test "runtimes 欠落は暗黙検出として reject し、明示すれば通る(Contrast Pair)" {
    stub_all
    printf '{ "version": 1, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'runtimes を明示してください'

    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_success
}

@test "runtimes が空でも reject" {
    printf '{ "version": 1, "runtimes": {}, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'runtimes が空です'
}

@test "bin が auto の runtime は reject" {
    printf '{ "version": 1, "runtimes": { "claude": { "bin": "auto", "minVersion": "1.0.0" } }, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'runtimes.claude.bin に "auto" は使えません'
}

@test "version が 1 以外は reject" {
    printf '{ "version": 2, "runtimes": { "apm": { "bin": "apm", "minVersion": "0.30.0" } }, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'version は 1 でなければなりません'
}

@test "同じ path を 2 つの owner が持つ manifest は reject し、重複を除けば通る(Contrast Pair)" {
    stub_all
    write_manifest '[
      { "path": "AGENTS.md", "runtime": "codex", "owner": "flaky", "content": "a" },
      { "path": "AGENTS.md", "runtime": "codex", "owner": "other", "content": "b" }
    ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'target "AGENTS.md" の owner が重複しています (flaky, other)'

    write_manifest '[ { "path": "AGENTS.md", "runtime": "codex", "owner": "flaky", "content": "a" } ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    refute_output --partial 'owner が重複'
}

@test "adapter が見つからない owner は reject" {
    stub_all
    write_manifest '[ { "path": "x.md", "runtime": "codex", "owner": "nonexistent" } ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'owner "nonexistent" に対応する adapter がありません'
}

@test "宣言されていない runtime を持つ target は reject" {
    stub_all
    write_manifest '[ { "path": "x.md", "runtime": "gemini", "owner": "flaky", "content": "a" } ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'runtime "gemini" は runtimes に宣言されていません'
}

# ---------- Task 2: Capability Probe ----------

@test "4 runtime が揃っていれば OK 行 4 つで exit 0" {
    stub_all
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_success
    assert_line 'OK   runtime apm 0.30.0'
    assert_line 'OK   runtime claude 2.1.268'
    assert_line 'OK   runtime codex 0.147.0'
    assert_line 'OK   runtime cursor 3.17.21'
    assert_line 'harness check: 0 failures, 0 warnings'
}

@test "runtime が 1 つでも無ければ full check は FAIL し、残りは報告される" {
    stub_all
    rm "$STUB_BIN/fixture-codex"
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 1
    assert_line 'FAIL runtime codex: 見つかりません (bin: fixture-codex)'
    assert_line 'OK   runtime claude 2.1.268'
    assert_line 'harness check: 1 failures, 0 warnings'
}

@test "minVersion 未満は FAIL" {
    stub_all
    make_stub fixture-cursor 2.0.0
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 1
    assert_line 'FAIL runtime cursor 2.0.0: minVersion 3.0.0 未満'
}

@test "maxVerifiedVersion 超は WARN だけで exit 0" {
    stub_all
    make_stub fixture-claude 2.9.0 "  --settings <file>"
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_success
    assert_line 'WARN runtime claude 2.9.0: maxVerifiedVersion 2.5.0 を超えています (再検証が必要)'
    assert_line 'harness check: 0 failures, 1 warnings'
}

@test "capability の pattern が help に無ければ FAIL" {
    stub_all
    make_stub fixture-claude 2.1.268 "  --nothing-here"
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 1
    assert_line 'FAIL runtime claude 2.1.268: capability settings がありません (pattern: --settings)'
}

@test "バージョンを解釈できなければ FAIL" {
    stub_all
    make_stub fixture-apm unknown
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 1
    assert_output --partial 'FAIL runtime apm: バージョンを解釈できません'
}

@test "versionArgs で --version 以外のサブコマンドも使える" {
    stub_all
    cat >"$STUB_BIN/fixture-apm" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = version ] && echo "apm 0.30.0"
EOF
    chmod +x "$STUB_BIN/fixture-apm"
    cat >"$MANIFEST" <<'EOF'
{ "version": 1, "runtimes": { "apm": { "bin": "fixture-apm", "minVersion": "0.30.0", "versionArgs": ["version"] } }, "targets": [] }
EOF
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_success
    assert_line 'OK   runtime apm 0.30.0'
}

@test "--runtime で 1 runtime だけを明示選択でき、他の欠落は無視される" {
    stub_all
    rm "$STUB_BIN/fixture-codex"
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT" --runtime claude
    assert_success
    assert_line 'OK   runtime claude 2.1.268'
    refute_output --partial 'codex'

    run harness check --manifest "$MANIFEST" --root "$ROOT" --runtime codex
    assert_failure 1
    assert_line 'FAIL runtime codex: 見つかりません (bin: fixture-codex)'
    refute_output --partial 'claude'
}

@test "--runtime に manifest に無い名前を渡すと exit 2" {
    stub_all
    write_manifest
    run harness check --manifest "$MANIFEST" --root "$ROOT" --runtime gemini
    assert_failure 2
    assert_output --partial 'runtime "gemini" は manifest に宣言されていません'
}
