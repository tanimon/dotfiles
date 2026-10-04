#!/usr/bin/env bash
# 抽出(harness-reflect)の入力を、失敗の検出器(harness-detect-failures.sh)で選ぶ。
# 週次ジョブと手動の /harness-reflect の両方が、抽出の前にこれを 1 回実行する。
#
# ~/.claude/harness/pending.jsonl の各エントリの transcript を検出器にかけ、
#   - 検出が 0 件のエントリを pending から外す(抽出に回さない)
#   - セッションごとの信号別の件数を ~/.claude/harness/detections.jsonl に 1 行ずつ記録する
#     ({"session_id","run","date","counts":{<信号>:<件数>}}。0 件のセッションも counts を {} で記録する)
# 記録は session_id ごとに 1 回だけで、前の run で記録したセッションは数え直さない。抽出の上限で
# pending に残ったセッションや、途中で止まった run の後に残ったセッションを、次の週に重ねて数えないため。
# 週次ジョブは --run に自分の session id を渡し、PR の本文にはその run の行だけを集計して載せる。
# --run を省くと run は manual になる(手動の reflect が記録した件数は PR の本文には載らない)。
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

command -v jq >/dev/null 2>&1 || {
    printf 'harness-select-pending: jq not found\n' >&2
    exit 1
}
if [[ ! -f "$DETECTOR" ]]; then
    printf 'harness-select-pending: detector %s not found; pending left unchanged\n' "$DETECTOR" >&2
    exit 1
fi

scanned=0 selected=0 not_scanned=0
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
        if ! detections=$(bash "$DETECTOR" "$transcript"); then
            printf 'harness-select-pending: WARN detector failed on session %s; left it in pending\n' "$session_id" >&2
            not_scanned=$((not_scanned + 1))
            continue
        fi
        scanned=$((scanned + 1))
        if ! { [[ -f "$LEDGER" ]] && grep -qF "\"session_id\":\"$session_id\"" "$LEDGER"; }; then
            jq -cs --arg sid "$session_id" --arg run "$RUN" --arg date "$TODAY" \
                '{session_id: $sid, run: $run, date: $date,
                  counts: (group_by(.signal) | map({key: .[0].signal, value: length}) | from_entries)}' \
                <<<"$detections" >>"$LEDGER"
        fi
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
printf 'harness-select-pending: scanned=%s selected=%s dropped=%s not_scanned=%s\n' \
    "$scanned" "$selected" "$dropped" "$not_scanned"
