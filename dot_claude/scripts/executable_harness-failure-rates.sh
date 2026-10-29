#!/usr/bin/env bash
# 週ごとの Failure Pattern の再発率の記録(Weekly Rate Record。GLOSSARY.md)を書き、PR 本文の推移の節と失敗の検出の節を
# 作る(Evaluator の一部。ADR 0011)。週次ジョブが毎回の run で使う。Weekly Rate Record の形式・期間・置き場と、
# 検出件数の記録(detections.jsonl)を期間で切る読み方の正本はこのスクリプト。
#
#   since <日付>                       この run の期間の始まり(epoch)を出す。<日付> より前の日付の
#                                      週の記録のうち、分類に成功した(classification: ok)最新のものの
#                                      until。その後に分類に失敗した週があれば、その週の期間も含める
#                                      (失敗した週の失敗をこの run でもう一度分類させるため。この run の
#                                      記録はその週の分も合わせた期間になり、失敗した週は推移で「記録なし」
#                                      のままなので二重には数えない)。成功した週が無ければ最も古い
#                                      失敗した週の since、記録が無ければ直近 7 日。期間を
#                                      heartbeat で決めないのは、heartbeat を書くのが run が最後まで成功したとき
#                                      だけだから。Weekly Rate Record を書いた後に失敗した run は、PR を作る前でも
#                                      作った後でも heartbeat を進めないので、heartbeat から数えると次の run の
#                                      期間が前の記録の期間(作った PR の本文の節が数えた期間)と重なって二重に
#                                      数える。同じ日の記録は見ないので、同じ日の再実行はその日の記録を
#                                      同じ期間の始まりで書き直す
#   record <日付> --since <epoch> --classification ok|failed
#                                      期間(since, 今]の週の記録を
#                                      ~/.claude/harness/failure-pattern-rates/<日付>.json に書く
#   trend <日付> [--weeks <N>]         <日付> 以前の直近 N 週(既定 4)の記録から推移の節(Markdown)を出す
#   detections <日付>                  <日付> の Weekly Rate Record の期間(since, until]に検出した失敗から、
#                                      失敗の検出の節(Markdown)を出す。表の行は期間に検出のあった信号だけで、
#                                      件数の多い順(同数なら信号名の順)。期間に 1 件も無ければ表を出さずに
#                                      合計 0 を書く。記録した実行(週次ジョブか手動の /harness-reflect か)は
#                                      問わない。選別は増えた分だけを記録する(harness-select-pending.sh の
#                                      ヘッダ)ので、期間で足せば重ねて数えない。<日付> の Weekly Rate Record が
#                                      無いか期間を読めなければ失敗する。推移の節と同じ <日付> で呼べば、2 つの
#                                      節は同じ Weekly Rate Record の期間を数え、件数の数え方も record と同じ
#                                      (detection_counts)。そのため分類に失敗した週の次の週は、since が
#                                      失敗した週の期間も含めるので、この節も前の週の PR と同じ期間を重ねて
#                                      数える(record の detections と同じ。節の 1 行目に期間が出る)
#   export <日付> --base <revision> --worktree <リポジトリの作業ツリー> [--dry-run]
#                                      ローカルの Weekly Rate Record のうち、<revision> の
#                                      docs/harness/failure-pattern-rates/ に無いものを、<作業ツリー> の同じ置き場に
#                                      そのまま写し、写した件数を「harness-failure-rates: exported <N> record(s)」
#                                      の 1 行で出す。--dry-run は
#                                      何も写さず(置き場も作らず)、写す件数を「harness-failure-rates: would export
#                                      <N> record(s)」の 1 行で出す。整形(oxfmt)・git add・commit と、写す直前の
#                                      データの照合は呼び出し側(週次ジョブの Loop PR の module)が行う
#
# export の選び方: <revision> に同じ名前の Weekly Rate Record が無ければ写す。閉じた PR や未マージの PR に
# 入っていた週も、<revision> に無ければ写す(ローカルの印では判定しない)。<日付>(その run の日付)の
# Weekly Rate Record だけは、<revision> にあっても中身が違えば写す。同じ日の再実行がその日の Weekly Rate Record を書き直すため
# (since は同じ日の Weekly Rate Record を見ない)。リポジトリ側は oxfmt を通してあるので、バイト列ではなく JSON として
# 比べ、どちらかが JSON として読めなければ違うものとして写す。ほかの日付は中身を比べない: <revision> の
# Weekly Rate Record を人が直したときにローカルの古い写しで戻さないためと、前の週の claude が書き換えた
# Weekly Rate Record(その週の後の run の Integrity Snapshot は書き換えた後の値を正として取るので見つけられない)で
# マージ済みのものを上書きしないため。同じ日の再実行が書き直した Weekly Rate Record を写さない週があることは、
# 呼び出し側(lib/harness-loop-pr.bash の harness_loop_pr_run_review)のコメントにある
#
# 週の記録は id と数値だけを持つ(仕事の文脈を含まないので、週次ジョブがリポジトリに commit する)。
#   sessions        期間に detections.jsonl に行があるセッション数。harness-select-pending.sh は、
#                   セッションを初めて走査したとき(失敗が無くても)と、前の記録より失敗が増えたときにだけ
#                   行を書く。そのため「期間に活動したセッション」ではなく「期間に初めて走査したセッションと、
#                   失敗が増えたセッション」の数になる
#   detections      期間に検出した失敗の件数(detections.jsonl の counts のうち数値の値の合計。detection_counts)
#   classified      期間に分類した失敗の件数(classifications.jsonl)。detections より少ない分は、分類の
#                   失敗・件数の上限・transcript の欠落で分類しなかった分。分類器は期間内に検出のあった
#                   セッションの、前の週に分類できなかった失敗もまとめて分類する
#                   (harness-classify-failures.sh のヘッダ)ので、classified と patterns の occurrences には
#                   前の週の失敗が入ることがあり、classified が detections を上回ることもある。rate も同じで、
#                   数えるセッションは期間内に検出のあったものに限られるが、そのセッションをある Failure Pattern
#                   に当たったと数える根拠の失敗は、期間より前のものでありうる
#   classification  この run の分類器が成功したか(ok / failed)。failed の週は推移で「記録なし」と書く
#                   (0% と書くと改善したように読めるため)
#   patterns        一覧の id と "unclassified" ごとの {occurrences, sessions, rate}。rate はその
#                   Failure Pattern の失敗が 1 件以上あったセッションの割合(sessions が 0 なら null)
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
RATES_DIR="$HARNESS_DIR/failure-pattern-rates"
# Weekly Rate Record のリポジトリ内の置き場。export が写す先
RATES_REPO_DIR="docs/harness/failure-pattern-rates"
LEDGER="$HARNESS_DIR/detections.jsonl"
RECORDS="$HARNESS_DIR/classifications.jsonl"
PATTERNS="$HOME/.claude/scripts/harness-failure-patterns.json"

