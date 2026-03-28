#!/bin/bash
# UserPromptSubmit hook: Check project harness health on first prompt.
#
# Checks:
# 1. CLAUDE.md existence in the current project
# 2. Previous session's harness feedback (from harness-feedback-collector.sh)
#
# Uses a per-session flag file to avoid repeating the same check every prompt.
# Exit codes follow Claude Code hook semantics:
#   exit 0 = success/skip (silent, but stderr is still displayed)
#   exit 1 + stderr = error feedback displayed to agent
# We use exit 0 with stderr for non-blocking informational feedback.

set -euo pipefail

PROJECT_DIR="${PWD}"

# Skip checks in home directory or inside ~/.claude/
case "$PROJECT_DIR" in
"$HOME" | "$HOME/") exit 0 ;;
"$HOME/.claude"*) exit 0 ;;
esac

# Skip if not a git repo (likely not a project)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    exit 0
fi

# Get git root for consistent project identification
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Per-session flag to avoid repeating checks on every prompt
# CLAUDE_SESSION_ID is set by Claude Code; fall back to PPID (parent Claude process)
SESSION_ID="${CLAUDE_SESSION_ID:-$PPID}"
FLAG_FILE="/tmp/claude-harness-checked-${SESSION_ID}"

if [[ -f "$FLAG_FILE" ]]; then
    exit 0
fi

# Mark as checked for this session
touch "$FLAG_FILE"

FEEDBACK=""

# --- Check 1: Previous session feedback ---
# Match the key used by harness-feedback-collector.sh: the encoded project path
# segment from ~/.claude/projects/<encoded-project-path>/
# Claude Code encodes project paths by replacing / with - (with leading -)
PROJECT_ENCODED="${PROJECT_ROOT//\//-}"
FEEDBACK_FILE="/tmp/claude-harness-feedback-${PROJECT_ENCODED}.md"

if [[ -f "$FEEDBACK_FILE" ]] && [[ -s "$FEEDBACK_FILE" ]]; then
    FEEDBACK+="[Harness Feedback] Previous session detected potential issues:"$'\n'
    FEEDBACK+=$(cat "$FEEDBACK_FILE")
    FEEDBACK+=$'\n'
    FEEDBACK+="Run /capture-harness-feedback to create rules from these patterns."$'\n'
    rm -f "$FEEDBACK_FILE"
fi

# --- Check 2: CLAUDE.md existence ---
if [[ ! -f "$PROJECT_ROOT/CLAUDE.md" ]]; then
    FEEDBACK+="[Harness Check] No CLAUDE.md found in this project."$'\n'
    FEEDBACK+="Run /scaffold-claude-md to generate one, or /harness-health for a full diagnosis."$'\n'
fi

# --- Output feedback if any ---
if [[ -n "$FEEDBACK" ]]; then
    echo "$FEEDBACK" >&2
    exit 0
fi

exit 0
