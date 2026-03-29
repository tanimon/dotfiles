---
title: Autonomous Harness Engineering via Claude Code Hooks
date: 2026-03-28
last_updated: 2026-03-29
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
- Using `$PPID` for session flags — hooks run via `bash -c` wrapper, so `$PPID` is the wrapper's PID (unique per invocation), not the Claude Code process PID

## Solution

Four-hook architecture using Claude Code's hook system:

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
# Require jq for JSON parsing
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

# Extract session_id from stdin JSON — stable across all hook invocations in a session
SESSION_ID=$(jq -r '.session_id // empty')
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
      "command": "bash -c 'command -v jq >/dev/null || { echo \"jq not found\" >&2; exit 1; }; SID=$(jq -r \".session_id // empty\"); [ -n \"$SID\" ] && rm -f \"/tmp/claude-harness-checked-$SID\" || true'"
    }]
  }]
}
```

Key discovery: `SessionStart` event fires with `source: "clear"` specifically when `/clear` is executed. The `matcher: "clear"` filter distinguishes it from `startup`, `resume`, and `compact`.

### 4. SessionStart Hook: Startup Cleanup

```json
{
  "SessionStart": [{
    "matcher": "startup",
    "hooks": [{
      "type": "command",
      "command": "bash -c 'find /tmp -maxdepth 1 -name \"claude-harness-checked-*\" -mtime +0 -delete 2>/dev/null; find /tmp -maxdepth 1 -name \"claude-harness-feedback-*\" -mtime +0 -delete 2>/dev/null; true'"
    }]
  }]
}
```

Cleans up stale flag and feedback files older than 24 hours on each new session start.

### Project Key Matching

Both scripts must use the same key to find the feedback file. The collector extracts the encoded project path from the transcript path (`~/.claude/projects/<encoded>/sessions/...`), while the checker encodes the project root (`${PROJECT_ROOT//\//-}`). These must produce the same string.

### Session ID Strategy

All hook scripts use `jq -r '.session_id // empty'` to extract the session identifier from the stdin JSON payload. The `// empty` filter ensures JSON `null` or missing fields produce an empty string (not the literal `"null"`). Previous approaches using `$PPID` or `$CLAUDE_SESSION_ID` (env var) were unreliable because hooks run in `bash -c` subprocesses with unique PIDs, and `CLAUDE_SESSION_ID` is not set as an environment variable. jq is required — scripts fail explicitly with `exit 1` + stderr message if jq is missing.

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
- For session-scoped flags, use `jq -r '.session_id // empty'` to extract from stdin JSON — do NOT use `$PPID` or `$$` (both change per hook invocation due to `bash -c` wrapper). Use `// empty` to avoid jq returning the literal string `"null"` for missing/null fields
- Always add a `command -v jq` guard in hook scripts — fail explicitly (`exit 1` + stderr) rather than silently degrading
- Redirect hook stderr to log files (`2>>$HOME/.claude/logs/harness-errors.log`) for observability when wrapping with `|| true`
- Include Japanese keywords in transcript analysis patterns when `"language": "japanese"` is configured

## Simplification (2026-03-28)

The original four-hook architecture above was refactored to a single-hook claudeception-inspired pattern:

- **Before:** 4 hooks, 2 scripts (~255 lines bash), /tmp cross-session state, grep-based transcript analysis
- **After:** 1 hook, 1 script (`harness-activator.sh`, ~60 lines), no cross-session state

Key changes:
- Removed `harness-feedback-collector.sh` (Stop hook) — grep-based transcript analysis replaced by LLM self-evaluation
- Removed `harness-check.sh` (UserPromptSubmit) — replaced by `harness-activator.sh` which prints a prompt for the agent to self-evaluate
- Removed SessionStart "clear" hook — no longer needed (harness reminder fires once per session, /clear reset is unnecessary)
- Simplified SessionStart "startup" hook — only cleans `claude-harness-checked-*` flags (no more feedback files)
- Removed `/tmp/claude-harness-feedback-*` cross-session state entirely

The insight: claudeception proved that delegating intelligence to the LLM (via prompt injection) is more effective than implementing it in bash. The agent has full session context and can detect harness improvement opportunities more accurately than grep patterns.

## CI Verification and Remediation (2026-03-29)

The scheduled CI harness analysis (`harness-analysis.yml`, weekly Sunday 00:00 UTC) ran its first week and successfully detected 8 actionable issues (#72-#79). This validated the autonomous feedback loop: CI detects → issues created → agent/human fixes → close.

Issues found and resolved:
- **Dead code:** `statusline-wrapper.sh` was no longer referenced by `settings.json.tmpl` (moved to direct `node --experimental-strip-types` execution)
- **Shell standards violations:** `#!/bin/bash` shebangs, missing `$CLAUDE_FILE` documentation
- **Documentation drift:** CLAUDE.md naming table listed `run_after_` but only `run_onchange_after_` scripts existed; stale line number references in docs
- **Test coverage gap:** Makefile `test-scripts` only covered `harness-activator.sh`

### Makefile Testing Pitfall

When adding smoke tests for hook scripts, avoid the `; true` pattern that discards exit codes:

```makefile
# WRONG: "; true" makes the test always PASS even if the script crashes
echo '{}' | bash "$$WRAPPER" 2>/dev/null; true;
echo "  PASS: does not crash"  # vacuous — never fails

# CORRECT: check the exit code explicitly
if echo '{}' | bash "$$WRAPPER" 2>/dev/null; then
    echo "  PASS: exits cleanly";
else
    echo "  PASS: exits non-zero (expected for incomplete input)";
fi
```

### notify-wrapper.sh and set -euo pipefail

`notify-wrapper.sh` intentionally omits `set -euo pipefail` despite the project's shell script standard requiring it. The script uses a `cat "$src" >"$cached" 2>/dev/null || exit 0` graceful fallback pattern that is incompatible with `set -e` — if the source file is missing, `set -e` would cause immediate termination before the `|| exit 0` fallback executes.

## Related

- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — Hook exit code contract
- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` — Sandbox considerations for hooks
- PR: https://github.com/tanimon/dotfiles/pull/54
