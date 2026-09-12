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

@test "./AGENTS.md と AGENTS.md を別 owner で持つ manifest は path 形式の段階で reject される" {
    stub_all
    write_manifest '[
      { "path": "./AGENTS.md", "runtime": "codex", "owner": "flaky", "content": "a" },
      { "path": "AGENTS.md", "runtime": "codex", "owner": "other", "content": "b" }
    ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'path は正規化された相対パスでなければなりません'
}

@test "../ を含む path は reject され --root の外に書かれない" {
    write_manifest '[ { "path": "../escaped.md", "runtime": "codex", "owner": "flaky", "content": "escaped" } ]'
    run sync
    assert_failure 2
    assert_output --partial 'path は正規化された相対パスでなければなりません'
    assert [ ! -e "$BATS_TEST_TMPDIR/escaped.md" ]
}

@test "file adapter は ../ を含む source を拒否する" {
    printf 'escaped\n' >"$BATS_TEST_TMPDIR/escaped.md"
    write_manifest '[ { "path": "AGENTS.md", "runtime": "codex", "owner": "file", "source": "../escaped.md" } ]'
    run sync
    assert_failure 1
    assert_line 'FAIL target AGENTS.md: adapter file が exit 1'
    assert_output --partial 'は正規化された相対パスでなければなりません'
}

@test "値のないオプションは exit 64" {
    run harness check --manifest
    assert_failure 64
    assert_output --partial 'には値が必要です'
}

@test "HOME 未設定で --root も無ければ exit 2" {
    stub_all
    write_manifest
    run env -u HOME bash "$HARNESS" check --manifest "$MANIFEST"
    assert_failure 2
    assert_output --partial 'HOME 未設定なら --root を指定してください'
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

# ---------- Task 3: Atomic Sync ----------

# two_targets: file adapter と flaky adapter の target を 1 つずつ持つ manifest と source を用意する。
# flaky を最後(index 1)に置くのは意図的: 「1 件目を置換してから 2 件目で失敗する」実装を
# Contrast Pair テストで捕まえるため、順序を変えないこと
two_targets() {
    printf 'from source v1\n' >"$SRC/agents.md"
    write_manifest '[
      { "path": "AGENTS.md", "runtime": "codex", "owner": "file", "source": "agents.md" },
      { "path": ".cursor/rules/shared.mdc", "runtime": "cursor", "owner": "flaky", "content": "flaky v1" }
    ]'
}

sync() {
    harness sync --manifest "$MANIFEST" --root "$ROOT" --source-dir "$SRC" "$@"
}

sha() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

@test "sync は全 target を render して配置し、親ディレクトリも作る" {
    two_targets
    run sync
    assert_success
    assert_equal "$(cat "$ROOT/AGENTS.md")" 'from source v1'
    assert_equal "$(cat "$ROOT/.cursor/rules/shared.mdc")" 'flaky v1'
    assert_line 'updated   AGENTS.md'
    assert_line 'updated   .cursor/rules/shared.mdc'
    assert_line 'harness sync: 2 updated, 0 unchanged'
}

@test "adapter が 1 つでも失敗すると既存 Target は 1 つも変わらず、失敗を除けば全部進む(Contrast Pair)" {
    two_targets
    sync
    local before_agents before_rules
    before_agents=$(sha "$ROOT/AGENTS.md")
    before_rules=$(sha "$ROOT/.cursor/rules/shared.mdc")

    # Source を進めたうえで flaky だけを失敗させる: file 側の候補も live に出てはいけない
    printf 'from source v2\n' >"$SRC/agents.md"
    HARNESS_FIXTURE_FAIL=1 run sync
    assert_failure 1
    assert_line 'FAIL target .cursor/rules/shared.mdc: adapter flaky が exit 7'
    assert_output --partial 'Target を変更しませんでした'
    assert_equal "$(sha "$ROOT/AGENTS.md")" "$before_agents"
    assert_equal "$(sha "$ROOT/.cursor/rules/shared.mdc")" "$before_rules"

    # 対照: 同じ manifest・同じ Source で失敗を外せば両方進む
    run sync
    assert_success
    assert_equal "$(cat "$ROOT/AGENTS.md")" 'from source v2'
    assert_line 'harness sync: 1 updated, 1 unchanged'
}

