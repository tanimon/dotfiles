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
        if [[ "$DAYS" -ge "$REVIEW_OVERDUE_DAYS" && $((QUEUE_COUNT + PENDING_COUNT)) -gt 0 ]]; then
            WARNINGS+=("harness review overdue (${DAYS}d, ${QUEUE_COUNT} queued / ${PENDING_COUNT} pending) — run /harness-review")
        fi
    elif [[ $((QUEUE_COUNT + PENDING_COUNT)) -gt 0 ]]; then
        WARNINGS+=("harness review has never run and work is waiting — run /harness-review")
    fi
fi

if [[ "$PENDING_COUNT" -gt "$PENDING_MAX" ]]; then
    WARNINGS+=("unreflected sessions piling up (${PENDING_COUNT}) — run /harness-reflect")
elif [[ "$PENDING_COUNT" -gt 0 ]]; then
    OLDEST=$(jq -rs 'map(.recorded_epoch) | min // empty' "$PENDING" 2>/dev/null) || OLDEST=""
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

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    printf 'Harness: OK | queue: %s | pending: %s | last review: %s\n' \
        "$QUEUE_COUNT" "$PENDING_COUNT" "$LAST_REVIEW_TEXT"
else
    printf 'Harness: ATTENTION\n'
    for w in "${WARNINGS[@]}"; do
        printf ' - %s\n' "$w"
    done
fi

exit 0
