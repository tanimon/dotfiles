#!/usr/bin/env bash
# 週ごとの Failure Pattern の再発率を記録し、PR 本文の推移の節を作る(Evaluator の一部。ADR 0011)。
# 週次ジョブが毎回の run で使う。
#
#   since <日付>                       この run の期間の始まり(epoch)を出す。<日付> より前の日付の
#                                      週の記録のうち最新のものの until。無ければ直近 7 日。期間を
#                                      heartbeat で決めないのは、失敗した run が heartbeat を進めず、
#                                      次の run の期間が前の記録と重なって二重に数えるため。同じ日の
#                                      記録は見ないので、同じ日の再実行はその日の記録を同じ期間の
#                                      始まりで書き直す
#   record <日付> --since <epoch> --classification ok|failed
#                                      期間(since, 今]の週の記録を
#                                      ~/.claude/harness/failure-pattern-rates/<日付>.json に書く
#   trend [--weeks <N>]                直近 N 週(既定 4)の記録から推移の節(Markdown)を出す
#
# 週の記録は id と数値だけを持つ(仕事の文脈を含まないので、週次ジョブがリポジトリに commit する)。
#   sessions        期間に検出器にかけたセッション数(detections.jsonl。失敗の無いセッションを含む)
#   detections      期間に検出した失敗の件数(detections.jsonl の counts の合計)
#   classified      期間に分類した失敗の件数(classifications.jsonl)。detections との差は、分類の
#                   失敗・件数の上限・transcript の欠落で分類しなかった分
#   classification  この run の分類器が成功したか(ok / failed)。failed の週は推移で「記録なし」と書く
#                   (0% と書くと改善したように読めるため)
#   patterns        一覧の id と "unclassified" ごとの {occurrences, sessions, rate}。rate はその
#                   Failure Pattern の失敗が 1 件以上あったセッションの割合(sessions が 0 なら null)
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
RATES_DIR="$HARNESS_DIR/failure-pattern-rates"
LEDGER="$HARNESS_DIR/detections.jsonl"
RECORDS="$HARNESS_DIR/classifications.jsonl"
PATTERNS="$HOME/.claude/scripts/harness-failure-patterns.json"

usage() {
    printf 'usage: harness-failure-rates.sh since <date> | record <date> --since <epoch> --classification ok|failed | trend [--weeks <n>]\n' >&2
    exit 2
}

