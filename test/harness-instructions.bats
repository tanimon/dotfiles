# このリポジトリを Managed Project にする部分(#310)の振る舞いテスト。
# 設計: docs/superpowers/specs/2026-09-12-project-instruction-sync-design.md
#
# 前半は fixture に対する compose adapter と check --no-probe の検査、
# 後半はこのリポジトリの commit 済み Target そのものの検査。
# すべて harness/bin/harness.sh を外部コマンドとして呼ぶ(内部関数は直接呼ばない)。
setup() {
    load 'helpers/setup'
    REPO="$BATS_TEST_DIRNAME/.."
    HARNESS="$REPO/harness/bin/harness.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    ROOT="$BATS_TEST_TMPDIR/root"
    SRC="$BATS_TEST_TMPDIR/src"
    STUB_BIN="$BATS_TEST_TMPDIR/bin"
    MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
    mkdir -p "$HOME" "$TMPDIR" "$ROOT" "$SRC/modules" "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"
    # harness.sh / adapter_path が実際に読む環境変数はすべてクリアする(.claude/rules/shell-scripts.md)。
    # 姉妹スイート test/harness-sync.bats はこれを export するので、漏れると compose の
    # テストが別の adapter を検査して通ったり落ちたりする
    unset HARNESS_ADAPTER_DIR HARNESS_HOME HARNESS_ROOT HARNESS_SOURCE_DIR HARNESS_MANIFEST
}

harness() {
    bash "$HARNESS" "$@"
}

# make_stub NAME VERSION: --version と --help を返す stub 実行ファイル
make_stub() {
    cat >"$STUB_BIN/$1" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
    --version) echo "$1 version $2" ;;
    --help) echo "usage" ;;
    *) exit 64 ;;
esac
EOF
    chmod +x "$STUB_BIN/$1"
}

stub_all() {
    make_stub fixture-claude 2.1.268
    make_stub fixture-codex 0.147.0
    make_stub fixture-cursor 3.17.21
}

# write_manifest TARGETS_JSON: 3 runtime を宣言した fixture manifest
write_manifest() {
    cat >"$MANIFEST" <<EOF
{
  "version": 1,
  "runtimes": {
    "claude": { "bin": "fixture-claude", "minVersion": "2.0.0" },
    "codex":  { "bin": "fixture-codex",  "minVersion": "0.100.0" },
    "cursor": { "bin": "fixture-cursor", "minVersion": "3.0.0" }
  },
  "targets": ${1:-[]}
}
EOF
}

# module NAME CONTENT...: $SRC/modules/NAME に改行終端でモジュールを書く
module() {
    local name=$1
    shift
    printf '%s\n' "$@" >"$SRC/modules/$name"
}

sync_fixture() {
    harness sync --manifest "$MANIFEST" --root "$ROOT" --source-dir "$SRC"
}

# ---------- compose adapter ----------

@test "compose は modules を宣言順に連結する" {
    module a.md '# A' 'alpha'
    module b.md '# B' 'beta'
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/a.md","modules/b.md"]}]'
    run sync_fixture
    assert_success
    run cat "$ROOT/OUT.md"
    assert_output - <<'EOF'
# A
alpha

# B
beta
EOF
}

@test "compose は末尾改行の無いモジュールでも見出しを繋げない" {
    printf '# A\nalpha' >"$SRC/modules/a.md" # 末尾改行なし
    module b.md '# B'
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/a.md","modules/b.md"]}]'
    run sync_fixture
    assert_success
    run cat "$ROOT/OUT.md"
    assert_output - <<'EOF'
# A
alpha

# B
EOF
}

@test "compose は modules 欠落を render 失敗にし live を変更しない" {
    printf 'original\n' >"$ROOT/OUT.md"
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose"}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial 'modules'
    run cat "$ROOT/OUT.md"
    assert_output 'original'
}

@test "compose は空の modules を render 失敗にする" {
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":[]}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial 'modules'
    [ ! -e "$ROOT/OUT.md" ]
}

