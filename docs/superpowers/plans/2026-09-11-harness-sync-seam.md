# harness 同期・検証 seam 実装プラン(#309)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harness Manifest を読んで runtime と Target Owner を明示的に解決し、4 runtime の Capability Probe・drift 報告・fixture に対する Atomic Sync を `harness/bin/harness.sh {check|sync}` として提供する(live の harness は変更しない)。

**Architecture:** `harness/bin/harness.sh` がサブコマンドを分岐し、`harness/lib/*.bash` を source する。manifest(JSON)は `jq` で検証・問い合わせ、Runtime Adapter は `harness/adapters/<owner>.sh render <staging-file> <target-json>` という実行ファイル契約で差し替え可能。`sync` は全 Target を staging に render → 全体検証 → target ディレクトリ内の一時ファイルを `mv` で置換する。テストはすべて `harness.sh` を外部コマンドとして呼ぶ bats。

**Tech Stack:** bash 3.2 互換(macOS `/bin/bash`)、jq、bats-core(`pnpm exec bats`)、just、shellcheck / shfmt

**Spec:** `docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md`(本プランはこの spec を実装する。実装者は必ず spec も読むこと)

## Global Constraints

- **bash 3.2 互換**: ローカルの `/usr/bin/env bash` は 3.2.57。`mapfile` / `readarray` / `declare -A` / `${var,,}` を使わない。空配列の展開は `${arr[@]+"${arr[@]}"}` の形にする(`set -u` で落ちるため)
- すべてのスクリプトは `#!/usr/bin/env bash` + `set -euo pipefail`(`.claude/rules/shell-scripts.md`)。source されるライブラリ(`lib/*.bash`)は `set` を書かず、呼び出し側の設定に従う
- `*.sh` / `*.bash` は `just shellcheck` と `just shfmt`(`shfmt -i 4`)を**必ず**通す。`*.json` は `just oxfmt` を通す(`pnpm exec oxfmt --write <file>` で整形してよい)
- **live の harness を変更しない**: `dot_claude/`、`dot_apm/`、`~/` 配下、`.chezmoiscripts/` を触らない。`harness/` は `.chezmoiignore` に追加して `~/harness/` へ配置されないようにする
- 一時ファイルは `mktemp -d "${TMPDIR:-/tmp}/harness-xxx-XXXXXX"` の形(`/tmp` 直書き禁止)。`trap 'rm -rf "$staging"' EXIT` で必ず削除
  - **実装時の変更(e2512e7)**: EXIT trap は採らず、親シェルで staging を作って `main` を subshell 実行し親が削除する形にした(bash 3.2 の EXIT trap は `set -u` 違反を exit 0 に潰す。ADR 0002 / 0003 と spec が現行の記述)。本プランの以降の trap 記述は履歴として残す
- 新規ドキュメント・コメント・テスト名はすべて日本語(`~/.claude/rules/common/documentation-language.md`)。`@test` 名に日本語を使うので bats 実行は `LC_ALL=C pnpm exec bats ...`(`.claude/rules/shell-scripts.md` の locale バグ回避)
- リテラルの `/Users/<名前>`、`ghq/github.com/<literal>`、`-Users-<名前>--` をコード・fixture・ドキュメントに書かない(`just scan-sensitive` が落ちる)
- 出力行の形式は spec の通り厳守: `OK   `(スペース 3 つ)/ `WARN ` / `FAIL ` / `DRIFT ` で始まり、summary は `harness check: <F> failures, <W> warnings` / `harness sync: <U> updated, <N> unchanged`
- exit code: manifest 検証エラー = 2、使い方エラー・未実装 = 64、check の FAIL/DRIFT あり = 1、sync の render 失敗 = 1
- commit メッセージは Conventional Commits(`feat(harness): ...` 等、本文は日本語)。末尾に `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` を付ける。各 commit で pre-commit フック(secretlint / shellcheck / shfmt / oxfmt / scan-sensitive)が走る — `--no-verify` は禁止
- 実装者は subagent を dispatch しない(レビューはコントローラが行う)

---

### Task 1: 入口・manifest 検証・テスト基盤

**Files:**
- Create: `harness/bin/harness.sh`
- Create: `harness/lib/report.bash`
- Create: `harness/lib/manifest.bash`
- Create: `test/harness-sync.bats`
- Modify: `justfile`(`lint` 行と `test-harness-sync` レシピ)
- Modify: `.chezmoiignore`(`harness` を追加)

**Interfaces:**
- Produces(後続 Task が依存する):
  - グローバル: `HARNESS_HOME`(`harness/` の絶対パス)、`HARNESS_ROOT`、`HARNESS_SOURCE_DIR`、`HARNESS_MANIFEST`(すべて export 済み)、`HARNESS_MANIFEST_JSON`(compact JSON 文字列)
  - `report.bash`: `report_ok MSG` / `report_warn MSG` / `report_fail MSG` / `report_drift MSG` / `report_summary CMD` / `die CODE MSG...`。集計は `HARNESS_FAILURES` / `HARNESS_WARNINGS`
  - `manifest.bash`: `manifest_load PATH`、`manifest_query JQ_ARGS...`(`jq -r` を `HARNESS_MANIFEST_JSON` に対して実行)、`manifest_runtimes`(runtime 名を 1 行ずつ)、`manifest_runtime_field NAME FIELD`、`manifest_target_count`、`manifest_target INDEX`(compact JSON)、`adapter_path OWNER`(実行ファイルのパスを出力、無ければ return 1)
  - `harness.sh`: `cmd_check RUNTIME_FILTER` / `cmd_sync RUNTIME_FILTER` 関数(Task 1 時点では `cmd_check` は manifest 検証と summary のみ、`cmd_sync` は未定義。Task 2〜4 で拡張)
  - テスト helper(`test/harness-sync.bats` 内): `make_stub NAME VERSION [HELP_TEXT]`、`stub_all`、`write_manifest [TARGETS_JSON]`、`make_flaky_adapter`

