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
# Reads only hook_event_name, notification_type, message, error, session_id, and
# cwd from the payload. The transcript is never opened.
#
# Design: docs/superpowers/specs/2026-07-25-notification-hook-redesign-design.md
set -euo pipefail

LOG_FILE="$HOME/.claude/logs/notify.log"
LOG_MAX_LINES=500
readonly LOG_FILE LOG_MAX_LINES

# Append one auditable line per invocation. The `notification_type` enum and the
# StopFailure `error` enum are external contracts this repo does not control, so
# keeping a bounded record of the raw discriminators alongside the classification
# is what makes a misclassification diagnosable. `message` is always empty for
# StopFailure, which is why `error` has to be logged separately.
log_diagnostic() {
    local event="$1" kind="$2" notification_type="$3" error="$4" message="$5" line_count
    mkdir -p "${LOG_FILE%/*}" 2>/dev/null || return 0
    printf '%s\tevent=%s\tkind=%s\tnotification_type=%s\terror=%s\tmessage=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$event" "$kind" \
        "$notification_type" "$error" "$message" \
        >>"$LOG_FILE" 2>/dev/null || return 0
    line_count=$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$line_count" -gt "$LOG_MAX_LINES" ]]; then
        if tail -n "$LOG_MAX_LINES" "$LOG_FILE" >"${LOG_FILE}.tmp" 2>/dev/null; then
            mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || rm -f "${LOG_FILE}.tmp"
        fi
    fi
}

# Shell command run when the notification is clicked. Brings the originating
# terminal forward; under tmux, also jumps to the exact pane. Prints nothing
# when the terminal cannot be identified, in which case the notification simply
# has no click action.
click_target() {
    local bundle=""
    case "${TERM_PROGRAM:-}" in
    ghostty) bundle="com.mitchellh.ghostty" ;;
    iTerm.app) bundle="com.googlecode.iterm2" ;;
    Apple_Terminal) bundle="com.apple.Terminal" ;;
    WezTerm) bundle="com.github.wez.wezterm" ;;
    esac

    if [[ -n "${TMUX:-}" && "${TMUX_PANE:-}" =~ ^[@%][0-9]+$ ]]; then
        # Activate the app first so the tmux switch lands on a visible window.
        [[ -n "$bundle" ]] && printf "open -b '%s'; " "$bundle"
        printf "tmux switch-client -t '%s' 2>/dev/null; " "$TMUX_PANE"
        printf "tmux select-window -t '%s'; " "$TMUX_PANE"
        printf "tmux select-pane -t '%s'" "$TMUX_PANE"
        return 0
    fi

    [[ -n "$bundle" ]] && printf "open -b '%s'" "$bundle"
    return 0
}

osascript_notify() {
    local title="$1" subtitle="$2" body="$3" sound="$4" script
    script='on run {t, s, m, snd}
  try
    if snd is "" then
      display notification m with title t subtitle s
    else
      display notification m with title t subtitle s sound name snd
    end if
  end try
end run'
    osascript -e "$script" "$title" "$subtitle" "$body" "$sound" >/dev/null 2>&1
}

send_notification() {
    local title="$1" subtitle="$2" body="$3" sound="$4" group="$5"
    local args jump

    # CLAUDE_NOTIFY_BACKEND pins the backend. Set it to "osascript" to exercise
    # the fallback path even when terminal-notifier is installed.
    if [[ "${CLAUDE_NOTIFY_BACKEND:-}" != "osascript" ]] &&
        command -v terminal-notifier >/dev/null 2>&1; then
        args=(-title "$title" -subtitle "$subtitle" -message "$body" -group "$group")
        [[ -n "$sound" ]] && args+=(-sound "$sound")
        jump=$(click_target)
        [[ -n "$jump" ]] && args+=(-execute "$jump")
        if terminal-notifier "${args[@]}" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi

    if command -v osascript >/dev/null 2>&1; then
        if osascript_notify "$title" "$subtitle" "$body" "$sound"; then
            return 0
        fi
        return 1
    fi

    return 1
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

notification_type=$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null || true)
message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null || true)
error=$(printf '%s' "$payload" | jq -r '.error // empty' 2>/dev/null || true)
session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && cwd="$PWD"
[[ -z "$session_id" ]] && session_id="unknown"

# --- 2. classification ------------------------------------------------------

# True when the payload is an approval dialog the user has to answer.
#
# `notification_type` is the payload's own discriminator, so it is what drives
# classification. Claude Code 2.1.x emits permission_prompt,
# worker_permission_prompt, idle_prompt, agent_needs_input, agent_completed,
# auth_success and elicitation_dialog/complete/response; the glob deliberately
# catches both *_permission_prompt forms, since the worker variant is a
# network-access approval dialog that blocks the same way.
#
# The message-regex branch is the fallback for a Claude Code that omits the
# field. `approv` rather than `approve` is deliberate: the product's literal is
# "needs your approval for …", which `approve` does not match.
is_permission_wait() {
    case "$notification_type" in
    *permission_prompt*) return 0 ;;
    "") printf '%s' "$message" | grep -qiE 'permission|approv|許可' ;;
    *) return 1 ;;
    esac
}

case "$event" in
StopFailure)
    kind="エラー停止"
    glyph="⚠️"
    sound="Basso"
    # `error` names the API failure (rate_limit, authentication_failed, …). It is
    # the only actionable field in the payload, so it goes in the banner body.
    if [[ -n "$error" ]]; then
        body="API エラーで停止: $error"
    else
        body="ターンが異常終了しました"
    fi
    ;;
*)
    # Notification, and any future event, share the waiting-for-human shape.
    # An unrecognized event or notification_type degrades to the lowest-priority
    # kind rather than to silence.
    body="$message"
    [[ -z "$body" ]] && body="応答を待っています"
    if [[ "$event" == "Notification" ]] && is_permission_wait; then
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

log_diagnostic "$event" "$kind" "$notification_type" "$error" "$message"

if [[ -n "${CLAUDE_NOTIFY_DRY_RUN:-}" ]]; then
    printf 'title=%s\nsubtitle=%s\nmessage=%s\nsound=%s\ngroup=%s\n' \
        "$title" "$kind" "$body" "$sound" "$group"
    exit 0
fi

# No backend available (e.g. Linux). Silent, intentional skip.
if ! command -v terminal-notifier >/dev/null 2>&1 &&
    ! command -v osascript >/dev/null 2>&1; then
    exit 0
fi

if ! send_notification "$title" "$kind" "$body" "$sound" "$group"; then
    echo "notify: delivery failed (event=$event kind=$kind)" >&2
fi

exit 0
