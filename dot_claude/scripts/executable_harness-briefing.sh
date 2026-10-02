#!/usr/bin/env bash
# SessionStart hook: print harness self-improvement loop status.
#
# Deterministic by design — no LLM. Prints exactly one status block every
# session: an OK one-liner when healthy, or ATTENTION warnings each carrying
# a remediation command. Repeated silence across sessions means this hook
# itself is dead — that is the signal; do not add a quiet mode.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

HARNESS_DIR="$HOME/.claude/harness"
STATE="$HARNESS_DIR/state.json"
PENDING="$HARNESS_DIR/pending.jsonl"
QUEUE="$HARNESS_DIR/queue.md"

REVIEW_OVERDUE_DAYS=7
PENDING_MAX=5
PENDING_OLDEST_MAX_DAYS=20
QUEUE_MAX=10
# 週次ジョブの間隔(7 日)に、スリープ明けの追いつき実行の分の猶予を足す。
# harness-doctor.sh の WEEKLY_STALE_DAYS と揃えること
WEEKLY_STALE_DAYS=8
WEEKLY_PLIST="$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
WEEKLY_HEARTBEAT="$HARNESS_DIR/weekly-heartbeat"
WEEKLY_REMEDY="check ~/Library/Logs/harness-weekly.log, then run bash ~/.claude/scripts/harness-weekly.sh"

# Bootstrap on first run (new machine / after manual reset).
mkdir -p "$HARNESS_DIR"
[[ -f "$STATE" ]] || printf '{"version":1}\n' >"$STATE"
[[ -f "$PENDING" ]] || : >"$PENDING"
if [[ ! -f "$QUEUE" ]]; then
    printf '# Harness improvement queue\n\nAppended by /harness-reflect; processed by /harness-review.\n' >"$QUEUE"
fi

NOW=$(date +%s)
WARNINGS=()

STATE_OK=1
if ! jq empty "$STATE" 2>/dev/null; then
    STATE_OK=0
    WARNINGS+=("state.json is corrupt — delete $STATE and it will re-bootstrap")
fi

QUEUE_COUNT=$(grep -c '^## ' "$QUEUE" 2>/dev/null || true)
QUEUE_COUNT=${QUEUE_COUNT:-0}
PENDING_COUNT=$(grep -c . "$PENDING" 2>/dev/null || true)
PENDING_COUNT=${PENDING_COUNT:-0}

LAST_REVIEW_TEXT="never"
if [[ "$STATE_OK" -eq 1 ]]; then
    LAST_REVIEW=$(jq -r '.last_review_epoch // empty' "$STATE" 2>/dev/null) || LAST_REVIEW=""
    if [[ -n "$LAST_REVIEW" && ! "$LAST_REVIEW" =~ ^[0-9]+$ ]]; then
        WARNINGS+=("state.json has a non-numeric last_review_epoch — delete $STATE and it will re-bootstrap")
        LAST_REVIEW=""
    fi
    if [[ -n "$LAST_REVIEW" ]]; then
        DAYS=$(((NOW - LAST_REVIEW) / 86400))
        LAST_REVIEW_TEXT="${DAYS}d ago"
        # Warn even with an empty queue: /harness-review's staleness scan and
        # doctor check are valuable on their own, and rule rot is exactly the
        # silent decay this loop exists to catch.
        if [[ "$DAYS" -ge "$REVIEW_OVERDUE_DAYS" ]]; then
            WARNINGS+=("harness review overdue (${DAYS}d, ${QUEUE_COUNT} queued / ${PENDING_COUNT} pending) — run /harness-review")
        fi
    elif [[ $((QUEUE_COUNT + PENDING_COUNT)) -gt 0 ]]; then
        WARNINGS+=("harness review has never run and work is waiting — run /harness-review")
    fi
fi

if [[ "$PENDING_COUNT" -gt "$PENDING_MAX" ]]; then
    WARNINGS+=("unreflected sessions piling up (${PENDING_COUNT}) — run /harness-reflect")
elif [[ "$PENDING_COUNT" -gt 0 ]]; then
    # Per-line fromjson? so one malformed line or a missing/non-numeric
    # recorded_epoch cannot null-poison the min and suppress the warning.
    # sed (not head) so the sort side never sees SIGPIPE under pipefail.
    OLDEST=$(jq -Rr 'fromjson? | .recorded_epoch | select(type=="number")' "$PENDING" 2>/dev/null |
        sort -n | sed -n 1p) || OLDEST=""
    if [[ -n "$OLDEST" && "$OLDEST" =~ ^[0-9]+$ ]]; then
        OLDEST_DAYS=$(((NOW - OLDEST) / 86400))
        if [[ "$OLDEST_DAYS" -ge "$PENDING_OLDEST_MAX_DAYS" ]]; then
            WARNINGS+=("oldest unreflected session is ${OLDEST_DAYS}d old; its transcript may be auto-pruned soon — run /harness-reflect")
        fi
    fi
fi

if [[ "$QUEUE_COUNT" -gt "$QUEUE_MAX" ]]; then
    WARNINGS+=("improvement queue piling up (${QUEUE_COUNT} unprocessed) — run /harness-review")
fi

# 週次ジョブの heartbeat。plist が無いマシン(未 apply・Linux)ではジョブが
# 動く前提が無いので表示しない。heartbeat が無いのは、plist を置いてから
# 1 周期経っていなければ「まだ初回が来ていない」、経っていれば「動いていない」
WEEKLY_TEXT=""
if [[ -f "$WEEKLY_PLIST" ]]; then
    WEEKLY_TEXT="never"
    if [[ -f "$WEEKLY_HEARTBEAT" ]]; then
        HEARTBEAT=$(tr -d '[:space:]' <"$WEEKLY_HEARTBEAT" 2>/dev/null) || HEARTBEAT=""
        if [[ "$HEARTBEAT" =~ ^[0-9]+$ ]]; then
            WEEKLY_DAYS=$(((NOW - HEARTBEAT) / 86400))
            WEEKLY_TEXT="${WEEKLY_DAYS}d ago"
            if [[ "$WEEKLY_DAYS" -ge "$WEEKLY_STALE_DAYS" ]]; then
                WARNINGS+=("weekly job last succeeded ${WEEKLY_DAYS}d ago — $WEEKLY_REMEDY")
            fi
        else
            WARNINGS+=("weekly-heartbeat is not a number — delete $WEEKLY_HEARTBEAT and $WEEKLY_REMEDY")
        fi
    elif [[ -n "$(find "$WEEKLY_PLIST" -mtime +"$WEEKLY_STALE_DAYS" 2>/dev/null)" ]]; then
        WARNINGS+=("weekly job has never succeeded since it was installed — $WEEKLY_REMEDY")
    fi
fi

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    printf 'Harness: OK | queue: %s | pending: %s | last review: %s' \
        "$QUEUE_COUNT" "$PENDING_COUNT" "$LAST_REVIEW_TEXT"
    [[ -n "$WEEKLY_TEXT" ]] && printf ' | weekly: %s' "$WEEKLY_TEXT"
    printf '\n'
else
    printf 'Harness: ATTENTION\n'
    for w in "${WARNINGS[@]}"; do
        printf ' - %s\n' "$w"
    done
fi

exit 0