usage() {
    printf 'usage: harness-failure-rates.sh since <date> | record <date> --since <epoch> --classification ok|failed | trend <date> [--weeks <n>] | detections <date> | export <date> --base <revision> --worktree <dir> [--dry-run]\n' >&2
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

# Weekly Rate Record のうち、日付が <日付> 以前のものを古い順に出す
record_files_up_to() { # <日付>
    local file
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        [[ "$(basename "$file" .json)" > "$1" ]] || printf '%s\n' "$file"
    done < <(record_files)
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

# 検出件数の記録の 1 行の counts から、値が数値の信号だけを {key, value} の配列で出す jq の定義。record の detections と
# 失敗の検出の節は、どちらもこの定義で数える(数え方が 2 つあると、同じ期間でも推移の節と失敗の検出の節の合計が食い違う)。
# counts が object でない行と数値でない値は数えない(読めない行を飛ばす rows_in_period と同じ扱い)
DETECTION_COUNTS_JQ='def detection_counts:
    .counts // {} | if type == "object" then to_entries | map(select(.value | type == "number")) else [] end;'

cmd_since() {
    local date=$1 file name earlier=() i until status oldest_failed="" now
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        name=$(basename "$file" .json)
        [[ "$name" < "$date" ]] && earlier+=("$file")
    done < <(record_files)
    # 新しい記録から遡り、分類に失敗した週は飛ばして、その週の始まりを候補にする
    for ((i = ${#earlier[@]} - 1; i >= 0; i--)); do
        file=${earlier[i]}
        # 前の週の記録が読めないときに直近 7 日へ戻すと、期間が前の記録と重なって二重に数える
        until=$(jq -e '.until | numbers' "$file" 2>/dev/null) || fail "cannot read .until from $file"
        status=$(jq -r '.classification' "$file" 2>/dev/null) || status=""
        case "$status" in
        ok)
            printf '%s\n' "$until"
            return 0
            ;;
        failed)
            oldest_failed=$(jq -e '.since | numbers' "$file" 2>/dev/null) || fail "cannot read .since from $file"
            ;;
        *) fail "cannot read .classification (ok or failed) from $file" ;;
        esac
    done
    if [[ -n "$oldest_failed" ]]; then
        printf '%s\n' "$oldest_failed"
        return 0
    fi
    now=$(date +%s)
    printf '%s\n' "$((now - 7 * 24 * 60 * 60))"
}

cmd_record() {
    local date=$1 since="" status="" until detections classifications ids tmp
    shift
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --since | --classification)
            [[ $# -ge 2 ]] || usage
            if [[ "$1" == --since ]]; then since=$2; else status=$2; fi
            shift 2
            ;;
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
        --argjson ids "$ids" --argjson detections "$detections" --argjson classifications "$classifications" "$DETECTION_COUNTS_JQ"'
        ($detections | map(.session_id) | unique | length) as $sessions
        | {date: $date, since: $since, until: $until, sessions: $sessions,
           detections: ($detections | map(detection_counts[].value) | add // 0),
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
    local date=$1 weeks=4 records="[]" ids file
    shift
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    if [[ "${1:-}" == "--weeks" ]]; then
        weeks=${2:-}
    elif [[ $# -gt 0 ]]; then
        usage
    fi
    [[ "$weeks" =~ ^[1-9][0-9]*$ ]] || usage
    ids=$(jq -c '[.patterns[].id]' "$PATTERNS") || fail "cannot read the Failure Pattern list $PATTERNS"
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        records=$(jq -c --slurpfile record "$file" '. + $record' <<<"$records") || fail "cannot read $file"
    done < <(record_files_up_to "$date" | tail -n "$weeks")
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

cmd_detections() {
    local date=$1 file since until rows
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    file="$RATES_DIR/$date.json"
    [[ -f "$file" ]] || fail "no weekly rate record for $date ($file)"
    since=$(jq -e '.since | numbers' "$file" 2>/dev/null) || fail "cannot read .since from $file"
    until=$(jq -e '.until | numbers' "$file" 2>/dev/null) || fail "cannot read .until from $file"
    rows=$(rows_in_period "$LEDGER" "$since" "$until") || fail "cannot read $LEDGER"
    # 時刻は jq で書く(date の -r と -d は BSD と GNU で違う)
    # shellcheck disable=SC2016 # jq のプログラム。バッククォートは Markdown のコードスパン
    jq -r --argjson since "$since" --argjson until "$until" "$DETECTION_COUNTS_JQ"'
        def time_label: localtime | strftime("%Y-%m-%d %H:%M");
        . as $rows
        | ($rows | map(.session_id) | unique | length) as $sessions
        | ($rows | map(select((detection_counts | map(.value) | add // 0) > 0) | .session_id) | unique | length) as $failing
        | ($rows | map(detection_counts[]) | group_by(.key) | map({signal: .[0].key, count: (map(.value) | add)})
            | map(select(.count > 0)) | sort_by([-.count, .signal])) as $signals
        | ($signals | map(.count) | add // 0) as $total
        | "", "## 失敗の検出", "",
          "\($since | time_label) から \($until | time_label) までに検出器にかけたセッション: \($sessions) 件(失敗あり \($failing) 件)。", "",
          if $total == 0 then "合計: 0"
          else "| 信号 | 件数 |", "|---|---:|", ($signals[] | "| `\(.signal)` | \(.count) |"), "| 合計 | \($total) |" end' <<<"$rows" ||
        fail "cannot build the detection section for $date"
}

# 写す Weekly Rate Record(ローカルのパス)を 1 行に 1 つ出す。選び方はヘッダの「export の選び方」。
# <ローカルの一覧> は record_files の出力、<base の一覧> は <revision> の置き場にあるファイルのリポジトリ内のパス。
# どちらも呼び出し側が失敗を確かめてから渡す(ここで列挙すると、プロセス置換やコマンド置換の中の失敗が
# 「0 件」や「base に無い」に化ける)
records_to_export() { # <日付> <revision> <作業ツリー> <ローカルの一覧> <base の一覧>
    local date=$1 base=$2 worktree=$3 local_files=$4 base_paths=$5 file name committed local_record
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        name=$(basename "$file")
        if ! grep -Fxq -- "$RATES_REPO_DIR/$name" <<<"$base_paths"; then
            printf '%s\n' "$file"
        elif [[ "$name" == "$date.json" ]]; then
            if ! committed=$(git -C "$worktree" show "$base:$RATES_REPO_DIR/$name" | jq -S -c . 2>/dev/null) ||
                ! local_record=$(jq -S -c . "$file" 2>/dev/null) || [[ "$committed" != "$local_record" ]]; then
                printf '%s\n' "$file"
            fi
        fi
    done <<<"$local_files"
}

cmd_export() {
    local date=$1 base="" worktree="" dry_run=0 local_files base_paths files file count=0
    shift
    [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --base)
            [[ $# -ge 2 ]] || usage
            base=$2
            shift 2
            ;;
        --worktree)
            [[ $# -ge 2 ]] || usage
            worktree=$2
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        *) usage ;;
        esac
    done
    [[ -n "$base" && -n "$worktree" ]] || usage
    # 引けない revision では、どの記録も「base に無い」と読んで全部を写してしまう
    git -C "$worktree" rev-parse --verify --quiet "$base^{commit}" >/dev/null || fail "cannot resolve $base in $worktree"
    local_files=$(record_files) || fail "cannot list the local weekly rate records in $RATES_DIR"
    # ls-tree は置き場が <revision> に無ければ空を出して成功し、git 自体の失敗だけを非 0 で返す
    base_paths=$(git -C "$worktree" ls-tree --name-only "$base" -- "$RATES_REPO_DIR/") ||
        fail "cannot list the weekly rate records in $base"
    files=$(records_to_export "$date" "$base" "$worktree" "$local_files" "$base_paths")
    if [[ "$dry_run" -eq 1 ]]; then
        count=$(grep -c . <<<"$files" || true)
        printf 'harness-failure-rates: would export %s record(s)\n' "$count"
        return 0
    fi
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        mkdir -p "$worktree/$RATES_REPO_DIR" || fail "cannot create $worktree/$RATES_REPO_DIR"
        cp "$file" "$worktree/$RATES_REPO_DIR/" || fail "cannot copy $file to $worktree/$RATES_REPO_DIR"
        count=$((count + 1))
    done <<<"$files"
    printf 'harness-failure-rates: exported %s record(s)\n' "$count"
}

case "${1:-}" in
since) [[ $# -eq 2 ]] || usage && cmd_since "$2" ;;
record) [[ $# -ge 2 ]] || usage && shift && cmd_record "$@" ;;
trend) [[ $# -ge 2 ]] || usage && shift && cmd_trend "$@" ;;
detections) [[ $# -eq 2 ]] || usage && cmd_detections "$2" ;;
export) [[ $# -ge 2 ]] || usage && shift && cmd_export "$@" ;;
*) usage ;;
esac
