#!/usr/bin/env bash
# UserPromptSubmit hook: Session-start deterministic learning injection.
#
# On the first prompt of each session:
# 1. Checks pipeline health via pipeline-health.sh --json
# 2. Lists instincts at confidence >= 0.6 (broader than previous 0.7 threshold)
# 3. Checks CLAUDE.md existence
# 4. Prints compact harness evaluation reminder
#
# Replaces the previous harness-activator.sh.

set -euo pipefail

# Require jq for session_id extraction and JSON parsing
command -v jq >/dev/null 2>&1 || exit 0

# Read stdin immediately (can only be read once)
STDIN_JSON=$(cat)

# Extract session_id from stdin JSON (stable across all hook invocations in a session)
SESSION_ID=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty') || exit 0
[[ -z "$SESSION_ID" ]] && exit 0

# Per-session flag: only fire on first prompt (checked early, set after context guards)
FLAG_FILE="/tmp/claude-learning-briefing-${SESSION_ID}"
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

# --- Pipeline health section ---
HEALTH_MSG=""
PIPELINE_HEALTH_SCRIPT="$HOME/.claude/scripts/pipeline-health.sh"
if [[ -x "$PIPELINE_HEALTH_SCRIPT" ]]; then
    HEALTH_JSON=$("$PIPELINE_HEALTH_SCRIPT" --json 2>/dev/null) || true
    if [[ -n "$HEALTH_JSON" ]]; then
        OVERALL_STATUS=$(printf '%s' "$HEALTH_JSON" | jq -r '.overall_status // empty' 2>/dev/null) || true
        if [[ "$OVERALL_STATUS" == "healthy" ]]; then
            HEALTH_MSG="Pipeline: healthy"
        elif [[ "$OVERALL_STATUS" == "broken" ]]; then
            # Extract broken stages compactly
            BROKEN_STAGES=""
            OBS_STATUS=$(printf '%s' "$HEALTH_JSON" | jq -r '.stages.observation_capture.status // empty' 2>/dev/null) || true
            ANALYSIS_STATUS=$(printf '%s' "$HEALTH_JSON" | jq -r '.stages.observer_analysis.status // empty' 2>/dev/null) || true
            INSTINCT_STATUS=$(printf '%s' "$HEALTH_JSON" | jq -r '.stages.instinct_creation.status // empty' 2>/dev/null) || true
            [[ "$OBS_STATUS" == "broken" ]] && BROKEN_STAGES="observation_capture"
            [[ "$ANALYSIS_STATUS" == "broken" ]] && BROKEN_STAGES="${BROKEN_STAGES:+$BROKEN_STAGES, }observer_analysis"
            [[ "$INSTINCT_STATUS" == "broken" ]] && BROKEN_STAGES="${BROKEN_STAGES:+$BROKEN_STAGES, }instinct_creation"
            HEALTH_MSG="Pipeline: BROKEN (${BROKEN_STAGES})"
        fi
    fi
fi

