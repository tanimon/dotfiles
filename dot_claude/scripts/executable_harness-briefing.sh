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

# Global instructions are harness-owned Targets under $HOME (#311): chezmoi
# apply no longer creates them, so a fresh machine has none until
# `just harness-sync-global` runs once (#324 wires it into apply). The gap is
# also written into this repo's generated CLAUDE.md, but that text only reaches
# an agent working *in* this repo — an agent missing its global instructions is
# by definition somewhere else. This hook is the only check that travels.
MISSING_GLOBAL=()
# The tildes are display text for the printed warning, never passed to a
# command — this repo's docs name these Targets as `~/.claude/CLAUDE.md`, and
# the message should match what the reader will grep for.
# shellcheck disable=SC2088
[[ -f "$HOME/.claude/CLAUDE.md" ]] || MISSING_GLOBAL+=("~/.claude/CLAUDE.md")
# shellcheck disable=SC2088
[[ -f "$HOME/.codex/AGENTS.md" ]] || MISSING_GLOBAL+=("~/.codex/AGENTS.md")
if [[ ${#MISSING_GLOBAL[@]} -gt 0 ]]; then
    WARNINGS+=("global instructions missing (${MISSING_GLOBAL[*]}) — run 'just harness-sync-global' in the chezmoi source repo")
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