@test "compose は存在しないモジュールを render 失敗にする" {
    module a.md '# A'
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/a.md","modules/missing.md"]}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial 'missing.md'
    [ ! -e "$ROOT/OUT.md" ]
}

@test "compose は source-dir の外を指す modules を拒否する(Contrast Pair)" {
    printf 'secret\n' >"$BATS_TEST_TMPDIR/outside.md"
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["../outside.md"]}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial '相対パス'

    # 同じ内容を source-dir の中に置けば通る
    cp "$BATS_TEST_TMPDIR/outside.md" "$SRC/modules/inside.md"
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/inside.md"]}]'
    run sync_fixture
    assert_success
}

@test "compose は読めないモジュールを成功扱いにしない(空セクションで黙って上書きしない)" {
    [ "$(id -u)" -ne 0 ] || skip "root は mode 000 のファイルも読めるので再現できない"
    module a.md '# A' 'alpha'
    module b.md '# B'
    chmod 000 "$SRC/modules/a.md"
    printf 'original\n' >"$ROOT/OUT.md"
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/a.md","modules/b.md"]}]'
    run sync_fixture
    chmod 644 "$SRC/modules/a.md"
    assert_failure 1
    assert_output --partial '読めません'
    run cat "$ROOT/OUT.md"
    assert_output 'original'
}

@test "compose は改行を含む modules エントリを拒否する(1 宣言が複数パスに分裂しない)" {
    module a.md '# A'
    module b.md '# B'
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/a.md\nmodules/b.md"]}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial '相対パス'
    [ ! -e "$ROOT/OUT.md" ]
}

@test "compose は frontmatter の壊れたキーと空の frontmatter を拒否する" {
    module a.md '# A'
    # 改行を含むキーは --- ブロックを途中で閉じ、alwaysApply を本文へ落としてしまう
    write_manifest '[{"path":"OUT.mdc","runtime":"cursor","owner":"compose","frontmatter":{"desc\n---\ninjected":"x","alwaysApply":true},"modules":["modules/a.md"]}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial 'キー'
    # frontmatter の無い .cursor/rules ファイルは Cursor に無視されるので {} も拒否する
    write_manifest '[{"path":"OUT.mdc","runtime":"cursor","owner":"compose","frontmatter":{},"modules":["modules/a.md"]}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial 'frontmatter が空'
    [ ! -e "$ROOT/OUT.mdc" ]
}

@test "compose は frontmatter を先頭に YAML として出す" {
    module a.md '# A'
    write_manifest '[{"path":"OUT.mdc","runtime":"cursor","owner":"compose","frontmatter":{"description":"d","alwaysApply":true},"modules":["modules/a.md"]}]'
    run sync_fixture
    assert_success
    run cat "$ROOT/OUT.mdc"
    assert_output - <<'EOF'
---
description: "d"
alwaysApply: true
---

# A
EOF
}

@test "compose は frontmatter のオブジェクト値を拒否する" {
    module a.md '# A'
    write_manifest '[{"path":"OUT.mdc","runtime":"cursor","owner":"compose","frontmatter":{"nested":{"a":1}},"modules":["modules/a.md"]}]'
    run sync_fixture
    assert_failure 1
    assert_output --partial 'frontmatter'
}

@test "compose は banner を frontmatter の直後に出す" {
    module a.md '# A'
    write_manifest '[{"path":"OUT.mdc","runtime":"cursor","owner":"compose","frontmatter":{"alwaysApply":true},"banner":"generated","modules":["modules/a.md"]}]'
    run sync_fixture
    assert_success
    run cat "$ROOT/OUT.mdc"
    assert_output - <<'EOF'
---
alwaysApply: true
---

<!-- generated -->

# A
EOF
}