# --- Instinct loading section ---
INSTINCT_MSG=""
HOMUNCULUS_DIR="$HOME/.claude/homunculus"
if [[ -d "$HOMUNCULUS_DIR/projects" ]]; then
    # Detect project ID using same approach as ECC (git remote URL hash)
    REMOTE_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)
    if [[ -n "$REMOTE_URL" ]]; then
        REMOTE_URL=$(printf '%s' "$REMOTE_URL" | sed -E 's|://[^@]+@|://|')
    fi
    HASH_INPUT="${REMOTE_URL:-$PROJECT_ROOT}"
    PROJECT_ID=$(printf '%s' "$HASH_INPUT" | shasum -a 256 2>/dev/null | cut -c1-12) ||
        PROJECT_ID=$(printf '%s' "$HASH_INPUT" | sha256sum 2>/dev/null | cut -c1-12) || true

    if [[ -n "$PROJECT_ID" ]]; then
        INSTINCT_DIR="$HOMUNCULUS_DIR/projects/$PROJECT_ID/instincts/personal"
        if [[ -d "$INSTINCT_DIR" ]]; then
            # Collect instincts with confidence >= 0.6
            INSTINCTS=""
            COUNT=0
            TOTAL=0

            # Build sorted list by confidence (descending)
            INSTINCT_ENTRIES=""
            for f in "$INSTINCT_DIR"/*.md "$INSTINCT_DIR"/*.yaml "$INSTINCT_DIR"/*.yml; do
                [[ -f "$f" ]] || continue
                CONFIDENCE=$(grep -m1 '^confidence:' "$f" 2>/dev/null | awk '{print $2}' || true)
                [[ -z "$CONFIDENCE" ]] && continue
                [[ "$CONFIDENCE" =~ ^[0-9]*\.?[0-9]+$ ]] || continue
                IS_HIGH=$(LC_NUMERIC=C awk -v c="$CONFIDENCE" 'BEGIN {print (c+0 >= 0.6) ? 1 : 0}' 2>/dev/null || echo "0")
                [[ "$IS_HIGH" != "1" ]] && continue

                TOTAL=$((TOTAL + 1))

                TRIGGER=$(grep -m1 '^trigger:' "$f" 2>/dev/null | sed 's/^trigger: *//' | sed 's/^"//' | sed 's/"$//' || true)
                DOMAIN=$(grep -m1 '^domain:' "$f" 2>/dev/null | awk '{print $2}' || true)
                [[ -z "$TRIGGER" ]] && continue

                # Extract first non-empty body line as action summary
                ACTION=""
                FRONTMATTER_DELIMITERS=0
                while IFS= read -r line; do
                    if [[ $FRONTMATTER_DELIMITERS -lt 2 ]]; then
                        # Count --- delimiters: first opens frontmatter, second closes it
                        if [[ "$line" == "---" ]]; then
                            FRONTMATTER_DELIMITERS=$((FRONTMATTER_DELIMITERS + 1))
                        fi
                    else
                        # First non-empty line after frontmatter closing ---
                        line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
                        if [[ -n "$line" ]]; then
                            ACTION="$line"
                            break
                        fi
                    fi
                done <"$f"

                # Store as sortable entry: confidence|domain|trigger|action
                INSTINCT_ENTRIES="${INSTINCT_ENTRIES}${CONFIDENCE}|${DOMAIN:-general}|${TRIGGER}|${ACTION}
"
            done

            # Sort by confidence descending, take top 15
            if [[ -n "$INSTINCT_ENTRIES" ]]; then
                SORTED=$(printf '%s' "$INSTINCT_ENTRIES" | sort -t'|' -k1 -rn | head -15)
                while IFS='|' read -r conf dom trig act; do
                    [[ -z "$conf" ]] && continue
                    if [[ -n "$act" ]]; then
                        INSTINCTS="${INSTINCTS}  - [${dom}] ${trig} — ${act} (${conf})
"
                    else
                        INSTINCTS="${INSTINCTS}  - [${dom}] ${trig} (${conf})
"
                    fi
                    COUNT=$((COUNT + 1))
                done <<<"$SORTED"
            fi

            if [[ -n "$INSTINCTS" ]]; then
                REMAINING=$((TOTAL - COUNT))
                INSTINCT_MSG="Learned Instincts (${COUNT} shown, project: ${PROJECT_ID}):
${INSTINCTS}"
                if [[ $REMAINING -gt 0 ]]; then
                    INSTINCT_MSG="${INSTINCT_MSG}  ... and ${REMAINING} more instincts
"
                fi
                INSTINCT_MSG="${INSTINCT_MSG}Use /instinct-status for details. /promote-instincts to convert to rules."
            fi
        fi
    fi
fi

# --- CLAUDE.md check ---
CLAUDE_MD_MSG=""
if [[ ! -f "$PROJECT_ROOT/CLAUDE.md" ]]; then
    CLAUDE_MD_MSG="No CLAUDE.md found. Run /scaffold-claude-md to generate one."
fi

# --- Output briefing ---
cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ECC Learning Briefing
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
${CLAUDE_MD_MSG:+${CLAUDE_MD_MSG}
}${HEALTH_MSG:+${HEALTH_MSG}
}${INSTINCT_MSG:+
${INSTINCT_MSG}
}
After this session: /propose-harness-improvement for failures,
/capture-harness-feedback for patterns, /ce:compound for solutions.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
