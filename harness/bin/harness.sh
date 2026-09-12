#!/usr/bin/env bash
# harness の入口。Claude Code / Codex / Cursor / APM の harness 設定を
# 1 つの Harness Manifest から検証・同期する(spec: docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md)。
#
# 使い方: harness.sh <check|sync|init|update> [--manifest PATH] [--root DIR] [--source-dir DIR] [--runtime NAME]
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

HARNESS_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export HARNESS_HOME

# shellcheck source=../lib/report.bash
source "$HARNESS_HOME/lib/report.bash"
# shellcheck source=../lib/manifest.bash
source "$HARNESS_HOME/lib/manifest.bash"
# shellcheck source=../lib/probe.bash
source "$HARNESS_HOME/lib/probe.bash"
# shellcheck source=../lib/render.bash
source "$HARNESS_HOME/lib/render.bash"

usage() {
    cat <<'USAGE'
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

exit codes:
  0    成功(check は WARN のみでも 0)
  1    check: FAIL / DRIFT が 1 件以上。sync: render または置換の失敗(FAIL 行を確認)
  2    manifest の不備、--root / --source-dir がディレクトリでない、jq が無い
  64   使い方の誤り(不明なコマンド・オプション、値の欠落、sync --runtime、未実装の init / update)
  130  INT / TERM / HUP による中断(staging と書きかけの一時ファイルは削除する)
USAGE
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
    render_all "$HARNESS_STAGING" "$filter" || true
    compare_all "$HARNESS_STAGING" "$filter"

    report_summary check
    [ "$HARNESS_FAILURES" -eq 0 ]
}

# cmd_sync RUNTIME_FILTER: Atomic Sync。RUNTIME_FILTER は受け取るが sync は常に全 target を対象にする
# (1 runtime だけ新版に進む状態を作らないため。#308「a failure cannot leave only one product on a new policy version」)
cmd_sync() {
    [ -z "$1" ] || die 64 "harness sync: --runtime は sync では使えません (sync は常に全 Target を対象にします)"
    # render_all が 0 を返した時点で全 target の staging が通常ファイルとして揃っている(全体検証)
    render_all "$HARNESS_STAGING" || die 1 "harness sync: render に失敗したため Target を変更しませんでした"
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
        --manifest | --root | --source-dir | --runtime)
            [ $# -ge 2 ] || die 64 "harness: $1 には値が必要です"
            case $1 in
            --manifest) manifest=$2 ;;
            --root) root=$2 ;;
            --source-dir) source_dir=$2 ;;
            --runtime) runtime=$2 ;;
            esac
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
    case $command in
    check) cmd_check "$runtime" ;;
    sync) cmd_sync "$runtime" ;;
    esac
}

# staging ディレクトリはスクリプト全体で 1 つ。親シェルで作り、main を subshell で走らせてから親が消す。
# EXIT trap で消す形にしないのは、bash 3.2(macOS の /bin/bash)では EXIT trap があると関数内の
# set -u 違反(unbound variable)の終了ステータスが 0 に潰れるため(ステータス保存型の trap でも直らない)。
# このツールの契約は終了コードなので、偽の成功を構造的に起こさない形にする
HARNESS_STAGING=$(mktemp -d "${TMPDIR:-/tmp}/harness-XXXXXX")
# INT / TERM / HUP は main の subshell に転送してから staging を消す(親だけが死んで subshell が
# 消えた staging の上で走り続けないため。subshell 側は replace_all の trap で書きかけの一時ファイルを消す)。
# `(main) || status=$?` の形にしない: || の左側では subshell 内の set -e が無効になる。
# 親で set +e にしてから subshell の中で set -e を立て直し、終了ステータスを wait で受ける。
# background(&)の subshell は既定で stdin が /dev/null になるので <&0 で親の stdin を引き継ぐ
HARNESS_MAIN_PID=
trap 'if [ -n "$HARNESS_MAIN_PID" ]; then kill -TERM "$HARNESS_MAIN_PID" 2>/dev/null; wait "$HARNESS_MAIN_PID" 2>/dev/null; fi; rm -rf "$HARNESS_STAGING"; exit 130' INT TERM HUP
set +e
(
    set -e
    main "$@"
) <&0 &
HARNESS_MAIN_PID=$!
wait "$HARNESS_MAIN_PID"
status=$?
rm -rf "$HARNESS_STAGING"
exit "$status"
