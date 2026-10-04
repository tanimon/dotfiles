#!/usr/bin/env bash
# SessionStart hook: print harness self-improvement loop status.
#
# Deterministic by design — no LLM. Prints exactly one status block every
# session: an OK one-liner when healthy, or ATTENTION warnings each carrying
# a remediation command. Repeated silence across sessions means this hook
# itself is dead — that is the signal; do not add a quiet mode.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# 週次ジョブの健全性の判定・状態ディレクトリの場所・初期化は lib にある(lib/harness-health.bash)。
# lib が無い・壊れているときも黙らない: 黙るのはこのフック自体が死んだときだけ、という約束を守るため。
# 素の source では、無いと exit 1、構文エラーだと exit 2、空だと関数が無いまま exit 127 で
# 黙って終わるので、読めること・構文・関数の有無を先に確かめる
HEALTH_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/harness-health.bash"
lib_broken() {
    printf 'Harness: ATTENTION\n'
    printf " - %s is missing or broken — run 'chezmoi apply'\n" "$HEALTH_LIB"
    exit 0
}
if [[ ! -r "$HEALTH_LIB" ]] || ! "$BASH" -n "$HEALTH_LIB" 2>/dev/null; then
    lib_broken
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/harness-health.bash
source "$HEALTH_LIB" 2>/dev/null || lib_broken
declare -F harness_health_dir harness_health_bootstrap harness_health_weekly >/dev/null || lib_broken

HARNESS_DIR=$(harness_health_dir) || lib_broken
STATE="$HARNESS_DIR/state.json"
PENDING="$HARNESS_DIR/pending.jsonl"
QUEUE="$HARNESS_DIR/queue.md"

REVIEW_OVERDUE_DAYS=7
PENDING_MAX=5
PENDING_OLDEST_MAX_DAYS=20
QUEUE_MAX=10

# Bootstrap on first run (new machine / after manual reset).
harness_health_bootstrap || lib_broken

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

# 週次ジョブの健全性。warn と fail はどちらも ATTENTION にする(level の意味は lib のコメント)
WEEKLY_TEXT=""
WEEKLY_OUT=$(harness_health_weekly) || lib_broken
while IFS=$'\t' read -r level message; do
    case $level in
    summary) WEEKLY_TEXT=$message ;;
    warn | fail) WARNINGS+=("$message") ;;
    esac
done <<<"$WEEKLY_OUT"

# 週次ジョブが残した Deploy-only Fix(harness-weekly.sh の record_deploy_only)。commit では
# 直らないので、人が適用してファイルを消すまで知らせ続ける
DEPLOY_ONLY="$HARNESS_DIR/deploy-only.md"
# 件数で判定する(項目だけ消して見出しが残ったファイルで警告し続けないため)
DEPLOY_ONLY_COUNT=0
if [[ -f "$DEPLOY_ONLY" ]]; then
    DEPLOY_ONLY_COUNT=$(grep -c '^- ' "$DEPLOY_ONLY" 2>/dev/null || true)
fi
if [[ "${DEPLOY_ONLY_COUNT:-0}" -gt 0 ]]; then
    WARNINGS+=("weekly job left deploy-only fix(es) to apply by hand (${DEPLOY_ONLY_COUNT}) — read $DEPLOY_ONLY, apply them, then delete it")
fi

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    printf 'Harness: OK | queue: %s | pending: %s | last review: %s' \
        "$QUEUE_COUNT" "$PENDING_COUNT" "$LAST_REVIEW_TEXT"
    [[ -n "$WEEKLY_TEXT" ]] && printf ' | %s' "$WEEKLY_TEXT"
    printf '\n'
else
    printf 'Harness: ATTENTION\n'
    for w in "${WARNINGS[@]}"; do
        printf ' - %s\n' "$w"
    done
fi

exit 0
