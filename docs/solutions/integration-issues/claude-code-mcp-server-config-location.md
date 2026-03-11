---
title: Claude Code MCP Server Settings Not Loading from ~/.claude/settings.json
date: 2026-03-06
category: integration-issues
tags: [chezmoi, claude-code, mcp, dotfiles, json-merge, configuration]
severity: medium
component: claude-code-configuration
root_cause: Claude Code reads user-scope MCP servers from ~/.claude.json (top-level mcpServers key), not from ~/.claude/settings.json
---

# Claude Code MCP Server Settings Not Loading from settings.json

## Problem Symptoms

- MCP servers defined in `~/.claude/settings.json` under `mcpServers` key were not appearing in `claude mcp list`
- Only servers registered via `claude mcp add -s user` (stored in `~/.claude.json`) were loaded
- No error messages indicated the settings.json config was being ignored

## Investigation Steps

1. **Checked `claude mcp list`**: Only `deepwiki` (previously added via CLI) appeared, despite 6 servers defined in `settings.json`
2. **Ran `claude mcp get <name>`**: `deepwiki` showed as "User config" scope. Other servers returned nothing
3. **Searched `~/.claude.json`** (the runtime state file): Found `mcpServers` at top-level with only `deepwiki`. Also found many `disabledMcpServers` entries in per-project configs
4. **Confirmed via `claude mcp add --help`**: Three scopes exist — `local`, `user`, `project` — and user-scope writes to `~/.claude.json`

## Root Cause

Claude Code maintains two separate configuration files with different purposes:

| File | Purpose | MCP Servers? |
|------|---------|-------------|
| `~/.claude/settings.json` | UI settings, permissions, hooks, plugins, sandbox | **Ignored** |
| `~/.claude.json` | Runtime state + user-scope MCP servers | **Read here** |
| `.mcp.json` (project root) | Project-scoped MCP servers | Read for project scope |

The `mcpServers` key in `~/.claude/settings.json` is silently ignored. There is no error or warning when it's present.

## Working Solution

Used chezmoi's `modify_` mechanism to partially manage `~/.claude.json`:

### File Structure

```
chezmoi source/
├── dot_claude/mcp-servers.json     # Source of truth for MCP server definitions
├── modify_dot_claude.json          # Merges mcpServers into ~/.claude.json
└── dot_claude/settings.json.tmpl   # mcpServers removed from here
```

### modify_dot_claude.json

```bash
#!/bin/bash
set -euo pipefail

MCP_SOURCE="${CHEZMOI_SOURCE_DIR}/dot_claude/mcp-servers.json"
CURRENT="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq not found, skipping MCP server merge" >&2
  printf '%s' "${CURRENT}"
  exit 0
fi

if [ ! -f "${MCP_SOURCE}" ] || ! jq empty "${MCP_SOURCE}" 2>/dev/null; then
  echo "WARNING: ${MCP_SOURCE} missing or invalid, skipping MCP server merge" >&2
  printf '%s' "${CURRENT}"
  exit 0
fi

printf '%s' "${CURRENT:-"{}"}" | jq --slurpfile servers "${MCP_SOURCE}" '.mcpServers = $servers[0]'
```

Key design decisions:
- **Full replacement** of `mcpServers` (source file is single source of truth)
- **Defensive error handling**: On any failure, pass through original content unchanged
- **`modify_` over `run_onchange_`**: chezmoi-native partial file management via stdin/stdout

### Verification

```bash
# After chezmoi apply:
claude mcp list                              # All servers should appear
jq '.mcpServers | keys' ~/.claude.json       # Verify server names
jq 'keys | length' ~/.claude.json            # Verify other keys preserved
```

## Prevention Strategies

### Diagnostic Commands

```bash
# Quick health check
claude mcp list

# Check specific server scope
claude mcp get <server-name>

# Compare configured vs loaded
diff <(jq -r '.mcpServers | keys[]' ~/.claude.json | sort) \
     <(claude mcp list 2>/dev/null | grep -v "^Checking" | awk -F: '{print $1}' | sort)
```

### Claude Code Config File Reference

| Setting | Correct File | Wrong File |
|---------|-------------|------------|
| MCP servers (user) | `~/.claude.json` | ~~`~/.claude/settings.json`~~ |
| Permissions | `~/.claude/settings.json` | — |
| Hooks | `~/.claude/settings.json` | — |
| Plugins | `~/.claude/settings.json` | — |
| MCP servers (project) | `.mcp.json` | — |

### Best Practices for chezmoi + Claude Code

1. Use `modify_` scripts for files with mixed managed/unmanaged keys
2. Never template `~/.claude.json` entirely (destroys runtime state)
3. Keep MCP server definitions in a separate JSON file for easy editing
4. Test with `chezmoi diff` before `chezmoi apply`

## Related Documentation

- Brainstorm: `docs/brainstorms/2026-03-06-chezmoi-mcp-servers-brainstorm.md`
- Plan: `docs/plans/2026-03-06-feat-chezmoi-mcp-server-management-plan.md`
- Related: `docs/solutions/security-issues/dotfiles-hardening-profile-management.md`
