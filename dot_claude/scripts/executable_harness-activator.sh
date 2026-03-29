#!/usr/bin/env bash
# UserPromptSubmit hook: Harness engineering activator (claudeception pattern).
#
# On the first prompt of each session:
# 1. Checks CLAUDE.md existence → suggests /scaffold-claude-md if missing
# 2. Prints harness evaluation reminder → agent self-evaluates improvements
#
# Delegates intelligence to the LLM instead of bash grep analysis.
# Replaces the previous harness-check.sh + harness-feedback-collector.sh system.

set -euo pipefail

# Require jq for session_id extraction
command -v jq >/dev/null 2>&1 || exit 0

# Extract session_id from stdin JSON (stable across all hook invocations in a session)
SESSION_ID=$(jq -r '.session_id // empty') || exit 0
[[ -z "$SESSION_ID" ]] && exit 0

# Per-session flag: only fire on first prompt (checked early, set after context guards)
FLAG_FILE="/tmp/claude-harness-checked-${SESSION_ID}"
[[ -f "$FLAG_FILE" ]] && exit 0

PROJECT_DIR="${PWD}"

# Skip non-project contexts (without consuming the one-shot flag)
case "$PROJECT_DIR" in
"$HOME" | "$HOME/") exit 0 ;;
"$HOME/.claude"*) exit 0 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Mark as checked only after confirming this is a project context
touch "$FLAG_FILE"

# --- CLAUDE.md check ---
CLAUDE_MD_MSG=""
if [[ ! -f "$PROJECT_ROOT/CLAUDE.md" ]]; then
    CLAUDE_MD_MSG="
⚠️  No CLAUDE.md found in this project.
Run /scaffold-claude-md to generate one, or /harness-health for a full diagnosis.
"
fi

# --- Harness evaluation reminder (claudeception pattern) ---
cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 HARNESS EVALUATION REMINDER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${CLAUDE_MD_MSG}
After completing this session's work, evaluate whether any
harness improvements are needed:

1. Did the agent make a preventable mistake?
   → Use Skill(propose-harness-improvement) with a description of:
     - What happened (concrete bad behavior)
     - Root cause (why it happened)
     - Suggested fix category (rule / hook / skill / solution doc)

2. Did a repeated failure pattern emerge (same error 3+ times)?
   → Run /capture-harness-feedback to create preventive rules

3. Was a non-trivial problem solved during this session?
   → Use Skill(compound-harness-knowledge) to document the solution
     OR run /ce:compound for the compound-engineering workflow

4. Check docs/solutions/ before proposing — the problem may already
   be documented with a known fix.

Only act if improvements are clearly warranted. No action needed
for routine, successful sessions.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