- [ ] **Step 1: テストファイルの骨格と Task 1 のテストを書く**

`test/harness-sync.bats`:

```bash
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
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `LC_ALL=C pnpm exec bats test/harness-sync.bats`
Expected: 全件 FAIL(`harness/bin/harness.sh` が存在しないため `bash: ... No such file`)

- [ ] **Step 3: `harness/lib/report.bash` を書く**

```bash
#!/usr/bin/env bash
# 報告行の出力と集計。harness.sh から source される(set は呼び出し側に従う)。
#
# 出力形式は spec「check の手順」の通り固定: 先頭トークンの幅を揃えるため
# OK は後ろにスペース 3 つ、WARN / FAIL / DRIFT は 1 つ。

HARNESS_FAILURES=0
HARNESS_WARNINGS=0

report_ok() {
    printf 'OK   %s\n' "$*"
}

report_warn() {
    printf 'WARN %s\n' "$*"
    HARNESS_WARNINGS=$((HARNESS_WARNINGS + 1))
}

report_fail() {
    printf 'FAIL %s\n' "$*"
    HARNESS_FAILURES=$((HARNESS_FAILURES + 1))
}

report_drift() {
    printf 'DRIFT %s\n' "$*"
    HARNESS_FAILURES=$((HARNESS_FAILURES + 1))
}

# report_summary CMD: "harness <cmd>: N failures, M warnings"
report_summary() {
    printf 'harness %s: %d failures, %d warnings\n' "$1" "$HARNESS_FAILURES" "$HARNESS_WARNINGS"
}

# die CODE MSG...: MSG を stderr に出して CODE で終了
die() {
    local code=$1
    shift
    printf '%s\n' "$*" >&2
    exit "$code"
}
```

- [ ] **Step 4: `harness/lib/manifest.bash` を書く**

```bash
#!/usr/bin/env bash
# Harness Manifest(JSON)の読み込み・検証・問い合わせ。harness.sh から source される。
# 依存: report.bash(die)、jq、HARNESS_HOME(harness/ の絶対パス)
#
# スキーマは docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md
# 「Harness Manifest スキーマ(version 1)」。検証エラーはすべて "manifest: <理由>" で exit 2。

# manifest_load PATH: 読み込んで検証し、HARNESS_MANIFEST(絶対パス)と
# HARNESS_MANIFEST_JSON(compact JSON)を設定する
manifest_load() {
    local path=$1
    [ -f "$path" ] || die 2 "manifest: ファイルがありません: $path"
    HARNESS_MANIFEST_JSON=$(jq -c . "$path" 2>/dev/null) || die 2 "manifest: JSON として解釈できません: $path"
    HARNESS_MANIFEST="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    export HARNESS_MANIFEST
    manifest_validate
}

# manifest_query JQ_ARGS...: HARNESS_MANIFEST_JSON に対して jq -r を実行する
manifest_query() {
    jq -r "$@" <<<"$HARNESS_MANIFEST_JSON"
}

# manifest_runtimes: runtime 名を 1 行ずつ出力
manifest_runtimes() {
    manifest_query '.runtimes | keys[]'
}

# manifest_runtime_field NAME FIELD: runtimes.NAME.FIELD(無ければ空)
manifest_runtime_field() {
    manifest_query --arg n "$1" --arg f "$2" '.runtimes[$n][$f] // empty'
}

manifest_target_count() {
    manifest_query '.targets | length'
}

# manifest_target INDEX: targets[INDEX] を compact JSON で出力
manifest_target() {
    manifest_query -c --argjson i "$1" '.targets[$i]'
}