@test "sync を 2 回実行しても 2 回目は何も変更しない(冪等)" {
    two_targets
    sync
    local marker="$BATS_TEST_TMPDIR/marker"
    # 1 回目の Target の mtime を過去に倒してから marker を作る(sleep 1 で待つ代わり)
    find "$ROOT" -type f -exec touch -t 202001010000 {} +
    touch "$marker"
    run sync
    assert_success
    assert_line 'unchanged AGENTS.md'
    assert_line 'harness sync: 0 updated, 2 unchanged'
    # mtime が marker より新しい Target が 1 つも無い = mv すら起きていない
    assert_equal "$(find "$ROOT" -type f -newer "$marker" | wc -l | tr -d ' ')" '0'
}

@test "sync は manifest に無いファイルに触れず、staging を残さない" {
    two_targets
    printf 'mine\n' >"$ROOT/notes.txt"
    run sync
    assert_success
    assert_equal "$(cat "$ROOT/notes.txt")" 'mine'
    assert_equal "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" '0'
}

@test "file adapter は source が無ければ失敗し、sync は Target を作らない" {
    write_manifest '[ { "path": "AGENTS.md", "runtime": "codex", "owner": "file", "source": "missing.md" } ]'
    run sync
    assert_failure 1
    assert_line 'FAIL target AGENTS.md: adapter file が exit 1'
    assert [ ! -e "$ROOT/AGENTS.md" ]
}

@test "adapter が staging ファイルを書かなければ失敗扱い" {
    cat >"$HARNESS_ADAPTER_DIR/silent.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$HARNESS_ADAPTER_DIR/silent.sh"
    write_manifest '[ { "path": "x.md", "runtime": "codex", "owner": "silent" } ]'
    run sync
    assert_failure 1
    assert_line 'FAIL target x.md: adapter silent が出力を生成しませんでした'
}

@test "sync --runtime は使えない" {
    two_targets
    run sync --runtime codex
    assert_failure 64
    assert_output --partial 'harness sync: --runtime は sync では使えません'
}

@test "live Target が symlink なら sync は何も置換せず FAIL" {
    two_targets
    printf 'elsewhere\n' >"$BATS_TEST_TMPDIR/elsewhere.md"
    mkdir -p "$ROOT"
    ln -s "$BATS_TEST_TMPDIR/elsewhere.md" "$ROOT/AGENTS.md"
    run sync
    assert_failure 1
    assert_output --partial 'symlink の Target は #309 では未対応です'
    assert [ ! -e "$ROOT/.cursor/rules/shared.mdc" ]
    assert [ -L "$ROOT/AGENTS.md" ]
}

@test "置換したファイルのモードは既存 live を引き継ぐ" {
    two_targets
    sync
    chmod 600 "$ROOT/AGENTS.md"
    printf 'from source v2\n' >"$SRC/agents.md"
    run sync
    assert_success
    assert_equal "$(stat -c '%a' "$ROOT/AGENTS.md" 2>/dev/null || stat -f '%Lp' "$ROOT/AGENTS.md")" '600'
}

# ---------- Task 4: drift 検出 ----------

check() {
    harness check --manifest "$MANIFEST" --root "$ROOT" --source-dir "$SRC" "$@"
}

@test "sync 直後の check は全 target が OK" {
    stub_all
    two_targets
    sync
    run check
    assert_success
    assert_line 'OK   target AGENTS.md'
    assert_line 'OK   target .cursor/rules/shared.mdc'
    assert_line 'harness check: 0 failures, 0 warnings'
}

@test "Target を直接編集すると check は owner 名付きの DRIFT で exit 1 し、Target は直さない" {
    stub_all
    two_targets
    sync
    printf 'hand edited\n' >"$ROOT/AGENTS.md"
    run check
    assert_failure 1
    assert_line 'DRIFT target AGENTS.md: 内容が Source と異なります (owner: file)'
    assert_line 'OK   target .cursor/rules/shared.mdc'
    assert_equal "$(cat "$ROOT/AGENTS.md")" 'hand edited'
}

@test "Target が無ければ DRIFT(存在しません)" {
    stub_all
    two_targets
    run check
    assert_failure 1
    assert_line 'DRIFT target AGENTS.md: 存在しません (owner: file)'
    assert_line 'DRIFT target .cursor/rules/shared.mdc: 存在しません (owner: flaky)'
    assert_line 'harness check: 2 failures, 0 warnings'
}

