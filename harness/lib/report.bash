#!/usr/bin/env bash
# 報告行の出力と集計。harness.sh から source される(set は呼び出し側に従う)。
#
# 出力形式は spec「check の手順」の通り固定: OK / WARN / FAIL は先頭トークンを 5 桁に揃える
# (OK は後ろにスペース 3 つ)。DRIFT は spec が固定したトークンなので 6 桁のまま揃えない。
# bats が行の完全一致で検証しているので、桁数を変えないこと。

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