@test "compose の sync は 2 回目に何も変更しない(冪等)" {
    module a.md '# A'
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","banner":"gen","modules":["modules/a.md"]}]'
    run sync_fixture
    assert_success
    assert_output --partial '1 updated, 0 unchanged'
    run sync_fixture
    assert_success
    assert_output --partial '0 updated, 1 unchanged'
}

# ---------- check --no-probe ----------

@test "--no-probe は runtime が無くても Target だけを検査する(Contrast Pair)" {
    module a.md '# A'
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/a.md"]}]'
    run sync_fixture
    assert_success

    # stub を置かない = 3 runtime とも見つからない状態
    run harness check --manifest "$MANIFEST" --root "$ROOT" --source-dir "$SRC" --no-probe
    assert_success
    refute_output --partial 'FAIL runtime'
    assert_output --partial 'OK   target OUT.md'
    assert_output --partial '--no-probe'

    # --no-probe を外すと同じ状態で FAIL になる
    run harness check --manifest "$MANIFEST" --root "$ROOT" --source-dir "$SRC"
    assert_failure 1
    assert_output --partial 'FAIL runtime'
}

@test "--no-probe でも Target の drift は検出する" {
    module a.md '# A'
    write_manifest '[{"path":"OUT.md","runtime":"claude","owner":"compose","modules":["modules/a.md"]}]'
    run sync_fixture
    assert_success
    printf 'hand edited\n' >"$ROOT/OUT.md"
    run harness check --manifest "$MANIFEST" --root "$ROOT" --source-dir "$SRC" --no-probe
    assert_failure 1
    assert_output --partial 'DRIFT target OUT.md'
    assert_output --partial 'owner: compose'
}

@test "sync に --no-probe は使えない" {
    stub_all
    write_manifest
    run harness sync --manifest "$MANIFEST" --root "$ROOT" --source-dir "$SRC" --no-probe
    assert_failure 64
    assert_output --partial 'sync では使えません'
}

# ---------- このリポジトリの Target ----------

repo_check() {
    bash "$HARNESS" check --manifest "$REPO/harness/project.json" \
        --root "$REPO" --source-dir "$REPO" --no-probe
}

@test "commit 済みの instruction Target が Source と一致している" {
    run repo_check
    assert_success
    assert_output --partial 'harness check: 0 failures'
}

@test "harness/modules/ の全ファイルがどれかの Target から参照されている" {
    # 参照されていないモジュールは、存在するのに誰にも届かない。Source と Target は
    # 一致しているので check-instructions は緑のまま — ここでしか検出できない
    local declared file
    declared=$(jq -r '[.targets[].modules[]] | unique | .[]' "$REPO/harness/project.json")
    while IFS= read -r file; do
        printf '%s\n' "$declared" | grep -qxF -- "$file" ||
            fail "$file がどの Target の modules にも入っていません"
    done < <(cd "$REPO" && find harness/modules -type f -name '*.md' | sort)
}

@test "--no-probe の告知と summary の文言が設計ドキュメントと一致している" {
    # 文字列を固定しないと、呼び出し側(#324 の chezmoi 統合)が読む契約が黙って変わる
    run repo_check
    assert_success
    assert_line --index 0 'SKIP runtime probe (--no-probe: 製品のロードは検証していません)'
    assert_output --partial 'harness check: 0 failures, 0 warnings (Capability Probe 省略)'
}

@test "project.json の runtime 宣言が manifest.json と一致している" {
    local name
    for name in claude codex cursor; do
        run jq -S --arg n "$name" '.runtimes[$n]' "$REPO/harness/project.json"
        assert_success
        local project_runtime=$output
        run jq -S --arg n "$name" '.runtimes[$n]' "$REPO/harness/manifest.json"
        assert_success
        assert_equal "$output" "$project_runtime"
    done
}

@test "CLAUDE.md には Claude 固有の指示がある" {
    # 1 件ずつ見る: grep -e A -e B -e C は「どれか 1 つ」で成功するので、
    # 3 つのうち 2 つが消えても通ってしまう
    local marker
    for marker in '/harness-reflect' 'mcp__claude-in-chrome' '/browse' 'Claude Code specifics'; do
        run grep -qF -- "$marker" "$REPO/CLAUDE.md"
        assert_success
    done
}

