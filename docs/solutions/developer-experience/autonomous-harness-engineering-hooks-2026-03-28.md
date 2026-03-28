---
title: Autonomous Harness Engineering via Claude Code Hooks
date: 2026-03-28
problem_type: developer_experience
component: tooling
symptoms:
  - "Agent mistakes not captured as reusable rules"
  - "No automatic feedback loop between sessions"
  - "CLAUDE.md absence in projects goes unnoticed"
root_cause: missing_tooling
resolution_type: tooling_addition
severity: medium
tags:
  - harness-engineering
  - claude-code-hooks
  - session-start
  - stop-hook
  - user-prompt-submit
  - autonomous-feedback
---

# Autonomous Harness Engineering via Claude Code Hooks

## Problem

Harness engineering improvements (adding rules, updating CLAUDE.md, documenting solutions) required manual invocation of commands. There was no mechanism to automatically detect when improvements were needed or to carry feedback between sessions.

## Symptoms

- Agent repeated the same mistakes across sessions with no correction
- New projects had no CLAUDE.md, and agents didn't suggest creating one
- Problem-solving sessions produced valuable knowledge that was never documented
- `/clear` reset the conversation but harness checks didn't re-run

## What Didn't Work

- Relying on manual `/capture-harness-feedback` invocation — users forget
- Attempting to use LLM-based analysis in hooks — too slow for every prompt
- Using `$$` (current PID) for session flags — each hook invocation gets a different PID

## Solution

Three-hook architecture using Claude Code's hook system:

### 1. Stop Hook: Transcript Analysis (`harness-feedback-collector.sh`)

```bash
# Reads transcript_path from stdin JSON (same pattern as notify.mts)
INPUT=$(cat) || exit 0
TRANSCRIPT_PATH=$(echo "$INPUT" | grep -o '"transcript_path"...')

# Lightweight grep-based pattern detection (no LLM needed)
ERROR_COUNT=$(echo "$CHUNK" | grep -ci '"error"\|"failed"\|エラー\|失敗' ...)
INVESTIGATION_SIGNALS=$(echo "$CHUNK" | grep -ci '原因\|修正\|解決' ...)

# Write findings to /tmp for next session pickup
echo "$FINDINGS" > "/tmp/claude-harness-feedback-${PROJECT_ENCODED}.md"
```

### 2. UserPromptSubmit Hook: Session Start Check (`harness-check.sh`)

```bash
# Per-session flag using PPID (not $$) for stable identification
SESSION_ID="${CLAUDE_SESSION_ID:-$PPID}"
FLAG_FILE="/tmp/claude-harness-checked-${SESSION_ID}"

# Check 1: Read previous session's feedback file
if [[ -f "$FEEDBACK_FILE" ]]; then
    cat "$FEEDBACK_FILE" >&2  # stderr = displayed to agent
    rm -f "$FEEDBACK_FILE"    # one-time display
fi

# Check 2: CLAUDE.md existence
if [[ ! -f "$PROJECT_ROOT/CLAUDE.md" ]]; then
    echo "Run /scaffold-claude-md" >&2
fi
```

### 3. SessionStart Hook: /clear Reset

```json
{
  "SessionStart": [{
    "matcher": "clear",
    "hooks": [{
      "type": "command",
      "command": "bash -c 'rm -f /tmp/claude-harness-checked-\"${CLAUDE_SESSION_ID:-$PPID}\" || true'"
    }]
  }]
}
```

Key discovery: `SessionStart` event fires with `source: "clear"` specifically when `/clear` is executed. The `matcher: "clear"` filter distinguishes it from `startup`, `resume`, and `compact`.

### Project Key Matching

Both scripts must use the same key to find the feedback file. The collector extracts the encoded project path from the transcript path (`~/.claude/projects/<encoded>/sessions/...`), while the checker encodes the project root (`${PROJECT_ROOT//\//-}`). These must produce the same string.

## Why This Works

- **Stop hooks** run after every session end, providing a natural collection point
- **UserPromptSubmit hooks** run before the first prompt, providing a natural display point
- **SessionStart with matcher** enables `/clear` to reset the one-shot flag
- **stderr output** from hooks is displayed as agent feedback, enabling self-correction
- **/tmp files** provide ephemeral cross-session state that auto-cleans on reboot
- **grep-based analysis** is fast enough (<50ms) for hook execution without impacting UX

## Prevention

- When adding new hook scripts, always use `|| true` wrapping in settings.json to prevent hook failures from blocking Claude Code
- Use `exit 0` for intentional skips, `exit 1 + stderr` only for genuine errors (see `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`)
- For session-scoped flags, use `$PPID` (not `$$`) as fallback when `CLAUDE_SESSION_ID` is unavailable — `$$` changes with each hook invocation
- Include Japanese keywords in transcript analysis patterns when `"language": "japanese"` is configured

## Related

- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — Hook exit code contract
- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` — Sandbox considerations for hooks
- PR: https://github.com/tanimon/dotfiles/pull/54
