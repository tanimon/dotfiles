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

# --- Load learned instincts from ECC continuous learning ---
INSTINCT_MSG=""
HOMUNCULUS_DIR="$HOME/.claude/homunculus"
if [[ -d "$HOMUNCULUS_DIR/projects" ]]; then
    # Detect project ID using same approach as ECC (git remote URL hash)
    REMOTE_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)
    # Strip embedded credentials from remote URL
    if [[ -n "$REMOTE_URL" ]]; then
        REMOTE_URL=$(printf '%s' "$REMOTE_URL" | sed -E 's|://[^@]+@|://|')
    fi
    HASH_INPUT="${REMOTE_URL:-$PROJECT_ROOT}"
    # Use shasum (macOS) or sha256sum (Linux) with graceful fallback
    PROJECT_ID=$(printf '%s' "$HASH_INPUT" | shasum -a 256 2>/dev/null | cut -c1-12) ||
        PROJECT_ID=$(printf '%s' "$HASH_INPUT" | sha256sum 2>/dev/null | cut -c1-12) || true
    # Skip instinct loading if project ID could not be computed
    if [[ -n "$PROJECT_ID" ]]; then
        INSTINCT_DIR="$HOMUNCULUS_DIR/projects/$PROJECT_ID/instincts/personal"
        if [[ -d "$INSTINCT_DIR" ]]; then
            # Read high-confidence instincts (>= 0.7) from YAML frontmatter
            INSTINCTS=""
            COUNT=0
            for f in "$INSTINCT_DIR"/*.md "$INSTINCT_DIR"/*.yaml "$INSTINCT_DIR"/*.yml; do
                [[ -f "$f" ]] || continue
                # Extract confidence from frontmatter
                CONFIDENCE=$(grep -m1 '^confidence:' "$f" 2>/dev/null | awk '{print $2}' || true)
                [[ -z "$CONFIDENCE" ]] && continue
                # Validate confidence is numeric to prevent code injection
                [[ "$CONFIDENCE" =~ ^[0-9]*\.?[0-9]+$ ]] || continue
                # Compare confidence >= 0.7 using awk (pass as variable, not code)
                IS_HIGH=$(awk -v c="$CONFIDENCE" 'BEGIN {print (c+0 >= 0.7) ? 1 : 0}' 2>/dev/null || echo "0")
                [[ "$IS_HIGH" != "1" ]] && continue

                TRIGGER=$(grep -m1 '^trigger:' "$f" 2>/dev/null | sed 's/^trigger: *//' | sed 's/^"//' | sed 's/"$//' || true)
                DOMAIN=$(grep -m1 '^domain:' "$f" 2>/dev/null | awk '{print $2}' || true)
                [[ -z "$TRIGGER" ]] && continue

                INSTINCTS="${INSTINCTS}  - [${DOMAIN:-general}] ${TRIGGER} (confidence: ${CONFIDENCE})
"
                COUNT=$((COUNT + 1))
                [[ $COUNT -ge 10 ]] && break
            done

            if [[ -n "$INSTINCTS" ]]; then
                INSTINCT_MSG="
📚 Learned Instincts (${COUNT} active, project: ${PROJECT_ID}):
${INSTINCTS}
Use /instinct-status for full details. /promote-instincts to convert to rules.
"
            fi
        fi
    fi
fi

# --- Harness evaluation reminder (claudeception pattern) ---
cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔧 HARNESS EVALUATION REMINDER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${CLAUDE_MD_MSG}${INSTINCT_MSG}
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
