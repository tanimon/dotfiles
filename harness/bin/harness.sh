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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/manifest.bash
source "$HARNESS_HOME/lib/manifest.bash"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/probe.bash
source "$HARNESS_HOME/lib/probe.bash"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/render.bash
source "$HARNESS_HOME/lib/render.bash"

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

# cmd_check RUNTIME_FILTER: runtime の Capability Probe と Target の drift 比較。
# RUNTIME_FILTER が空なら manifest の全 runtime、指定があればその 1 つだけ(明示選択)
cmd_check() {
    local filter=$1 name runtimes=()
    if [ -n "$filter" ]; then
        # shellcheck disable=SC2016 # $n は jq 自身の --arg 変数(シェル変数ではない)
        [ "$(manifest_query --arg n "$filter" '.runtimes | has($n)')" = "true" ] ||
            die 2 "harness check: runtime \"$filter\" は manifest に宣言されていません"
        runtimes=("$filter")
    else
        while IFS= read -r name; do
            runtimes+=("$name")
        done < <(manifest_runtimes)
    fi
    for name in "${runtimes[@]}"; do
        probe_runtime "$name"
    done

    # drift: 対象 runtime の target を staging に render して live と比較する(live は変更しない)
    HARNESS_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/harness-check-XXXXXX")
    render_all "$HARNESS_STAGING" "$filter" || true
    compare_all "$HARNESS_STAGING" "$filter"

    report_summary check
    [ "$HARNESS_FAILURES" -eq 0 ]
}

# cmd_sync RUNTIME_FILTER: Atomic Sync。RUNTIME_FILTER は受け取るが sync は常に全 target を対象にする
# (1 runtime だけ新版に進む状態を作らないため。#308「a failure cannot leave only one product on a new policy version」)
cmd_sync() {
    [ -z "$1" ] || die 64 "harness sync: --runtime は sync では使えません (sync は常に全 Target を対象にします)"
    HARNESS_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/harness-sync-XXXXXX")

    if ! render_all "$HARNESS_STAGING" || ! validate_staging "$HARNESS_STAGING"; then
        die 1 "harness sync: render に失敗したため Target を変更しませんでした"
    fi
    replace_all "$HARNESS_STAGING" || die 1 "harness sync: 一部の Target を置換できませんでした (上の FAIL 行を確認してください)"
}

main() {
    [ $# -ge 1 ] || {
        usage >&2
        exit 64
    }
    local command=$1
    shift

    local manifest="$HARNESS_HOME/manifest.json" root=${HOME:-} source_dir="$HARNESS_HOME/.." runtime=""
    while [ $# -gt 0 ]; do
        case $1 in
        --manifest)
            [ $# -ge 2 ] || die 64 "harness: $1 には値が必要です"
            manifest=$2
            shift 2
            ;;
        --root)
            [ $# -ge 2 ] || die 64 "harness: $1 には値が必要です"
            root=$2
            shift 2
            ;;
        --source-dir)
            [ $# -ge 2 ] || die 64 "harness: $1 には値が必要です"
            source_dir=$2
            shift 2
            ;;
        --runtime)
            [ $# -ge 2 ] || die 64 "harness: $1 には値が必要です"
            runtime=$2
            shift 2
            ;;
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

    [ -d "$root" ] || die 2 "harness: --root がディレクトリではありません (HOME 未設定なら --root を指定してください): $root"
    [ -d "$source_dir" ] || die 2 "harness: --source-dir がディレクトリではありません: $source_dir"
    HARNESS_ROOT=$(cd "$root" && pwd)
    HARNESS_SOURCE_DIR=$(cd "$source_dir" && pwd)
    export HARNESS_ROOT HARNESS_SOURCE_DIR

    manifest_load "$manifest"
    "cmd_$command" "$runtime"
}

main "$@"
