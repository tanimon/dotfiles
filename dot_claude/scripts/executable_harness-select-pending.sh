#!/usr/bin/env bash
# 抽出(harness-reflect)の入力を、失敗の検出器(harness-detect-failures.sh)で選ぶ。
# 週次ジョブと手動の /harness-reflect の両方が、抽出の前にこれを 1 回実行する。
#
# ~/.claude/harness/pending.jsonl の各エントリの transcript を検出器にかけ、
#   - 検出が 0 件のエントリを pending から外す(抽出に回さない)
#   - セッションごとの信号別の件数を ~/.claude/harness/detections.jsonl に追記する
#     ({"session_id","run","date","epoch","counts":{<信号>:<件数>}})
# 記録は増えた分だけを足す。初めて走査したセッションは全件を 1 行で記録し(0 件のセッションも counts を
# {} で記録する)、記録済みのセッションは、前の行の合計より増えた信号の差分だけを 1 行足す(増えて
# いなければ足さない)。抽出の上限で pending に残ったセッションを次の週に重ねて数えず、再開された
# セッションや実行中のセッションで後から増えた失敗も数えるため。セッションごとの行の合計が、最後に
# 走査した時点の件数になる。
# 週次ジョブは epoch で期間を切って PR の本文に載せる(harness-weekly.sh の detection_section)ので、
# 手動の /harness-reflect が先に記録した分も、その週の件数に入る。run(--run に渡した id。省くと
# manual)は、どの実行が記録したかを読むためだけに残す。
# detections.jsonl の JSON として読めない行は飛ばす(1 行の破損で選別を止めない)。
#
# transcript を読めないエントリと、パスが ~/.claude/projects/ 配下の .jsonl でないエントリは、
# 検出器にかけずに pending に残す(harness-reflect スキルが要約に明記して落とす)。判定はスキルと同じで、
# `..` を含むパスは正規化の前に外し、残りは realpath で正規化してから比べる。
# pending は SessionEnd hook が並行に追記するので、前に読んだ写しは書き戻さず、外す行だけを
# その場で grep -v で絞って mv する(harness-weekly.sh の strip_job_sessions と同じ)
set -euo pipefail

RUN=manual
if [[ "${1:-}" == "--run" && -n "${2:-}" ]]; then
    RUN=$2
elif [[ $# -gt 0 ]]; then
    printf 'usage: harness-select-pending.sh [--run <id>]\n' >&2
    exit 2
fi

HARNESS_DIR="$HOME/.claude/harness"
PENDING="$HARNESS_DIR/pending.jsonl"
LEDGER="$HARNESS_DIR/detections.jsonl"
DETECTOR="$HOME/.claude/scripts/harness-detect-failures.sh"
TODAY=$(date +%Y-%m-%d)
NOW=$(date +%s)

command -v jq >/dev/null 2>&1 || {
    printf 'harness-select-pending: jq not found\n' >&2
    exit 1
}
if [[ ! -f "$DETECTOR" ]]; then
    printf 'harness-select-pending: detector %s not found; pending left unchanged\n' "$DETECTOR" >&2
    exit 1
fi

scanned=0 selected=0 not_scanned=0 detector_failed=0
drop_ids=""
projects_root=""
if [[ -d "$HOME/.claude/projects" ]]; then
    projects_root=$(realpath "$HOME/.claude/projects")
fi

# transcript_path が ~/.claude/projects/ 配下の読める .jsonl なら、正規化したパスを出す
resolve_transcript() {
    local path=$1 resolved
    [[ -n "$projects_root" && "$path" == *.jsonl && "/$path/" != */../* ]] || return 1
    [[ -f "$path" && -r "$path" ]] || return 1
    resolved=$(realpath "$path" 2>/dev/null) || return 1
    [[ "$resolved" == "$projects_root"/* ]] || return 1
    printf '%s\n' "$resolved"
}

if [[ -f "$PENDING" ]]; then
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        session_id=$(jq -r '.session_id // empty' <<<"$entry" 2>/dev/null) || session_id=""
        transcript=$(jq -r '.transcript_path // empty' <<<"$entry" 2>/dev/null) || transcript=""
        if [[ -z "$session_id" ]] || ! transcript=$(resolve_transcript "$transcript"); then
            not_scanned=$((not_scanned + 1))
            continue
        fi
        # 検出器が失敗したエントリは、選ばれたとも外すとも決められないので pending に残し、
        # detector_failed として要約に分けて出す。抽出の側(harness-reflect スキル)は、検出器が失敗した
        # エントリを抽出せずに pending に残す。検出器の不具合でセッションを黙って捨てないため
        if ! detections=$(bash "$DETECTOR" "$transcript"); then
            printf 'harness-select-pending: WARN detector failed on session %s; left it in pending\n' "$session_id" >&2
            detector_failed=$((detector_failed + 1))
            continue
        fi
        scanned=$((scanned + 1))
        counts=$(jq -cs 'group_by(.signal) | map({key: .[0].signal, value: length}) | from_entries' <<<"$detections")
        ledger_source=/dev/null
        [[ -f "$LEDGER" ]] && ledger_source=$LEDGER
        jq -n -c --rawfile ledger "$ledger_source" --argjson counts "$counts" \
            --arg sid "$session_id" --arg run "$RUN" --arg date "$TODAY" --argjson epoch "$NOW" '
            [$ledger | split("\n")[] | (try fromjson catch null)
                | select(type == "object" and .session_id == $sid)] as $rows
            | (reduce ($rows[] | .counts // {} | to_entries[]) as $c ({}; .[$c.key] += $c.value)) as $recorded
            | ($counts | with_entries(.value -= ($recorded[.key] // 0)) | with_entries(select(.value > 0))) as $added
            | if ($rows | length) == 0 then {session_id: $sid, run: $run, date: $date, epoch: $epoch, counts: $counts}
              elif $added != {} then {session_id: $sid, run: $run, date: $date, epoch: $epoch, counts: $added}
              else empty end' >>"$LEDGER"
        if [[ -n "$detections" ]]; then
            selected=$((selected + 1))
        else
            drop_ids+="\"session_id\":\"${session_id}\""$'\n'
        fi
    done <"$PENDING"
fi

if [[ -n "$drop_ids" ]]; then
    tmp=$(mktemp "$HARNESS_DIR/.pending.XXXXXX")
    status=0
    grep -vF -f <(printf '%s' "$drop_ids") "$PENDING" >"$tmp" || status=$?
    if [[ "$status" -gt 1 ]]; then
        rm -f "$tmp"
        printf 'harness-select-pending: failed to filter %s (grep exit %s); left it unchanged\n' "$PENDING" "$status" >&2
        exit 1
    fi
    mv "$tmp" "$PENDING"
fi

dropped=$((scanned - selected))
printf 'harness-select-pending: scanned=%s selected=%s dropped=%s not_scanned=%s detector_failed=%s\n' \
    "$scanned" "$selected" "$dropped" "$not_scanned" "$detector_failed"
