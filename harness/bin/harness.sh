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
        --manifest)
            manifest=$2
            shift 2
            ;;
        --root)
            root=$2
            shift 2
            ;;
        --source-dir)
            source_dir=$2
            shift 2
            ;;
        --runtime)
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

    [ -d "$root" ] || die 2 "harness: --root がディレクトリではありません: $root"
    [ -d "$source_dir" ] || die 2 "harness: --source-dir がディレクトリではありません: $source_dir"
    HARNESS_ROOT=$(cd "$root" && pwd)
    HARNESS_SOURCE_DIR=$(cd "$source_dir" && pwd)
    export HARNESS_ROOT HARNESS_SOURCE_DIR

    manifest_load "$manifest"
    "cmd_$command" "$runtime"
}

main "$@"
