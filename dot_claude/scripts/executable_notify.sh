#!/usr/bin/env bash
# Claude Code notification hook.
#
# Wired to Notification (permission requests, idle waits) and StopFailure
# (abnormal turn termination). Deliberately NOT wired to Stop: Stop fires on
# every assistant turn and was the original cause of notification fatigue.
#
# Silent inside orca workspaces. orca receives the same hook events via
# ~/.orca/agent-hooks/claude-hook.sh and emits its own notifications, with more
# accurate worktree/tab attribution than this script could reconstruct.
#
# Reads only hook_event_name, message, session_id, and cwd from the payload.
# The transcript is never opened.
#
# Design: docs/superpowers/specs/2026-07-25-notification-hook-redesign-design.md
set -euo pipefail

LOG_FILE="$HOME/.claude/logs/notify.log"
LOG_MAX_LINES=500
readonly LOG_FILE LOG_MAX_LINES

# Append one auditable line per invocation. The Notification `message` wording
# and StopFailure semantics are external contracts this repo does not control,
# so keeping a bounded record is what makes a misclassification diagnosable.
log_diagnostic() {
    local event="$1" kind="$2" message="$3" line_count
    mkdir -p "${LOG_FILE%/*}" 2>/dev/null || return 0
    printf '%s\tevent=%s\tkind=%s\tmessage=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$event" "$kind" "$message" \
        >>"$LOG_FILE" 2>/dev/null || return 0
    line_count=$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$line_count" -gt "$LOG_MAX_LINES" ]]; then
        if tail -n "$LOG_MAX_LINES" "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null; then
            mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || rm -f "${LOG_FILE}.tmp"
        fi
    fi
}

# --- 1. suppression gates ---------------------------------------------------

# Mirror orca's own forwarding gate in ~/.orca/agent-hooks/claude-hook.sh, which
# POSTs only when all three of these are set. If the port or token is missing,
# orca is not receiving the event and cannot notify, so this script must.
# Checking ORCA_PANE_KEY alone would open a silent no-notification gap.
if [[ -n "${ORCA_PANE_KEY:-}" ]] &&
    [[ -n "${ORCA_AGENT_HOOK_PORT:-}" ]] &&
    [[ -n "${ORCA_AGENT_HOOK_TOKEN:-}" ]]; then
    exit 0
fi

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
[[ -z "$payload" ]] && exit 0

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null) || exit 0
[[ -z "$event" ]] && exit 0

message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"
[[ -z "$session_id" ]] && session_id="unknown"

# --- 2. classification ------------------------------------------------------

case "$event" in
StopFailure)
    kind="エラー停止"
    glyph="⚠️"
    sound="Basso"
    body="ターンが異常終了しました"
    ;;
*)
    # Notification, and any future event, share the waiting-for-human shape.
    # An unrecognized event degrades to the lowest-priority kind rather than
    # to silence.
    body="$message"
    [[ -z "$body" ]] && body="応答を待っています"
    if [[ "$event" == "Notification" ]] &&
        printf '%s' "$message" | grep -qiE 'permission|approve|許可'; then
        kind="許可待ち"
        glyph="⏸"
        sound="Glass"
    else
        kind="入力待ち"
        glyph="💤"
        sound=""
    fi
    ;;
esac

# Attribution. Without it a notification cannot be acted on, because several
# sessions run in parallel and all of them look alike.
label=$(basename "$cwd")
branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [[ -n "$branch" && "$branch" != "HEAD" ]]; then
    label="$label ($branch)"
fi
title="$glyph $label"
group="claude-${session_id}"

# --- 3. send ----------------------------------------------------------------

log_diagnostic "$event" "$kind" "$message"

if [[ -n "${CLAUDE_NOTIFY_DRY_RUN:-}" ]]; then
    printf 'title=%s\nsubtitle=%s\nmessage=%s\nsound=%s\ngroup=%s\n' \
        "$title" "$kind" "$body" "$sound" "$group"
    exit 0
fi

exit 0