@test "AGENTS.md は Claude 専用コマンドを実行可能な指示として出さない(AC: 陳腐化した Codex 指示の排除)" {
    # Claude Code のツール名は 1 度も出てはいけない
    run grep -n 'mcp__claude-in-chrome' "$REPO/AGENTS.md"
    assert_failure
    # コマンドブロックの行頭に Claude のスラッシュコマンドが並んでいてはいけない
    # (機構の説明として本文中で名前に触れるのは可。下の disclaimer がまさにそれ)
    run grep -n -e '^/harness-reflect' -e '^/harness-review' -e '^bash ~/\.claude/scripts/' "$REPO/AGENTS.md"
    assert_failure
    # 当てはまらないことが明示されている
    run grep -q 'Claude Code slash commands do not exist here' "$REPO/AGENTS.md"
    assert_success
}

@test "AGENTS.md は Codex の切り捨て(32 KiB)の内側に「Key Patterns 以外の全セクション」を収める" {
    # codex は project_doc_max_bytes(既定 32768 バイト)で AGENTS.md を黙って切る。
    # モジュールの並びは「切り捨てが 35-key-patterns の内側でだけ起きる」ように決めてあるので、
    # それ以外のセクションの見出しが先頭 32 KiB に全部入っていることを不変条件として強制する。
    # 共有モジュールが太っても、このテストが落ちて並べ替えを促す
    local head_bytes marker
    head_bytes=$(head -c 32768 "$REPO/AGENTS.md")
    for marker in \
        'Claude Code slash commands do not exist here' \
        'project_doc_max_bytes' \
        '## What This Is' \
        '## Common Commands' \
        '## chezmoi Naming Conventions' \
        '## Architecture' \
        '## Verification' \
        '## Known Pitfalls' \
        '## Agent docs'; do
        printf '%s' "$head_bytes" | grep -qF -- "$marker" ||
            fail "AGENTS.md の先頭 32768 バイトに \"$marker\" がありません (モジュールの並びを見直してください)"
    done
    # Contrast: 末尾に置いた Key Patterns は実際に切り捨てられている
    # (切り捨てが起きていないなら、上の不変条件は自明に成り立つだけで何も検証していない)
    run grep -qF -- '### Key Patterns' "$REPO/AGENTS.md"
    assert_success
    printf '%s' "$head_bytes" | grep -qF -- '**Harness sync seam' &&
        fail "AGENTS.md が 32 KiB に収まっているなら、この検査と codex-extension.md の説明を更新してください"
    return 0
}

@test "AGENTS.md と CLAUDE.md の両方に共有モジュールが入っている" {
    run grep -q 'chezmoi Naming Conventions' "$REPO/AGENTS.md"
    assert_success
    run grep -q 'chezmoi Naming Conventions' "$REPO/CLAUDE.md"
    assert_success
}

@test "Cursor の rule は .mdc で alwaysApply: true の frontmatter を持つ" {
    local mdc="$REPO/.cursor/rules/dotfiles.mdc"
    [ -f "$mdc" ]
    run head -n1 "$mdc"
    assert_output '---'
    run grep -q '^alwaysApply: true$' "$mdc"
    assert_success
}

@test "Cursor の rule は共有モジュールを重複して持たない" {
    run grep -q 'chezmoi Naming Conventions' "$REPO/.cursor/rules/dotfiles.mdc"
    assert_failure
}

@test "生成された 3 Target すべてが自動生成 banner を持つ" {
    local f
    for f in "$REPO/CLAUDE.md" "$REPO/AGENTS.md" "$REPO/.cursor/rules/dotfiles.mdc"; do
        run head -n8 "$f"
        assert_output --partial '自動生成'
        assert_output --partial 'harness'
    done
}
