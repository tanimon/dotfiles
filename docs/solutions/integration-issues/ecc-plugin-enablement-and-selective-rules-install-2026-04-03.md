---
title: ECC Plugin Enablement and Selective Rules Installation via chezmoi
date: 2026-04-03
category: integration-issues
module: chezmoi / Claude Code plugins
problem_type: integration_issue
component: tooling
symptoms:
  - "claude plugin list shows everything-claude-code as disabled despite marketplace registration and plugin installation"
  - "ECC install.sh installs ALL rules via module system, no selective category support"
  - "User rules overlap with ECC rules causing maintenance duplication"
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - chezmoi
  - claude-code-plugins
  - everything-claude-code
  - declarative-sync
  - enabledplugins
  - rules-management
---

# ECC Plugin Enablement and Selective Rules Installation via chezmoi

## Problem

The everything-claude-code (ECC) plugin was marketplace-registered and installed but not active — `claude plugin list` showed it as disabled. Additionally, integrating ECC's rules selectively (only specific categories like common, golang, typescript, web) was not supported by ECC's own install.sh, which operates at module level (all rules at once).

## Symptoms

- `claude plugin list` showed `everything-claude-code@everything-claude-code` with `Status: ✘ disabled`
- `known_marketplaces.json` contained the ECC entry, and `~/.claude/plugins/marketplaces/everything-claude-code/` directory existed
- `installed_plugins.json` had `everything-claude-code@everything-claude-code` entry
- User-maintained rules in `dot_claude/rules/` duplicated most of ECC's rules with less coverage
- Running ECC's `install.sh` would install rules for ALL languages (python, java, rust, etc.), not just the desired subset

## What Didn't Work

- **ECC's install.sh**: Uses a module manifest system (`manifests/install-modules.json`) where `rules-core` module has `paths: ["rules"]` — copies the entire `rules/` directory. No flag exists for selecting specific language categories.
- **install.sh with language arguments** (e.g., `install.sh typescript golang`): This controls which *additional modules* (like `framework-language` for skills) are installed, but `rules-core` always installs ALL rules.

## Solution

Two-part fix:

### 1. Enable the plugin via enabledPlugins

In `dot_claude/settings.json.tmpl`, the `enabledPlugins` section explicitly controls plugin state. Changed:

```json
"everything-claude-code@everything-claude-code": false
```
to:
```json
"everything-claude-code@everything-claude-code": true
```

### 2. Declarative selective rule installation

Created a declarative sync pattern (matching the existing marketplace and gh-extension patterns) for selective ECC rule installation:

**`dot_claude/ecc-rules-languages.txt`** — text list of rule categories:
```
common
golang
typescript
web
```

**`.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl`** — copies specific rule directories from the ECC marketplace:
```bash
# ecc-rules-languages hash: {{ include "dot_claude/ecc-rules-languages.txt" | sha256sum }}

ECC_MARKETPLACE_DIR="{{ .chezmoi.homeDir }}/.claude/plugins/marketplaces/everything-claude-code"
RULES_SRC="$ECC_MARKETPLACE_DIR/rules"
RULES_DST="{{ .chezmoi.homeDir }}/.claude/rules"

while IFS= read -r lang || [ -n "$lang" ]; do
  [[ -z "$lang" || "$lang" == \#* ]] && continue
  mkdir -p "$RULES_DST/$lang"
  cp -r "$RULES_SRC/$lang/"* "$RULES_DST/$lang/"
done < "{{ .chezmoi.sourceDir }}/dot_claude/ecc-rules-languages.txt"
```

### 3. Remove overlapping user rules

Deleted 10 user-maintained rule files that ECC provides equivalents for. Kept 3 user-specific files that ECC does not offer:
- `common/documentation-language.md`
- `common/github-actions.md`
- `common/harness-engineering.md`

## Why This Works

### Three-layer plugin lifecycle

Claude Code plugins have a three-layer lifecycle, each managed differently by chezmoi:

| Layer | What | chezmoi management |
|-------|------|-------------------|
| Marketplace registration | `known_marketplaces.json` + marketplace directory | `marketplaces.txt` + `run_onchange_` + `extraKnownMarketplaces` in settings |
| Plugin installation | `installed_plugins.json` + cache | NOT managed (`.chezmoiignore`) — runtime state |
| Plugin enablement | `enabledPlugins` in `settings.json` | `settings.json.tmpl` — fully owned by chezmoi |

A plugin can be registered and installed but still **disabled** if `enabledPlugins` has it set to `false`.

### Selective installation via direct copy

ECC's `install.sh` is designed for fresh setups (install everything). For a chezmoi-managed dotfiles repo that already has curated rules, direct `cp -r` from the marketplace directory gives finer control:
- Install only desired categories (common, golang, typescript, web)
- Skip unwanted categories (python, java, rust, php, etc.)
- Hash tracking triggers re-copy when languages change or ECC updates

### Coexistence model

chezmoi and the `run_onchange_` script write to the same `~/.claude/rules/` directory but manage different files. chezmoi only manages files present in `dot_claude/rules/` — it does not delete ECC-installed files that aren't in the source tree.

## Prevention

- **Document the three-layer lifecycle**: When troubleshooting "plugin not working," check all three layers (marketplace → install → enable), not just one.
- **Use the declarative sync pattern for selective installation**: When a tool's installer is too coarse-grained, bypass it with a targeted `run_onchange_` script that copies specific content from the tool's managed directory.
- **Separate user-specific from vendor-provided rules**: Keep user-specific rules that vendors don't provide (harness-engineering, github-actions) in chezmoi management. Let vendor rules be installed separately so they can update independently.

## Related Issues

- `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md` — establishes the declarative sync pattern used here
- `docs/solutions/integration-issues/chezmoi-apply-overwrites-runtime-plugin-changes.md` — documents why runtime-mutable files must not use regular templates
- Memory: `claude_code_plugin_lifecycle.md` — auto memory recording of the three-layer discovery (auto memory [claude])
