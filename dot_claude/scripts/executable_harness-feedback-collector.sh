#!/bin/bash
# Stop hook: Lightweight transcript analysis for harness improvement feedback.
#
# Reads the session transcript (via stdin JSON from Claude Code) and detects
# patterns that suggest harness improvements are needed:
# - Repeated tool failures (same command failing 3+ times)
# - Excessive file rewrites (same file edited 5+ times)
# - Error cascades (multiple consecutive errors)
#
# Writes findings to a project-specific temp file that harness-check.sh
# reads on the next session start.
#
# Exit 0 always — this hook must never block Claude Code shutdown.

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat) || exit 0

# Extract transcript_path from JSON input
TRANSCRIPT_PATH=$(echo "$INPUT" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//') || exit 0

if [[ -z "$TRANSCRIPT_PATH" ]]; then
    exit 0
fi

# Expand ~ if present
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# Validate path is under ~/.claude/projects/
ALLOWED_BASE="$HOME/.claude/projects"
RESOLVED_PATH=$(cd "$(dirname "$TRANSCRIPT_PATH")" 2>/dev/null && pwd)/$(basename "$TRANSCRIPT_PATH") 2>/dev/null || exit 0

case "$RESOLVED_PATH" in
"$ALLOWED_BASE"*) ;;
*) exit 0 ;;
esac

if [[ ! -f "$RESOLVED_PATH" ]]; then
    exit 0
fi

# Determine project identifier from transcript path
# Transcript paths follow: ~/.claude/projects/<encoded-project-path>/sessions/...
# Use the encoded segment directly as a stable key (avoids fragile decoding)
PROJECT_ENCODED=$(echo "$RESOLVED_PATH" | sed "s|$ALLOWED_BASE/||" | cut -d'/' -f1)

FEEDBACK_FILE="/tmp/claude-harness-feedback-${PROJECT_ENCODED}.md"

# Read last portion of transcript (64KB max, same as notify.mts)
TAIL_BYTES=65536
FILE_SIZE=$(stat -f%z "$RESOLVED_PATH" 2>/dev/null || stat -c%s "$RESOLVED_PATH" 2>/dev/null || echo 0)

if [[ "$FILE_SIZE" -eq 0 ]]; then
    exit 0
fi

CHUNK=$(tail -c "$TAIL_BYTES" "$RESOLVED_PATH" 2>/dev/null) || exit 0

FINDINGS=""

# --- Pattern 1: Repeated tool failures ---
# Look for "error" or "failed" in tool results
ERROR_COUNT=$(echo "$CHUNK" | grep -ci '"error"\|"failed"\|"EPERM"\|"ENOENT"\|"permission denied"\|エラー\|失敗\|拒否\|権限' 2>/dev/null || echo 0)
if [[ "$ERROR_COUNT" -ge 5 ]]; then
    FINDINGS+="- High error rate detected ($ERROR_COUNT error indicators). Consider adding rules to prevent common failures."$'\n'
fi

# --- Pattern 2: Excessive file rewrites ---
# Count Edit/Write tool uses to the same file
if command -v awk >/dev/null 2>&1; then
    REWRITE_FILES=$(echo "$CHUNK" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"//;s/"$//' | sort | uniq -c | sort -rn | awk '$1 >= 5 {print $2}' 2>/dev/null || true)
    if [[ -n "$REWRITE_FILES" ]]; then
        FINDINGS+="- Files edited excessively (5+ times): $(echo "$REWRITE_FILES" | head -3 | tr '\n' ', ' | sed 's/,$//'). This may indicate unclear requirements or missing patterns."$'\n'
    fi
fi

# --- Pattern 3: Bash command failures ---
BASH_ERRORS=$(echo "$CHUNK" | grep -c '"Exit code [^0]' 2>/dev/null || echo 0)
if [[ "$BASH_ERRORS" -ge 3 ]]; then
    FINDINGS+="- Multiple command failures detected ($BASH_ERRORS). Consider documenting correct commands in CLAUDE.md."$'\n'
fi

# --- Pattern 4: Problem-solving activity (suggests ce:compound value) ---
# Detect investigation/debugging patterns that produce documentable knowledge
SUGGEST_COMPOUND=false
INVESTIGATION_SIGNALS=$(echo "$CHUNK" | grep -ci '"root.cause\|"workaround\|"the fix\|"the issue was\|"discovered that\|"turns out\|"the problem\|"solution"\|原因\|回避策\|修正\|問題は\|判明\|分かった\|解決' 2>/dev/null || echo 0)
if [[ "$INVESTIGATION_SIGNALS" -ge 2 ]]; then
    SUGGEST_COMPOUND=true
fi
# Also suggest if there were both errors AND eventual success (debugging session)
if [[ "$ERROR_COUNT" -ge 3 ]] && [[ "$BASH_ERRORS" -lt "$ERROR_COUNT" ]]; then
    SUGGEST_COMPOUND=true
fi

# --- Write findings ---
if [[ -n "$FINDINGS" ]] || [[ "$SUGGEST_COMPOUND" == "true" ]]; then
    {
        echo "## Session Feedback ($(date '+%Y-%m-%d %H:%M'))"
        echo ""
        if [[ -n "$FINDINGS" ]]; then
            echo "$FINDINGS"
        fi
        if [[ "$SUGGEST_COMPOUND" == "true" ]]; then
            echo "- This session involved significant problem-solving. Run /ce:compound to document the solution in docs/solutions/."
        fi
    } >"$FEEDBACK_FILE"
fi

exit 0
