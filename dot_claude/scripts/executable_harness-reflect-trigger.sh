#!/usr/bin/env bash
# SessionEnd hook: record the ended session for later harness reflection.
#
# Deterministic by design — no LLM here. Appends one JSON line per substantial
# session to ~/.claude/harness/pending.jsonl; the /harness-reflect skill
# consumes it in the next interactive session (deferred analysis, see
# docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md).
#
# Exit code contract: intentional skip = 0. This hook must never break
# session teardown, so every parse failure degrades to exit 0.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# Opt-out guard (also keeps scripted/CI runs from polluting the queue)
[[ -n "${HARNESS_DISABLE:-}" ]] && exit 0

STDIN_JSON=$(cat) || exit 0
SESSION_ID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[[ -z "$SESSION_ID" ]] && exit 0
TRANSCRIPT=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
CWD=$(printf '%s' "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

HARNESS_DIR="$HOME/.claude/harness"
PENDING="$HARNESS_DIR/pending.jsonl"
STATE="$HARNESS_DIR/state.json"
mkdir -p "$HARNESS_DIR"

# Record the trigger attempt (atomic tmp+rename; corrupt state resets to {}).
NOW_EPOCH=$(date +%s)
STATE_JSON="{}"
[[ -f "$STATE" ]] && STATE_JSON=$(cat "$STATE" 2>/dev/null || printf '{}')
printf '%s' "$STATE_JSON" | jq empty 2>/dev/null || STATE_JSON="{}"
TMP_STATE=$(mktemp "$HARNESS_DIR/.state.XXXXXX")
printf '%s' "$STATE_JSON" | jq --argjson now "$NOW_EPOCH" '.last_trigger_epoch = $now' >"$TMP_STATE"
mv "$TMP_STATE" "$STATE"

[[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && exit 0

# Gate: only sessions with enough assistant turns plausibly contain learnings.
TURN_THRESHOLD=10
TURNS=$(grep -c '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null || true)
TURNS=${TURNS:-0}
[[ "$TURNS" -lt "$TURN_THRESHOLD" ]] && exit 0

# Dedupe: a resumed session ends again under the same session_id.
if [[ -f "$PENDING" ]] && grep -qF "\"session_id\":\"$SESSION_ID\"" "$PENDING"; then
    exit 0
fi

jq -cn \
    --arg sid "$SESSION_ID" \
    --arg tp "$TRANSCRIPT" \
    --arg cwd "$CWD" \
    --argjson at "$NOW_EPOCH" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, recorded_epoch: $at}' >>"$PENDING"

exit 0