# adapter_path OWNER: adapter 実行ファイルのパスを出力。
# 解決順は HARNESS_ADAPTER_DIR(設定時)→ $HARNESS_HOME/adapters。無ければ return 1
adapter_path() {
    local owner=$1 dir candidate dirs=()
    [ -z "${HARNESS_ADAPTER_DIR:-}" ] || dirs+=("$HARNESS_ADAPTER_DIR")
    dirs+=("$HARNESS_HOME/adapters")
    for dir in "${dirs[@]}"; do
        candidate="$dir/$owner.sh"
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

manifest_validate() {
    local version
    version=$(manifest_query '.version // "missing"')
    [ "$version" = "1" ] || die 2 "manifest: version は 1 でなければなりません (現在: $version)"

    # runtime の暗黙検出は許さない: runtimes は非空オブジェクトで、"*" キーや bin:"auto" を含まない
    [ "$(manifest_query '.runtimes | type')" = "object" ] \
        || die 2 "manifest: runtimes を明示してください (runtime の暗黙検出はしません)"
    [ "$(manifest_query '.runtimes | length')" -gt 0 ] \
        || die 2 "manifest: runtimes が空です (runtime の暗黙検出はしません)"
    [ "$(manifest_query '.runtimes | has("*")')" = "false" ] \
        || die 2 'manifest: runtimes に "*" は使えません (runtime を明示してください)'

    local name bin min
    while IFS= read -r name; do
        bin=$(manifest_runtime_field "$name" bin)
        min=$(manifest_runtime_field "$name" minVersion)
        [ -n "$bin" ] || die 2 "manifest: runtimes.$name.bin が必要です"
        [ "$bin" != "auto" ] || die 2 "manifest: runtimes.$name.bin に \"auto\" は使えません (実行ファイル名を明示してください)"
        [ -n "$min" ] || die 2 "manifest: runtimes.$name.minVersion が必要です"
    done < <(manifest_runtimes)

    [ "$(manifest_query '.targets | type')" = "array" ] || die 2 "manifest: targets は配列でなければなりません"

    # Target Owner は 1 target につき 1 つ: 同じ path が 2 回出たら manifest 全体を reject
    local dup owners
    dup=$(manifest_query '[.targets[].path] | group_by(.) | map(select(length > 1) | .[0]) | .[0] // empty')
    if [ -n "$dup" ]; then
        owners=$(manifest_query --arg p "$dup" '[.targets[] | select(.path == $p) | .owner] | join(", ")')
        die 2 "manifest: target \"$dup\" の owner が重複しています ($owners)"
    fi

    local i count path runtime owner
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        path=$(manifest_query --argjson i "$i" '.targets[$i].path // empty')
        runtime=$(manifest_query --argjson i "$i" '.targets[$i].runtime // empty')
        owner=$(manifest_query --argjson i "$i" '.targets[$i].owner // empty')
        [ -n "$path" ] || die 2 "manifest: targets[$i].path が必要です"
        [ -n "$runtime" ] || die 2 "manifest: targets[$i].runtime が必要です"
        [ -n "$owner" ] || die 2 "manifest: targets[$i].owner が必要です"
        [ "$(manifest_query --arg n "$runtime" '.runtimes | has($n)')" = "true" ] \
            || die 2 "manifest: target \"$path\" の runtime \"$runtime\" は runtimes に宣言されていません"
        adapter_path "$owner" >/dev/null \
            || die 2 "manifest: target \"$path\" の owner \"$owner\" に対応する adapter がありません"
    done
}
```

- [ ] **Step 5: `harness/bin/harness.sh` を書く(Task 1 時点)**

```bash
#!/usr/bin/env bash
# harness の入口。Claude Code / Codex / Cursor / APM の harness 設定を
# 1 つの Harness Manifest から検証・同期する(spec: docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md)。
#
# 使い方: harness.sh <check|sync|init|update> [--manifest PATH] [--root DIR] [--source-dir DIR] [--runtime NAME]
set -euo pipefail

HARNESS_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export HARNESS_HOME

# staging ディレクトリはスクリプト全体で 1 つ。trap は関数を抜けた後(スクリプト終了時)に評価されるので
# local ではなくグローバルに持つ(local だと set -u で未定義になり削除されない)
HARNESS_STAGING=""
trap 'rm -rf "${HARNESS_STAGING:-}"' EXIT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/report.bash
source "$HARNESS_HOME/lib/report.bash"
# shellcheck source=../lib/manifest.bash
source "$HARNESS_HOME/lib/manifest.bash"

usage() {
    cat <<'EOF'
使い方: harness.sh <command> [options]

commands:
  check   runtime の Capability Probe と Target の drift を報告する(live は変更しない)
  sync    全 Target を staging に render し、全体検証後に置換する(Atomic Sync)
  init    Managed Project の登録(未実装: #322)
  update  依存更新(未実装: #323)

options:
  --manifest PATH    Harness Manifest(既定: harness/manifest.json)
  --root DIR         Target のルート(既定: $HOME)
  --source-dir DIR   Content Module 等の Source ルート(既定: リポジトリルート)
  --runtime NAME     check の対象を 1 runtime に限定する(既定: manifest の全 runtime)
EOF
}

# cmd_check RUNTIME_FILTER: Task 1 時点では manifest 検証と summary のみ(Task 2 / 4 で拡張)
cmd_check() {
    report_summary check
    [ "$HARNESS_FAILURES" -eq 0 ]
}

main() {
    [ $# -ge 1 ] || {
        usage >&2
        exit 64
    }
    local command=$1
    shift

    local manifest="$HARNESS_HOME/manifest.json" root="$HOME" source_dir="$HARNESS_HOME/.." runtime=""
    while [ $# -gt 0 ]; do
        case $1 in
            --manifest) manifest=$2; shift 2 ;;
            --root) root=$2; shift 2 ;;
            --source-dir) source_dir=$2; shift 2 ;;
            --runtime) runtime=$2; shift 2 ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) die 64 "harness: 不明なオプション: $1" ;;
        esac
    done

    case $command in
        check | sync) ;;
        init) die 64 "harness init: 未実装です (#322 で実装)" ;;
        update) die 64 "harness update: 未実装です (#323 で実装)" ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die 64 "harness: 不明なコマンド: $command" ;;
    esac

    [ -d "$root" ] || die 2 "harness: --root がディレクトリではありません: $root"
    [ -d "$source_dir" ] || die 2 "harness: --source-dir がディレクトリではありません: $source_dir"
    HARNESS_ROOT=$(cd "$root" && pwd)
    HARNESS_SOURCE_DIR=$(cd "$source_dir" && pwd)
    export HARNESS_ROOT HARNESS_SOURCE_DIR

    manifest_load "$manifest"
    "cmd_$command" "$runtime"
}