@test "--runtime を指定すると drift もその runtime の target だけを見る" {
    stub_all
    two_targets
    sync
    printf 'hand edited\n' >"$ROOT/AGENTS.md"
    run check --runtime cursor
    assert_success
    assert_line 'OK   target .cursor/rules/shared.mdc'
    refute_output --partial 'AGENTS.md'
}

@test "check 中の adapter 失敗は FAIL として報告し、他の target の比較は続ける" {
    stub_all
    two_targets
    sync
    HARNESS_FIXTURE_FAIL=1 run check
    assert_failure 1
    assert_line 'FAIL target .cursor/rules/shared.mdc: adapter flaky が exit 7'
    assert_line 'OK   target AGENTS.md'
}

@test "check も symlink Target を FAIL で報告する" {
    stub_all
    two_targets
    printf 'elsewhere\n' >"$BATS_TEST_TMPDIR/elsewhere.md"
    mkdir -p "$ROOT"
    ln -s "$BATS_TEST_TMPDIR/elsewhere.md" "$ROOT/AGENTS.md"
    run check
    assert_failure 1
    assert_output --partial 'symlink の Target は #309 では未対応です'
}

@test "check は staging を残さない" {
    stub_all
    two_targets
    sync
    run check
    assert_success
    assert_equal "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" '0'
}

# ---------- レビュー(PR #328)で見つかった穴 ----------

@test "型の違う manifest も manifest: の理由付きで exit 2 (jq のエラーで exit 5 にならない)" {
    stub_all
    write_manifest '[ { "path": 5, "runtime": "codex", "owner": "flaky" } ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'manifest: targets[0].path'

    write_manifest '[ "AGENTS.md" ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'manifest: targets[0]'

    printf '{ "version": 1, "runtimes": { "claude": "auto" }, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'manifest: runtimes.claude'

    printf '{ "version": 1, "runtimes": { "claude": { "bin": "fixture-claude", "minVersion": "1.0.0", "versionArgs": "--version" } }, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'manifest: runtimes.claude.versionArgs'
}

@test "pattern の無い capability や空の pattern は reject (literal null / 全件一致で偽 OK にならない)" {
    stub_all
    printf '{ "version": 1, "runtimes": { "claude": { "bin": "fixture-claude", "minVersion": "1.0.0", "capabilities": [ { "name": "settings", "args": ["--help"] } ] } }, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'manifest: runtimes.claude.capabilities'

    printf '{ "version": 1, "runtimes": { "claude": { "bin": "fixture-claude", "minVersion": "1.0.0", "capabilities": [ { "name": "settings", "pattern": "" } ] } }, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'manifest: runtimes.claude.capabilities'
}

@test "owner に / や .. を含む target は reject (adapters/ の外の実行ファイルを adapter にしない)" {
    stub_all
    mkdir -p "$HARNESS_ADAPTER_DIR/sub"
    cp "$HARNESS_ADAPTER_DIR/flaky.sh" "$HARNESS_ADAPTER_DIR/sub/evil.sh"
    write_manifest '[ { "path": "x.md", "runtime": "codex", "owner": "sub/evil", "content": "o" } ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'owner "sub/evil"'

    write_manifest '[ { "path": "x.md", "runtime": "codex", "owner": "../adapters/flaky", "content": "o" } ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'owner "../adapters/flaky"'
}

@test "末尾 / の path と、大文字小文字だけ違う path の併存は reject" {
    stub_all
    write_manifest '[ { "path": "foo/", "runtime": "codex", "owner": "flaky", "content": "a" } ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'path は正規化された相対パスでなければなりません'

    write_manifest '[
      { "path": "AGENTS.md", "runtime": "codex", "owner": "flaky", "content": "a" },
      { "path": "agents.md", "runtime": "codex", "owner": "file", "source": "agents.md" }
    ]'
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 2
    assert_output --partial 'owner が重複しています'
}

@test "versionArgs が空でバージョンを解釈できない runtime は FAIL で exit 1 (bash 3.2 の EXIT trap で exit 0 に潰れない)" {
    cat >"$STUB_BIN/fixture-noversion" <<'EOF2'
#!/usr/bin/env bash
echo usage
EOF2
    chmod +x "$STUB_BIN/fixture-noversion"
    printf '{ "version": 1, "runtimes": { "x": { "bin": "fixture-noversion", "minVersion": "1.0.0", "versionArgs": [] } }, "targets": [] }\n' >"$MANIFEST"
    run harness check --manifest "$MANIFEST" --root "$ROOT"
    assert_failure 1
    assert_output --partial 'FAIL runtime x: バージョンを解釈できません'
    assert_line 'harness check: 1 failures, 0 warnings'
}

