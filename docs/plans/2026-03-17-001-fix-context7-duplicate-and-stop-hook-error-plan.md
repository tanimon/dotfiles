---
title: Fix context7 MCP duplicate warning and Stop hook error
type: fix
status: completed
date: 2026-03-17
---

# Fix context7 MCP duplicate warning and Stop hook error

Two configuration issues producing warnings/errors on every Claude Code session.

## Enhancement Summary

**Deepened on:** 2026-03-17
**Sections enhanced:** 3 (Proposed Solution, Edge Cases, Verification)
**Research:** repo-research-analyst, learnings-researcher, spec-flow-analyzer, plugin source inspection

### Key Improvements
1. Confirmed plugin registers under exact name `context7` with same URL — safe to remove
2. Identified plugin version includes optional `x-api-key` header (minor improvement)
3. Verified `mcp__context7` permission in `settings.json.tmpl:67` remains valid after change
4. Identified catch block stderr issue as a second bug in the same script
5. Confirmed `deepwiki` and other servers are NOT duplicated by any plugin

## Problem Statement

### Issue 1: context7 MCP server duplicate warning

```
MCP server 'context7' skipped — same command/URL as already-configured 'context7'
Remove 'context7' from your MCP config if you want the plugin's version instead
```

**Root cause:** `dot_claude/mcp-servers.json` defines a `context7` entry (`type: http`, `url: https://mcp.context7.com/mcp`). The compound-engineering plugin (enabled in `settings.json.tmpl` line 205) also provides an identical `context7` MCP server via both `plugin.json` and `.mcp.json`. Claude Code deduplicates by name/URL and emits a warning.

**Three sources define context7:**
1. `dot_claude/mcp-servers.json` → merged into `~/.claude.json` by `modify_dot_claude.json`
2. `plugin.json` in compound-engineering 2.40.0 → `{ "type": "http", "url": "https://mcp.context7.com/mcp" }`
3. `.mcp.json` in compound-engineering 2.40.0 → same URL, plus optional `x-api-key` header

### Issue 2: Stop hook error

```
Stop hook error: Failed with non-blocking status code: No stderr output
```

**Root cause:** `dot_claude/scripts/executable_notify.mjs` line 25 calls `process.exit(1)` without writing to stderr when `transcript_path` is outside `~/.claude/projects/`. This is an intentional skip, not an error — but exit code 1 signals failure to Claude Code. Additionally, the catch block (lines 73-75) uses `console.log` (stdout) instead of `console.error` (stderr), so genuine errors also produce the "No stderr output" message.

## Proposed Solution

### Fix 1: Remove context7 from `dot_claude/mcp-servers.json`

Remove the `"context7"` entry from `dot_claude/mcp-servers.json`. The compound-engineering plugin provides the same server (with the bonus of an optional `x-api-key` header for rate limiting).

**File:** `dot_claude/mcp-servers.json`

```json
{
  "notion": {
    "command": "npx",
    "args": ["-y", "mcp-remote", "https://mcp.notion.com/sse"]
  },
  "codex": {
    "type": "stdio",
    "command": "codex",
    "args": ["-m", "gpt-5.2-codex", "mcp-server"]
  },
  "newrelic": {
    "type": "http",
    "url": "https://mcp.newrelic.com/mcp/"
  },
  "figma": {
    "type": "http",
    "url": "https://mcp.figma.com/mcp"
  },
  "deepwiki": {
    "type": "http",
    "url": "https://mcp.deepwiki.com/mcp"
  }
}
```

### Research Insights (Fix 1)

**Verified safe:**
- Plugin `plugin.json` registers exactly `"context7"` with `"url": "https://mcp.context7.com/mcp"` — same name and URL
- `mcp__context7` permission at `settings.json.tmpl:67` remains valid (tool name derived from server name, not source)
- No other servers in `mcp-servers.json` are duplicated by any plugin (checked `deepwiki`, `notion`, `codex`, `newrelic`, `figma`)

**Bootstrap risk (low):**
On a fresh machine, context7 won't be available until the compound-engineering plugin is installed. The marketplace sync (`run_onchange_after_add-marketplaces.sh.tmpl`) registers the marketplace during `chezmoi apply`, but plugin installation requires launching Claude Code. This is acceptable — context7 is not critical for bootstrapping.