main "$@"
```

`chmod +x harness/bin/harness.sh` を実行する。`shfmt -i 4` は `case` の 1 行 `;;` 形式を許容するが、実装後に `just shfmt` の diff が出たらその出力に合わせて整形する。

- [ ] **Step 6: justfile と .chezmoiignore を更新する**

`justfile` の `lint:` 行末に ` test-harness-sync` を追加し、`test-harness-scripts` レシピの直後に追加:

```just
# Smoke test the harness sync/check seam (harness/bin/harness.sh)
@test-harness-sync:
    LC_ALL=C pnpm exec bats test/harness-sync.bats
```

`.chezmoiignore` の `CONCEPTS.md` 行の直後に追加:

```
# harness/ は repo-only の同期・検証ツール(docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md)。
# ~/harness/ には配置しない
harness
```

- [ ] **Step 7: テストと lint を通す**

Run: `just test-harness-sync && just shellcheck && just shfmt && chezmoi ignored --source "$(pwd)" | grep -q '^harness' && [ "$(chezmoi managed --source "$(pwd)" | grep -c '^harness')" = 0 ]`
Expected: bats 11 件 PASS、shellcheck / shfmt エラーなし、`harness` が ignored に出て managed には 1 件も出ない(`--source "$(pwd)"` は必須。無いと main の source を見て vacuous に通る — CLAUDE.md「Known Pitfalls」)

- [ ] **Step 8: Commit**

```bash
git add harness/bin/harness.sh harness/lib/report.bash harness/lib/manifest.bash test/harness-sync.bats justfile .chezmoiignore
git commit -m "feat(harness): Harness Manifest の検証と harness.sh 入口を追加 (#309)"
```

---

### Task 2: Capability Probe(`check` の runtime 検査)

**Files:**
- Create: `harness/lib/probe.bash`
- Modify: `harness/bin/harness.sh`(`source` 追加と `cmd_check` 置換)
- Modify: `test/harness-sync.bats`(Task 2 のテストを末尾に追加)

**Interfaces:**
- Consumes: `manifest_runtimes` / `manifest_runtime_field` / `manifest_query`、`report_*`
- Produces: `probe_runtime NAME`(1 runtime を検査し `report_*` で 1 行報告)、`version_lt A B`(A < B なら 0)、`extract_version TEXT`(最初の semver を出力、無ければ return 1)、`cmd_check` が `--runtime` の解決と probe ループを持つ

- [ ] **Step 1: Task 2 のテストを追加する**

`test/harness-sync.bats` の末尾に追加:

```bash
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
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `just test-harness-sync`
Expected: Task 1 の 11 件は PASS、Task 2 の 9 件は FAIL(`OK   runtime ...` 行が無い)

- [ ] **Step 3: `harness/lib/probe.bash` を書く**

```bash
#!/usr/bin/env bash
# Capability Probe: runtime の存在・バージョン・必須 capability を実際の挙動で確かめる。
# harness.sh から source される。依存: report.bash、manifest.bash
#
# バージョン文字列だけでは機能の有無が分からないので、capability は
# `bin args` の出力を pattern(ERE)で照合する(spec「決定事項サマリ」Capability Probe)。

# version_lt A B: semver A < B なら 0(sort -V で比較)
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# extract_version TEXT: 最初の X.Y.Z を出力。無ければ return 1
extract_version() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$1" | head -n1 | grep .
}

# run_capture BIN ARGS...: stdout+stderr を結合して出力。exit code は握りつぶす
# (--help で非 0 を返すツールがあっても照合だけできればよい)
run_capture() {
    "$@" 2>&1 || true
}

# probe_runtime NAME: 1 runtime を検査し、OK / WARN / FAIL のいずれか 1 行以上を報告する
probe_runtime() {
    local name=$1 bin min max
    bin=$(manifest_runtime_field "$name" bin)
    min=$(manifest_runtime_field "$name" minVersion)
    max=$(manifest_runtime_field "$name" maxVerifiedVersion)

    if ! command -v "$bin" >/dev/null 2>&1; then
        report_fail "runtime $name: 見つかりません (bin: $bin)"
        return 0
    fi

    local version_args=() arg
    while IFS= read -r arg; do
        version_args+=("$arg")
    done < <(manifest_query --arg n "$name" '.runtimes[$n].versionArgs // ["--version"] | .[]')

    local output version
    output=$(run_capture "$bin" ${version_args[@]+"${version_args[@]}"})
    if ! version=$(extract_version "$output"); then
        report_fail "runtime $name: バージョンを解釈できません (\`$bin ${version_args[*]}\` の出力: $(head -n1 <<<"$output"))"
        return 0
    fi
    if version_lt "$version" "$min"; then
        report_fail "runtime $name $version: minVersion $min 未満"
        return 0
    fi

    local failed=0 cap_count i cap_name pattern cap_args
    cap_count=$(manifest_query --arg n "$name" '.runtimes[$n].capabilities // [] | length')
    for ((i = 0; i < cap_count; i++)); do
        cap_name=$(manifest_query --arg n "$name" --argjson i "$i" '.runtimes[$n].capabilities[$i].name')
        pattern=$(manifest_query --arg n "$name" --argjson i "$i" '.runtimes[$n].capabilities[$i].pattern')
        cap_args=()
        while IFS= read -r arg; do
            cap_args+=("$arg")
        done < <(manifest_query --arg n "$name" --argjson i "$i" '.runtimes[$n].capabilities[$i].args // [] | .[]')
        output=$(run_capture "$bin" ${cap_args[@]+"${cap_args[@]}"})
        if ! grep -qE -- "$pattern" <<<"$output"; then
            report_fail "runtime $name $version: capability $cap_name がありません (pattern: $pattern)"
            failed=1
        fi
    done
    [ "$failed" -eq 0 ] || return 0

    if [ -n "$max" ] && version_lt "$max" "$version"; then
        report_warn "runtime $name $version: maxVerifiedVersion $max を超えています (再検証が必要)"
        return 0
    fi
    report_ok "runtime $name $version"
}
```