@test "live Target がディレクトリなら sync は何も置換せず FAIL し、check も FAIL で報告する" {
    stub_all
    two_targets
    mkdir -p "$ROOT/AGENTS.md"
    run sync
    assert_failure 1
    assert_output --partial 'target AGENTS.md: 通常ファイルではありません'
    assert [ -d "$ROOT/AGENTS.md" ]
    assert_equal "$(ls -A "$ROOT/AGENTS.md" | wc -l | tr -d ' ')" '0'
    assert [ ! -e "$ROOT/.cursor/rules/shared.mdc" ]

    run check
    assert_failure 1
    assert_line 'FAIL target AGENTS.md: 通常ファイルではありません (owner: file)'
}

@test "Target の祖先が通常ファイルなら sync は何も置換せず FAIL し、check も FAIL で報告する" {
    stub_all
    two_targets
    : >"$ROOT/.cursor"
    run sync
    assert_failure 1
    assert_output --partial 'target .cursor/rules/shared.mdc: 親ディレクトリを作れません (.cursor が通常ファイルです)'
    refute_output --partial 'updated'
    assert [ ! -e "$ROOT/AGENTS.md" ]
    assert [ -f "$ROOT/.cursor" ]

    run check
    assert_failure 1
    assert_line 'FAIL target .cursor/rules/shared.mdc: 親ディレクトリを作れません (.cursor が通常ファイルです) (owner: flaky)'
    refute_output --partial 'DRIFT target .cursor/rules/shared.mdc'
}

@test "置換フェーズの環境要因の失敗 (親ディレクトリが読み取り専用) は FAIL で報告し、他の target は続けて exit 1" {
    stub_all
    two_targets
    mkdir -p "$ROOT/.cursor/rules"
    chmod 555 "$ROOT/.cursor/rules"
    run sync
    chmod 755 "$ROOT/.cursor/rules"
    assert_failure 1
    assert_line 'updated   AGENTS.md'
    assert_line 'FAIL target .cursor/rules/shared.mdc: 置換に失敗しました (owner: flaky)'
    assert_line 'harness sync: 1 updated, 0 unchanged'
    assert_output --partial '一部の Target を置換できませんでした'
    assert [ -f "$ROOT/AGENTS.md" ]
    assert [ ! -e "$ROOT/.cursor/rules/shared.mdc" ]
    assert_equal "$(ls -A "$ROOT/.cursor/rules" | wc -l | tr -d ' ')" '0'
}

@test "staging を書いてから失敗した adapter の target は check で FAIL 1 行だけ (DRIFT / OK を重ねない)" {
    stub_all
    cat >"$HARNESS_ADAPTER_DIR/partial.sh" <<'EOF2'
#!/usr/bin/env bash
printf 'partial\n' >"$2"
exit 3
EOF2
    chmod +x "$HARNESS_ADAPTER_DIR/partial.sh"
    write_manifest '[ { "path": "x.md", "runtime": "codex", "owner": "partial" } ]'
    printf 'partial\n' >"$ROOT/x.md"
    run check
    assert_failure 1
    assert_line 'FAIL target x.md: adapter partial が exit 3'
    refute_output --partial 'DRIFT target x.md'
    refute_output --partial 'OK   target x.md'
    assert_line 'harness check: 1 failures, 0 warnings'
}

# ---------- Task 5: 本物の manifest ----------

@test "リポジトリの harness/manifest.json は検証を通り、apm の probe 形式が実際の help 出力と合う" {
    # apm --help の実出力(2026-09-11, v0.30.0)の該当行を模した stub。他 3 runtime は --runtime apm で対象外
    make_stub apm 0.30.0 '  audit         Scan installed primitives
  install       Install APM, MCP, and LSP dependencies
  prune         Remove APM packages absent from the resolved dependency'
    run harness check --manifest "$BATS_TEST_DIRNAME/../harness/manifest.json" --root "$ROOT" --runtime apm
    assert_success
    assert_line 'OK   runtime apm 0.30.0'
    assert_line 'harness check: 0 failures, 0 warnings'
}
