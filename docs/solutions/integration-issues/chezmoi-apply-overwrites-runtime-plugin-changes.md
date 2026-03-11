---
title: "Fix chezmoi overwriting runtime plugin changes with modify_ scripts"
date: 2026-03-07
category: integration-issues
tags:
  - chezmoi
  - claude-code
  - plugins
  - modify-script
  - dotfiles
problem_summary: "chezmoi apply overwrites runtime plugin changes in ~/.claude/plugins/"
root_cause: "Plugin JSON files managed as regular templates are overwritten before run_after_ sync"
---

# chezmoi apply Overwrites Runtime Plugin Changes

## Problem

After installing a new Claude Code plugin, running `chezmoi apply` would **delete the newly installed plugin**. The `installed_plugins.json` and `known_marketplaces.json` files would revert to whatever was in the chezmoi source templates.

### Symptoms

- Newly installed Claude Code plugins disappear after `chezmoi apply`
- `installed_plugins.json` resets to the source template state
- `known_marketplaces.json` similarly reverts

### Root Cause

Plugin JSON files were managed as regular chezmoi templates (`.tmpl`), which unconditionally overwrite the target with the rendered source content. chezmoi's execution order is:

```
1. Compute source state (read all templates)
2. Apply source → target (overwrite target files)
3. Execute run_after_ scripts
```

The `run_after_sync-plugins.sh` script was designed to reverse-sync target → source for git tracking, but it ran at step 3 — **after** step 2 had already destroyed the runtime changes.

```
Broken flow:
1. User installs plugin → target updated
2. chezmoi apply → source template overwrites target (plugin lost!)
3. run_after_ → copies reverted target to source (too late)
```

## Solution

Convert plugin JSON files from regular templates to **`modify_` scripts**. The `modify_` pattern receives current target content on stdin and outputs the desired content on stdout, allowing preservation of runtime changes.

### Step 1: Rename template files to data files

```bash
git mv dot_claude/plugins/private_installed_plugins.json.tmpl \
       dot_claude/plugins/.installed_plugins.json.data
git mv dot_claude/plugins/known_marketplaces.json.tmpl \
       dot_claude/plugins/.known_marketplaces.json.data
```

The dot prefix ensures chezmoi ignores these files (they don't match any chezmoi naming convention). They serve as seed data for new machines only.

### Step 2: Create modify_ scripts

**`dot_claude/plugins/modify_private_installed_plugins.json.tmpl`:**

```bash
#!/bin/bash
set -e
DATA_FILE="{{ .chezmoi.sourceDir }}/dot_claude/plugins/.installed_plugins.json.data"
INPUT=$(cat)
if [ -n "$INPUT" ]; then
    printf '%s\n' "$INPUT"
else
    sed 's|{{ "{{ .chezmoi.homeDir }}" }}|{{ .chezmoi.homeDir }}|g' "$DATA_FILE"
fi
```

Same pattern for `modify_known_marketplaces.json.tmpl` (different `DATA_FILE` path).

### Step 3: Update run_after_ sync script

Update output paths from `.tmpl` to `.data` and extract a reusable function:

```bash
sync_plugin_file() {
  local name="$1"
  local src="${HOME_DIR}/.claude/plugins/${name}"
  local dest="${PLUGINS_SRC}/.${name}.data"
  if [ -f "$src" ]; then
    cp "$src" "$dest"
    sed -i '' "s|${HOME_DIR}|${TMPL_VAR}|g" "$dest"
  fi
}
sync_plugin_file "installed_plugins.json"
sync_plugin_file "known_marketplaces.json"
```

### How it works after the fix

```
Fixed flow:
1. User installs plugin → target updated
2. chezmoi apply → modify_ passes through stdin (target preserved)
3. run_after_ → syncs target to source .data file for git tracking
```

## Critical Gotchas

| Gotcha | Consequence | Fix |
|--------|------------|-----|
| `modify_` with OS guard (`{{ if eq .chezmoi.os "darwin" }}`) | Empty output on non-matching OS → target file **zeroed** | Remove OS guards from `modify_` scripts |
| Missing `set -e` | `sed` failure produces empty output → target **deleted** | Always include `set -e` |
| `printf '%s'` without `\n` | `$(cat)` strips trailing newlines → perpetual `chezmoi diff` | Use `printf '%s\n'` to compensate |
| Missing `.data` file | `sed` fails → empty output → target deleted | Guard with `[ -f "$DATA_FILE" ]` or rely on `set -e` |

## Decision Tree: When to Use Each chezmoi Pattern

```
Does chezmoi need to manage this file?
├─ NO → .chezmoiignore
└─ YES
   ↓
   Does any external tool modify this file at runtime?
   ├─ NO → Regular template (.tmpl)
   └─ YES
      ↓
      Should chezmoi only provision it once, then hands off?
      ├─ YES → create_ prefix
      └─ NO (need ongoing sync or partial ownership)
         ↓
         modify_ script
```

| Strategy | Owns entire file? | Runs every apply? | Preserves external changes? |
|----------|-------------------|-------------------|----------------------------|
| Regular template | Yes | Yes (overwrites) | **No** |
| `create_` | Yes (first time) | Only if missing | Yes (after creation) |
| `modify_` | Partial/full | Yes (merges) | Yes |
| `.chezmoiignore` | No | N/A | Yes |

## Testing Checklist for modify_ Scripts

- [ ] Test with existing target: `chezmoi apply --dry-run -v` shows no diff for unchanged files
- [ ] Test with missing target: delete target, apply, verify file is seeded correctly
- [ ] Test idempotency: two consecutive `chezmoi apply` produce identical results
- [ ] Verify `chezmoi diff` is clean after second apply (no perpetual diffs)
- [ ] Confirm `chezmoi managed` still lists the files

## Rule of Thumb

> **If you did not write every byte of the file, do not use a regular template.** Use `modify_` to own your keys and leave everything else alone.

## Related

- [`modify_dot_claude.json`](/modify_dot_claude.json) — Same pattern for partial JSON management (MCP servers via `jq`)
- [`docs/solutions/integration-issues/claude-code-mcp-server-config-location.md`](/docs/solutions/integration-issues/claude-code-mcp-server-config-location.md) — MCP server config discovery
- [PR #8](https://github.com/tanimon/dotfiles/pull/8) — Implementation PR
- [CLAUDE.md Key Patterns](/CLAUDE.md) — Project-level documentation of chezmoi patterns