- [ ] **Step 4: `harness.sh` に source と `cmd_check` の probe ループを入れる**

`source "$HARNESS_HOME/lib/manifest.bash"` の直後に追加:

```bash
# shellcheck source=../lib/probe.bash
source "$HARNESS_HOME/lib/probe.bash"
```

`cmd_check` を以下に置き換える:

```bash
# cmd_check RUNTIME_FILTER: runtime の Capability Probe(Task 4 で drift 比較を追加)。
# RUNTIME_FILTER が空なら manifest の全 runtime、指定があればその 1 つだけ(明示選択)
cmd_check() {
    local filter=$1 name runtimes=()
    if [ -n "$filter" ]; then
        [ "$(manifest_query --arg n "$filter" '.runtimes | has($n)')" = "true" ] \
            || die 2 "harness check: runtime \"$filter\" は manifest に宣言されていません"
        runtimes=("$filter")
    else
        while IFS= read -r name; do
            runtimes+=("$name")
        done < <(manifest_runtimes)
    fi
    for name in "${runtimes[@]}"; do
        probe_runtime "$name"
    done

    report_summary check
    [ "$HARNESS_FAILURES" -eq 0 ]
}
```

- [ ] **Step 5: テストと lint を通す**

Run: `just test-harness-sync && just shellcheck && just shfmt`
Expected: 20 件 PASS、lint エラーなし

- [ ] **Step 6: Commit**

```bash
git add harness/lib/probe.bash harness/bin/harness.sh test/harness-sync.bats
git commit -m "feat(harness): runtime の Capability Probe を check に追加 (#309)"
```

---

### Task 3: Atomic Sync(`sync`)と `file` adapter

**Files:**
- Create: `harness/lib/render.bash`
- Create: `harness/adapters/file.sh`
- Modify: `harness/bin/harness.sh`(`source` 追加と `cmd_sync` 追加)
- Modify: `test/harness-sync.bats`(Task 3 のテストを末尾に追加)

**Interfaces:**
- Consumes: `manifest_target_count` / `manifest_target` / `adapter_path`、`report_fail`、export 済みの `HARNESS_ROOT` / `HARNESS_SOURCE_DIR` / `HARNESS_MANIFEST`
- Produces:
  - `render_all STAGING_DIR [RUNTIME_FILTER]`: 対象 target を `STAGING_DIR/<index>` に render。失敗 target は `report_fail` して最後に return 1(live は触らない)
  - `validate_staging STAGING_DIR [RUNTIME_FILTER]`: 対象 target 全件の staging ファイルが通常ファイルとして存在すれば 0
  - `replace_all STAGING_DIR`: staging を live に反映。target ごとに `updated   <path>` / `unchanged <path>` を出力し、最後に `harness sync: N updated, M unchanged` を出力
  - staging ディレクトリはスクリプト全体で 1 つのグローバル `HARNESS_STAGING`(Task 1 の `harness.sh` 冒頭で宣言・trap 済み)。`cmd_sync` / `cmd_check` はこれに `mktemp -d` の結果を代入する
  - `target_selected TARGET_JSON RUNTIME_FILTER`: filter が空か runtime が一致すれば 0(Task 4 の compare も使う)
  - adapter 契約: `<adapter> render <staging-file> <target-json>`(env: `HARNESS_MANIFEST` / `HARNESS_ROOT` / `HARNESS_SOURCE_DIR`)
  - `adapters/file.sh`: target の `source`(`HARNESS_SOURCE_DIR` 相対)を staging に `cp`

- [ ] **Step 1: Task 3 のテストを追加する**

`test/harness-sync.bats` の末尾に追加:

```bash
# ---------- Task 3: Atomic Sync ----------

# two_targets: file adapter と flaky adapter の target を 1 つずつ持つ manifest と source を用意する
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
    sleep 1
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
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `just test-harness-sync`
Expected: Task 3 の 6 件が FAIL(`cmd_sync` 未定義で `command not found`)。他 20 件は PASS

- [ ] **Step 3: `harness/adapters/file.sh` を書く**

```bash
#!/usr/bin/env bash
# 組み込み Runtime Adapter "file": Source ファイルをそのまま Target 内容にする。
# 契約: file.sh render <staging-file> <target-json>
#   env HARNESS_SOURCE_DIR からの相対パス target.source を <staging-file> に cp する。
#   source 欠落・不在は exit 1(spec「Runtime Adapter 契約」)。
set -euo pipefail