fail() {
    printf 'harness-failure-rates: %s\n' "$1" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq not found'

# 日付の名前の週の記録を古い順に出す
record_files() {
    [[ -d "$RATES_DIR" ]] || return 0
    find "$RATES_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json' | sort
}

# JSON Lines のファイルから、epoch が期間(since, until]の object の行を配列で出す。読めない行は飛ばす
rows_in_period() {
    if [[ -f "$1" ]]; then
        jq -R -s -c --argjson since "$2" --argjson until "$3" '[split("\n")[] | (try fromjson catch null)
            | select(type == "object" and ((.epoch // 0) | type) == "number" and .epoch > $since and .epoch <= $until)]' "$1"
    else
        printf '[]\n'
    fi
}

cmd_since() {
    local date=$1 file name previous=""
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        name=$(basename "$file" .json)
        [[ "$name" < "$date" ]] && previous=$file
    done < <(record_files)
    if [[ -n "$previous" ]] && jq -e '.until | type == "number"' "$previous" >/dev/null 2>&1; then
        jq '.until' "$previous"
    else
        printf '%s\n' "$(($(date +%s) - 7 * 24 * 60 * 60))"
    fi
}

cmd_record() {
    local date=$1 since="" status="" until detections classifications ids tmp
    shift
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --since) since=${2:-} && shift 2 ;;
        --classification) status=${2:-} && shift 2 ;;
        *) usage ;;
        esac
    done
    [[ "$since" =~ ^[0-9]+$ && ("$status" == ok || "$status" == failed) ]] || usage
    ids=$(jq -c '[.patterns[].id]' "$PATTERNS") || fail "cannot read the Failure Pattern list $PATTERNS"
    until=$(date +%s)
    detections=$(rows_in_period "$LEDGER" "$since" "$until") || fail "cannot read $LEDGER"
    classifications=$(rows_in_period "$RECORDS" "$since" "$until") || fail "cannot read $RECORDS"
    mkdir -p "$RATES_DIR"
    tmp=$(mktemp "$RATES_DIR/.record.XXXXXX")
    jq -n --arg date "$date" --argjson since "$since" --argjson until "$until" --arg status "$status" \
        --argjson ids "$ids" --argjson detections "$detections" --argjson classifications "$classifications" '
        ($detections | map(.session_id) | unique | length) as $sessions
        | {date: $date, since: $since, until: $until, sessions: $sessions,
           detections: ($detections | map(.counts // {} | add // 0) | add // 0),
           classified: ($classifications | length), classification: $status,
           patterns: ([$ids[], "unclassified"] | map(. as $id
               | ($classifications | map(select(.pattern == $id))) as $hits
               | ($hits | map(.session_id) | unique | length) as $hit_sessions
               | {key: $id, value: {occurrences: ($hits | length), sessions: $hit_sessions,
                   rate: (if $sessions > 0 then ($hit_sessions / $sessions * 10000 | round / 10000) else null end)}})
               | from_entries)}' >"$tmp" || {
        rm -f "$tmp"
        fail "cannot build the record for $date"
    }
    mv "$tmp" "$RATES_DIR/$date.json"
    printf 'harness-failure-rates: recorded %s\n' "$RATES_DIR/$date.json"
}

cmd_trend() {
    local weeks=4 records="[]" ids file
    if [[ "${1:-}" == "--weeks" ]]; then
        weeks=${2:-}
    elif [[ $# -gt 0 ]]; then
        usage
    fi
    [[ "$weeks" =~ ^[1-9][0-9]*$ ]] || usage
    ids=$(jq -c '[.patterns[].id]' "$PATTERNS" 2>/dev/null) || ids="[]"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        records=$(jq -c --slurpfile record "$file" '. + $record' <<<"$records") || fail "cannot read $file"
    done < <(record_files | tail -n "$weeks")
    printf '\n## Failure Pattern の再発率\n\n'
    if [[ "$records" == "[]" ]]; then
        printf '週の記録はまだ無い。\n'
        return 0
    fi
    # shellcheck disable=SC2016 # jq のプログラム。バッククォートは Markdown のコードスパン
    jq -r --argjson ids "$ids" '
        def cell($r; $id):
            if $r.classification != "ok" then "記録なし"
            elif ($r.patterns[$id] // null) == null or $r.patterns[$id].rate == null then "-"
            else "\($r.patterns[$id].rate * 100 | round)% (\($r.patterns[$id].occurrences))" end;
        def row($label; $cells): "| \($label) | \($cells | join(" | ")) |";
        . as $records
        | ([$records[].patterns | keys[]] | unique) as $seen
        | ($ids + ($seen - $ids - ["unclassified"])) as $rows
        | "週ごとに、検出器にかけたセッションのうち、その Failure Pattern の失敗が 1 件以上あったセッションの割合(括弧内は失敗の件数)。「記録なし」はその週の分類に失敗したもの。",
          "",
          row("Failure Pattern"; $records | map(.date)),
          row("---"; $records | map("---:")),
          ($rows[] as $id | row("`\($id)`"; $records | map(cell(.; $id)))),
          row("未分類"; $records | map(cell(.; "unclassified"))),
          row("セッション数"; $records | map(.sessions | tostring)),
          row("分類した失敗 / 検出した失敗"; $records | map("\(.classified) / \(.detections)"))' <<<"$records"
}

case "${1:-}" in
since) [[ $# -eq 2 ]] || usage && cmd_since "$2" ;;
record) [[ $# -ge 2 ]] || usage && shift && cmd_record "$@" ;;
trend) shift && cmd_trend "$@" ;;
*) usage ;;
esac
