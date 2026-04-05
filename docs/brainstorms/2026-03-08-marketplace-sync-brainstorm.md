# Brainstorm: Declarative Marketplace Sync via chezmoi

**Date:** 2026-03-08
**Status:** Completed

## What We're Building

Replace the current 3-layer marketplace sync system (`modify_` + `.data` files + `run_after_` reverse sync) with a simple declarative approach:

1. A plain text file listing marketplace sources (one per line)
2. A `run_onchange_` script that reads the list and runs `claude plugin marketplace add` for each entry

Additionally, remove `installed_plugins.json` and `known_marketplaces.json` from chezmoi management entirely (add to `.chezmoiignore`), since plugin install/enable state does not need to sync.

## Why This Approach

The current system manages `known_marketplaces.json` bidirectionally — chezmoi applies it, then a `run_after_` script reverse-syncs runtime changes back to `.data` files with template substitution. This creates:

- 3 layers of indirection (`.data` shadow files, `modify_` scripts, `run_after_` reverse sync)
- Template escaping complexity (`{{ "{{ .chezmoi.homeDir }}" }}`)
- Additive-only merge (marketplace deletions don't propagate)
- JSON merge conflicts across machines

The new approach is **unidirectional and declarative**: the source list is the single source of truth, and `claude plugin marketplace add` is idempotent (adding an already-registered marketplace is a no-op).

### Why not chezmoi built-in features?

- `chezmoi merge` / `merge-all` — interactive only, designed for conflict resolution, not automated sync
- `chezmoi re-add` — cannot run inside `run_after_` (DB lock), skips templates
- No `merge_` or `sync_` source state attribute exists (proposed and declined by maintainer)
- The current `modify_` + `.data` + `run_after_` pattern is actually chezmoi's idiomatic solution for bidirectional sync — but we can avoid needing bidirectional sync entirely

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| List format | Plain text (1 line per source) | Simple, clean git diffs, easy to edit |
| Source identifier | `owner/repo` for GitHub, full URL for git | Matches `claude plugin marketplace add` argument format |
| Sync direction | Source -> target only (add) | `marketplace add` is idempotent; no reverse sync needed |
| Deletion sync | Not needed | User confirmed add-only is sufficient |
| `installed_plugins.json` | Remove from chezmoi, add to `.chezmoiignore` | Plugin install/enable state not synced |
| `known_marketplaces.json` | Remove from chezmoi, add to `.chezmoiignore` | Replaced by declarative list + CLI approach |
| Duplicate handling | Keep GitHub form only | `every-marketplace` (git URL) removed in favor of `EveryInc/compound-engineering-plugin` (GitHub) |

## Implementation Overview

### New files

- `dot_claude/plugins/marketplaces.txt` — declarative marketplace list
- `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` — reads list, runs `claude plugin marketplace add` for each entry; hash comment tracks `marketplaces.txt` changes

### Files to remove

- `dot_claude/plugins/modify_known_marketplaces.json.tmpl`
- `dot_claude/plugins/.known_marketplaces.json.data`
- `dot_claude/plugins/modify_private_installed_plugins.json.tmpl`
- `dot_claude/plugins/.installed_plugins.json.data`
- Marketplace-related lines in `run_after_20-sync-plugins.sh.tmpl` (or entire file if only marketplace sync remains)

### Files to modify

- `.chezmoiignore` — add `known_marketplaces.json` and `installed_plugins.json`
- `CLAUDE.md` — update architecture documentation

### Marketplace list content (as of 2026-03-08)

```
anthropics/skills
anthropics/claude-plugins-official
jarrodwatts/claude-delegator
OthmanAdi/planning-with-files
affaan-m/everything-claude-code
EveryInc/compound-engineering-plugin
```

> Note: The current list in `dot_claude/plugins/marketplaces.txt` may include additional entries added after this brainstorm.

## Open Questions

None — all questions resolved during brainstorming.
