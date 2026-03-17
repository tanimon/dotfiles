---
title: Claude Code Hook Exit Codes and stderr Semantics
date: 2026-03-17
category: integration-issues
tags:
  - claude-code
  - hooks
  - exit-codes
  - stderr
  - notify
severity: medium
component: Claude Code Hooks
symptom: "Stop hook error: Failed with non-blocking status code: No stderr output"
root_cause: Hook script exits with code 1 without writing to stderr; Claude Code expects either exit 0 or exit 1 with stderr message
---

# Claude Code Hook Exit Codes and stderr Semantics

## Problem Symptom

Every Claude Code session displays:

```
Stop hook error: Failed with non-blocking status code: No stderr output
```

The Stop hook (`notify.mjs`) appeared to fail, but notifications were actually working for valid transcripts. The error was noise from a legitimate "skip" path being treated as failure.

## Investigation Steps

1. **Read the hook script** (`dot_claude/scripts/executable_notify.mjs`): Found that when `transcript_path` resolves outside `~/.claude/projects/`, the script calls `process.exit(1)` with no output — neither stdout nor stderr.

2. **Checked Claude Code hook protocol**: Claude Code interprets hook exit codes as:
   - `exit(0)` = success or intentional skip — no error shown
   - `exit(1)` with stderr = error — Claude Code displays the stderr message
   - `exit(1)` without stderr = broken state — Claude Code shows generic "Failed with non-blocking status code: No stderr output"

3. **Found a second issue**: The catch block used `console.log` (stdout) for error messages instead of `console.error` (stderr), so even genuine errors produced the same "No stderr output" message.

## Root Cause

Two bugs in `executable_notify.mjs`:

1. **Line 25**: `process.exit(1)` for paths outside the allowed directory. This is an intentional skip (not an error), but exit code 1 signals failure to Claude Code.

2. **Lines 73-75**: `console.log("Hook execution failed:", ...)` writes to stdout, not stderr. Claude Code reads stderr for error messages, so genuine errors were invisible.

## Working Solution

```javascript
// Line 24-26: Intentional skip — use exit(0), log to stderr for observability
if (!resolvedPath.startsWith(allowedBase)) {
  console.error("notify: transcript path outside allowed directory, skipping");
  process.exit(0);
}

// Catch block: Genuine errors — use console.error (stderr) with exit(1)
} catch (error) {
  console.error("Hook execution failed:", error.message);
  process.exit(1);
}
```

## Prevention Strategies

### Claude Code hook exit code contract

| Scenario | Exit code | Output | Claude Code behavior |
|----------|-----------|--------|---------------------|
| Success / intentional skip | 0 | Optional (ignored) | Silent |
| Error with explanation | 1 | stderr message | Displays stderr |
| Error without explanation | 1 | Nothing | "No stderr output" error |

### Rules for writing Claude Code hooks

1. **Use `exit(0)` for intentional skips** — "nothing to do" is not an error
2. **Always write to stderr before `exit(1)`** — Claude Code expects an explanation
3. **Never use `console.log` for error messages in hooks** — use `console.error` (stderr)
4. **Add diagnostic logs for skip paths** — helps debug "why didn't my hook fire?"

### Same script, multiple hooks

The `notify.mjs` script is used for both `Stop` and `Notification` hooks. Both hooks pass the same input format (`transcript_path`). When fixing hook scripts, verify behavior for all hook types that use the script.

## Related

- Settings template: `dot_claude/settings.json.tmpl` (Stop hook at line 169, Notification hook at line 147)
- MCP config learning: `docs/solutions/integration-issues/claude-code-mcp-server-config-location.md`
- PR: https://github.com/tanimon/dotfiles/pull/17