if ! { [ "${1:-}" = render ] && [ $# -eq 3 ]; }; then
    echo "file adapter: 使い方: file.sh render <staging-file> <target-json>" >&2
    exit 64
fi
staging=$2
target=$3

source_rel=$(jq -r '.source // empty' <<<"$target")
[ -n "$source_rel" ] || {
    echo "file adapter: target に source がありません: $target" >&2
    exit 1
}
source_path="$HARNESS_SOURCE_DIR/$source_rel"
[ -f "$source_path" ] || {
    echo "file adapter: source がありません: $source_path" >&2
    exit 1
}
cp "$source_path" "$staging"
```

`chmod +x harness/adapters/file.sh` を実行する。

- [ ] **Step 4: `harness/lib/render.bash` を書く**

```bash
#!/usr/bin/env bash
# Runtime Adapter の実行・staging・全体検証・置換・drift 比較。harness.sh から source される。
# 依存: report.bash、manifest.bash、export 済みの HARNESS_ROOT / HARNESS_SOURCE_DIR / HARNESS_MANIFEST
#
# Atomic Sync(spec「sync の手順」): 全 target を staging に render し、全体検証に通ってから
# live と同じディレクトリに一時ファイルを書いて mv で置換する。
# 同一ファイルシステム内の rename なので Target は「旧内容」か「新内容」のどちらかしか観測されない。

# target_selected TARGET_JSON RUNTIME_FILTER: filter が空か runtime が一致すれば 0
target_selected() {
    local target=$1 filter=$2
    [ -z "$filter" ] || [ "$(jq -r .runtime <<<"$target")" = "$filter" ]
}

# render_all STAGING_DIR [RUNTIME_FILTER]: 対象 target を STAGING_DIR/<index> に render する。
# 失敗した target は report_fail し、1 件でもあれば最後に return 1(live には触れない)
render_all() {
    local staging=$1 filter=${2:-} count i target path owner adapter status failed=0
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        target_selected "$target" "$filter" || continue
        path=$(jq -r .path <<<"$target")
        owner=$(jq -r .owner <<<"$target")
        adapter=$(adapter_path "$owner")
        status=0
        "$adapter" render "$staging/$i" "$target" || status=$?
        if [ "$status" -ne 0 ]; then
            report_fail "target $path: adapter $owner が exit $status"
            failed=1
        elif [ ! -f "$staging/$i" ]; then
            report_fail "target $path: adapter $owner が出力を生成しませんでした"
            failed=1
        fi
    done
    return "$failed"
}

# validate_staging STAGING_DIR [RUNTIME_FILTER]: 対象 target 全件の staging が通常ファイルなら 0
validate_staging() {
    local staging=$1 filter=${2:-} count i target
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        target_selected "$target" "$filter" || continue
        [ -f "$staging/$i" ] || return 1
    done
    return 0
}

# replace_all STAGING_DIR: staging を live に反映する。内容が同じなら mv せず mtime も変えない。
# 最後に "harness sync: N updated, M unchanged" を出力する
replace_all() {
    local staging=$1 count i path live tmp updated=0 unchanged=0
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        path=$(manifest_target "$i" | jq -r .path)
        live="$HARNESS_ROOT/$path"
        if [ -f "$live" ] && cmp -s "$staging/$i" "$live"; then
            printf 'unchanged %s\n' "$path"
            unchanged=$((unchanged + 1))
            continue
        fi
        mkdir -p "$(dirname "$live")"
        # 一時ファイルは live と同じディレクトリに置く(別ファイルシステムの mv は copy+unlink で原子的でない)。
        # モードは staging(= adapter 出力)に従う
        tmp="$(dirname "$live")/.$(basename "$live").harness-tmp.$$"
        cp "$staging/$i" "$tmp"
        mv -f "$tmp" "$live"
        printf 'updated   %s\n' "$path"
        updated=$((updated + 1))
    done
    printf 'harness sync: %d updated, %d unchanged\n' "$updated" "$unchanged"
}
```

- [ ] **Step 5: `harness.sh` に source と `cmd_sync` を追加する**

`source "$HARNESS_HOME/lib/probe.bash"` の直後に追加:

```bash
# shellcheck source=../lib/render.bash
source "$HARNESS_HOME/lib/render.bash"
```

`cmd_check` の直後に追加:

```bash
# cmd_sync RUNTIME_FILTER: Atomic Sync。RUNTIME_FILTER は受け取るが sync は常に全 target を対象にする
# (1 runtime だけ新版に進む状態を作らないため。#308「a failure cannot leave only one product on a new policy version」)
cmd_sync() {
    HARNESS_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/harness-sync-XXXXXX")

    if ! render_all "$HARNESS_STAGING" || ! validate_staging "$HARNESS_STAGING"; then
        die 1 "harness sync: render に失敗したため Target を変更しませんでした"
    fi
    replace_all "$HARNESS_STAGING"
}
```

- [ ] **Step 6: テストと lint を通す**

Run: `just test-harness-sync && just shellcheck && just shfmt`
Expected: 26 件 PASS、lint エラーなし

- [ ] **Step 7: Commit**

```bash
git add harness/lib/render.bash harness/adapters/file.sh harness/bin/harness.sh test/harness-sync.bats
git commit -m "feat(harness): Atomic Sync と file adapter を追加 (#309)"
```

---

### Task 4: drift 検出(`check` の Target 比較)

**Files:**
- Modify: `harness/lib/render.bash`(`compare_all` 追加)
- Modify: `harness/bin/harness.sh`(`cmd_check` に staging render と比較を追加)
- Modify: `test/harness-sync.bats`(Task 4 のテストを末尾に追加)

**Interfaces:**
- Consumes: `render_all` / `target_selected` / `manifest_target*`、`report_ok` / `report_drift`
- Produces: `compare_all STAGING_DIR [RUNTIME_FILTER]`(staging が存在する対象 target について live と比較し、`OK   target <path>` / `DRIFT target <path>: ... (owner: <owner>)` を報告)

- [ ] **Step 1: Task 4 のテストを追加する**

`test/harness-sync.bats` の末尾に追加:

```bash
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

@test "check は staging を残さない" {
    stub_all
    two_targets
    sync
    run check
    assert_success
    assert_equal "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" '0'
}
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `just test-harness-sync`
Expected: Task 4 の 6 件が FAIL(`OK   target` / `DRIFT` 行が無い)。他 26 件は PASS

- [ ] **Step 3: `render.bash` に `compare_all` を追加する**

`replace_all` の直後に追加:

```bash
# compare_all STAGING_DIR [RUNTIME_FILTER]: staging と live を比較して drift を報告する。live は変更しない。
# render に失敗した target(staging が無い)は render_all が FAIL 済みなので飛ばす
compare_all() {
    local staging=$1 filter=${2:-} count i target path owner live
    count=$(manifest_target_count)
    for ((i = 0; i < count; i++)); do
        target=$(manifest_target "$i")
        target_selected "$target" "$filter" || continue
        [ -f "$staging/$i" ] || continue
        path=$(jq -r .path <<<"$target")
        owner=$(jq -r .owner <<<"$target")
        live="$HARNESS_ROOT/$path"
        if [ ! -f "$live" ]; then
            report_drift "target $path: 存在しません (owner: $owner)"
        elif ! cmp -s "$staging/$i" "$live"; then
            report_drift "target $path: 内容が Source と異なります (owner: $owner)"
        else
            report_ok "target $path"
        fi
    done
}
```

- [ ] **Step 4: `cmd_check` に drift 比較を追加する**

`cmd_check` 内の `for name in "${runtimes[@]}"; do ... done` の直後、`report_summary check` の前に追加:

```bash
    # drift: 対象 runtime の target を staging に render して live と比較する(live は変更しない)
    HARNESS_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/harness-check-XXXXXX")
    render_all "$HARNESS_STAGING" "$filter" || true
    compare_all "$HARNESS_STAGING" "$filter"
```

`cmd_check` の冒頭コメントを「runtime の Capability Probe と Target の drift 比較」に直す。

- [ ] **Step 5: テストと lint を通す**

Run: `just test-harness-sync && just shellcheck && just shfmt`
Expected: 32 件 PASS、lint エラーなし

- [ ] **Step 6: Commit**

```bash
git add harness/lib/render.bash harness/bin/harness.sh test/harness-sync.bats
git commit -m "feat(harness): check に Target の drift 検出を追加 (#309)"
```

---

### Task 5: 本物の manifest・CI・ドキュメント

**Files:**
- Create: `harness/manifest.json`
- Modify: `.github/workflows/lint.yml`(`harness-loop-scripts` job の直後に `harness-sync` job)
- Modify: `.claude/rules/shell-scripts.md`(frontmatter `paths` に `harness/**`)
- Modify: `CONTEXT.md`(`### Harness sync` セクション追加)
- Modify: `CLAUDE.md`(Key Patterns に段落追加、Directory Layout に行追加、Verification に `just test-harness-sync`)
- Modify: `test/harness-sync.bats`(本物の manifest を読むテストを末尾に追加)

**Interfaces:**
- Consumes: Task 1〜4 の `harness.sh check`、spec「本物の manifest」の表
- Produces: `harness/manifest.json`(`harness.sh` の既定 manifest)

- [ ] **Step 1: 本物の manifest を読むテストを追加する**

`test/harness-sync.bats` の末尾に追加:

```bash
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
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `just test-harness-sync`
Expected: 新規 1 件が FAIL(`manifest: ファイルがありません`)

- [ ] **Step 3: `harness/manifest.json` を書く**

```json
{
  "version": 1,
  "runtimes": {
    "claude": {
      "bin": "claude",
      "minVersion": "2.1.268",
      "maxVerifiedVersion": "2.1.268",
      "capabilities": [
        { "name": "settings-flag", "args": ["--help"], "pattern": "--settings" },
        { "name": "mcp-config-flag", "args": ["--help"], "pattern": "--mcp-config" },
        { "name": "plugin-dir-flag", "args": ["--help"], "pattern": "--plugin-dir" }
      ]
    },
    "codex": {
      "bin": "codex",
      "minVersion": "0.147.0",
      "maxVerifiedVersion": "0.147.0",
      "capabilities": [
        { "name": "mcp-subcommand", "args": ["--help"], "pattern": "^ +mcp " },
        { "name": "exec-subcommand", "args": ["--help"], "pattern": "^ +exec " },
        { "name": "sandbox-subcommand", "args": ["--help"], "pattern": "^ +sandbox " }
      ]
    },
    "cursor": {
      "bin": "cursor",
      "minVersion": "3.17.21",
      "maxVerifiedVersion": "3.17.21",
      "capabilities": [
        { "name": "user-data-dir-flag", "args": ["--help"], "pattern": "--user-data-dir" },
        { "name": "install-extension-flag", "args": ["--help"], "pattern": "--install-extension" }
      ]
    },
    "apm": {
      "bin": "apm",
      "minVersion": "0.30.0",
      "maxVerifiedVersion": "0.30.0",
      "capabilities": [
        { "name": "install-subcommand", "args": ["--help"], "pattern": "^ +install " },
        { "name": "audit-subcommand", "args": ["--help"], "pattern": "^ +audit " },
        { "name": "prune-subcommand", "args": ["--help"], "pattern": "^ +prune " }
      ]
    }
  },
  "targets": []
}
```

`pnpm exec oxfmt --write harness/manifest.json` で整形し、`just oxfmt` を通す。

- [ ] **Step 4: このマシンで本物の check を 1 回実行する(AC1 の手動確認)**

Run: `bash harness/bin/harness.sh check`
Expected: `OK   runtime apm 0.30.0` / `OK   runtime claude 2.1.268` / `OK   runtime codex 0.147.0` / `OK   runtime cursor 3.17.21` / `harness check: 0 failures, 0 warnings`、exit 0。出力を report に貼る。バージョンが上がっていて WARN になった場合は、その版で capability が全部 OK なら `maxVerifiedVersion` をその版に更新して再実行し、その旨を report に書く。

- [ ] **Step 5: CI job を追加する**

`.github/workflows/lint.yml` の `harness-loop-scripts:` job ブロック(`harness-loop-scripts:` から次の job 名の直前まで)をコピーし、直後に貼って job 名を `harness-sync:`、`name:` があれば `harness-sync` に、最後の `run:` を `just test-harness-sync` に変える。他の行(checkout / pnpm / node / just のインストール)は完全に同一にする。

Run: `just actionlint && just zizmor`
Expected: エラーなし

- [ ] **Step 6: `.claude/rules/shell-scripts.md` の frontmatter に追記する**

`paths:` の配列に `- "harness/**"` を追加する(他の行は変えない)。

- [ ] **Step 7: `CONTEXT.md` に用語を追加する**

`### Verification` セクションの直後(`### Profiles` の前)に追加:

```markdown
### Harness sync

**Harness Manifest**:
runtime・必須 capability・Target とその Owner を機械検証可能に宣言する JSON(`harness/manifest.json`)。runtime は明示必須で、暗黙検出は reject される。
_Avoid_: 設定ファイル(無限定)、マニフェスト(無限定)

**Target Owner**:
ある Target の最終内容を書く唯一のコンポーネント。Harness Manifest では 1 target につき 1 つの adapter 名で指名し、同じ path を 2 つの owner が持つ manifest は無効。
_Avoid_: 生成元、担当

**Runtime Adapter**:
Harness Policy を製品固有の表現に render する実行体(`harness/adapters/<owner>.sh render <staging-file> <target-json>`)。Target Owner として指名される。
_Avoid_: ジェネレータ、プラグイン

**Atomic Sync**:
全 Target を staging に render し、全体が検証に通った後だけ live を置換する同期方式。1 つでも render に失敗すれば既存 Target は 1 つも変わらない。
_Avoid_: 一括同期、上書き

**Capability Probe**:
製品のバージョン文字列ではなく、実際の挙動(`--help` 出力等)で必須機能の有無を確かめる検査。存在しない・minVersion 未満・capability 欠落は FAIL、maxVerifiedVersion 超は WARN。
_Avoid_: バージョンチェック、互換性チェック
```

- [ ] **Step 8: `CLAUDE.md` を更新する**

(a) Key Patterns の「**Harness self-improvement loop**」段落の直後に追加:

```markdown
**Harness sync seam (`harness/`)** — Claude Code / Codex / Cursor / APM の harness 設定を 1 つの Harness Manifest(`harness/manifest.json`)から検証・同期する repo-only ツール(#308 の基盤、#309)。`bash harness/bin/harness.sh check` が 4 runtime の Capability Probe と Target の drift を報告し、`sync` が Atomic Sync(staging → 全体検証 → 置換)で Target を更新する。`init` / `update` は未実装(#322 / #323)。`harness/` は `.chezmoiignore` で除外され `~/` には配置されない。#309 時点では `targets` は空で、live の harness は変更しない。adapter は `harness/adapters/<owner>.sh render <staging-file> <target-json>` の契約で追加する。設計: `docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md`
```

(b) Directory Layout の表の `scripts/` 行の直前に追加:

```markdown
| `harness/` | Harness Manifest(`manifest.json`)と同期・検証ツール(`bin/harness.sh`、`lib/`、`adapters/`)。repo-only、`~/` に配置されない |
```

(c) Verification のコードブロック内、`just test-harness-scripts` 行の直後に追加:

```sh
just test-harness-sync         # Smoke test the harness sync/check seam (harness/bin/harness.sh)
```

- [ ] **Step 9: 全 lint を通す**

Run: `just lint`
Expected: 全レシピ成功(`test-harness-sync` が 33 件 PASS、`scan-sensitive` / `oxfmt` / `actionlint` / `zizmor` / `check-templates` を含む)

- [ ] **Step 10: Commit**

```bash
git add harness/manifest.json .github/workflows/lint.yml .claude/rules/shell-scripts.md CONTEXT.md CLAUDE.md test/harness-sync.bats
git commit -m "feat(harness): 本物の manifest・CI job・用語とドキュメントを追加 (#309)"
```