**Aligns with documented pattern:** Per `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md`, plugin capabilities should come from plugins, not be duplicated in user config.

### Fix 2: Fix exit codes and stderr in `executable_notify.mjs`

Two changes:

1. **Line 25:** Change `process.exit(1)` to `process.exit(0)` — outside-directory is an intentional skip, not an error
2. **Lines 73-75:** Change `console.log` to `console.error` — genuine errors should go to stderr so Claude Code can display them

**File:** `dot_claude/scripts/executable_notify.mjs`

```javascript
// Line 24-25: Change from error exit to silent skip
if (!resolvedPath.startsWith(allowedBase)) {
  process.exit(0);
}

// Lines 73-75: Change console.log to console.error
} catch (error) {
  console.error("Hook execution failed:", error.message);
  process.exit(1);
}
```

### Research Insights (Fix 2)

**Exit code semantics:**
- `exit(0)` = success/skip — Claude Code ignores silently
- `exit(1)` with stderr = error — Claude Code displays stderr message
- `exit(1)` without stderr = current broken state — Claude Code shows generic "No stderr output" error

**Shared script concern:** The same `notify.mjs` is used for both `Stop` (line 169) and `Notification` (line 147) hooks in `settings.json.tmpl`. Both hooks receive `transcript_path` in the same format. The fix applies correctly to both hook types.

**Security note:** Changing exit(1) to exit(0) for paths outside `~/.claude/projects/` means path traversal attempts are silently ignored rather than flagged. This is acceptable — this is a personal notification hook, not a security boundary. The `path.resolve()` + `startsWith()` check still prevents actual path traversal; the exit code only affects the error message.

## Edge Cases

| Scenario | Expected Behavior |
|---|---|
| compound-engineering plugin disabled | context7 not available (acceptable) |
| Plugin not yet installed (fresh machine) | context7 not available until plugin installed |
| transcript_path outside `~/.claude/projects/` | Silent skip (exit 0), no error shown |
| transcript_path is null/undefined | Silent skip (exit 0 at line 11, unchanged) |
| Malformed JSON on stdin | catch block fires, stderr message shown, exit 1 |
| Transcript file doesn't exist | "file does not exist" logged, exit 0 (unchanged) |
| Empty transcript file | "file is empty" logged, exit 0 (unchanged) |

## Acceptance Criteria

- [x] `chezmoi apply` succeeds without context7 duplicate warning
- [x] Stop hook runs without "Failed with non-blocking status code" error
- [x] context7 MCP server still available via compound-engineering plugin
- [x] Notifications still work for valid transcript paths under `~/.claude/projects/`
- [x] Genuine errors in notify.mjs produce visible stderr output
- [x] `mcp__context7` permission in settings.json.tmpl still functions correctly

## Verification

```bash
# After chezmoi apply:
chezmoi apply --dry-run          # Preview changes
chezmoi apply                    # Apply

# Verify context7 removal
jq '.mcpServers | keys' ~/.claude.json  # context7 should be absent

# Verify plugin provides context7 (launch Claude Code, then):
claude mcp list                  # context7 should appear from plugin

# Verify hook fix (trigger a Stop):
# No "Stop hook error" should appear in session
```

## Sources

- `dot_claude/mcp-servers.json` — MCP server definitions (source of truth for user-scope servers)
- `dot_claude/scripts/executable_notify.mjs` — Stop/Notification hook script
- `dot_claude/settings.json.tmpl:67` — `mcp__context7` permission
- `dot_claude/settings.json.tmpl:205` — compound-engineering plugin enabled
- `~/.claude/plugins/cache/compound-engineering-plugin/compound-engineering/2.40.0/.claude-plugin/plugin.json` — plugin MCP server definition
- `~/.claude/plugins/cache/compound-engineering-plugin/compound-engineering/2.40.0/.mcp.json` — plugin MCP server with headers
- `docs/solutions/integration-issues/claude-code-mcp-server-config-location.md` — past learning on MCP config location
- `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md` — declarative sync pattern
