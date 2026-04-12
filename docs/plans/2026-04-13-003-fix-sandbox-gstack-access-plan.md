---
title: "fix: Allow sandbox access to ~/.gstack/ directory"
type: fix
status: active
date: 2026-04-13
---

# fix: Allow sandbox access to ~/.gstack/ directory

## Overview

Add `~/.gstack/` to the sandbox allow lists (safehouse and cco) so Claude Code can access gstack's runtime state directory from within the macOS Seatbelt sandbox.

## Problem Frame

Claude Code runs inside a deny-all macOS Seatbelt sandbox via safehouse (with cco as fallback). The gstack skill collection was recently added to this dotfiles repo, but its runtime state directory (`~/.gstack/`) was not added to the sandbox allow lists. This means Claude Code cannot read or write gstack's browser data, caches, or runtime artifacts, causing gstack skills (e.g., `/browse`) to fail with permission errors.

## Requirements Trace

- R1. Claude Code must be able to read and write `~/.gstack/` when running inside the safehouse sandbox
- R2. Claude Code must be able to read and write `~/.gstack/` when running inside the cco fallback sandbox
- R3. Follow existing patterns for adding working directories to both configs

## Scope Boundaries

- Only adding path entries — no changes to sandbox modules, wrappers, or architecture
- No changes to `.chezmoiignore` (already excludes `.gstack` for chezmoi management)

## Context & Research

### Relevant Code and Patterns

- `dot_config/safehouse/config.tmpl` — Primary sandbox config. Working directories use `--add-dirs=` (read-write). Example: `--add-dirs={{ .chezmoi.homeDir }}/.codex` (line 34)
- `dot_config/cco/allow-paths.tmpl` — Fallback sandbox config. Read-write paths have no `:ro` suffix. Example: `{{ .chezmoi.homeDir }}/.codex` (line 30)
- Both configs use `{{ .chezmoi.homeDir }}` template variable for home directory

### Institutional Learnings

- `docs/solutions/integration-issues/migrate-cco-to-agent-safehouse.md` — safehouse is primary, cco is fallback; both must be updated in lockstep
- `docs/solutions/runtime-errors/cco-sandbox-codex-mcp-eperm.md` — Same class of bug: missing allow entry for a runtime state directory (`.codex`). Fix pattern: add to both configs with read-write access

## Key Technical Decisions

- **Read-write access (not read-only)**: gstack writes browser state, caches, and session data to `~/.gstack/` at runtime. Read-only would break functionality. This matches the `.codex` and `.cache` entries.
- **Both configs updated**: Safehouse is primary on macOS, but cco is the fallback. Both must be kept in sync per established practice.

## Open Questions

### Resolved During Planning

- **Where to place the entry in safehouse config?** Under "Working directories (read-write)" section alongside `.codex` and `.cache` — gstack runtime state is the same category.
- **Where to place the entry in cco config?** After the `.codex` entry with a comment explaining gstack runtime state.

## Implementation Units

- [x] **Unit 1: Add ~/.gstack/ to safehouse config**

**Goal:** Allow read-write access to `~/.gstack/` in the primary sandbox.

**Requirements:** R1, R3

**Dependencies:** None

**Files:**
- Modify: `dot_config/safehouse/config.tmpl`

**Approach:**
- Add `--add-dirs={{ .chezmoi.homeDir }}/.gstack` to the "Working directories (read-write)" section, after the `.codex` entry

**Patterns to follow:**
- Line 34: `--add-dirs={{ .chezmoi.homeDir }}/.codex` — same pattern for a tool's runtime state directory

**Test scenarios:**
- Happy path: `chezmoi execute-template` renders the config with the new entry containing the correct home directory path
- Edge case: verify the entry does not duplicate any existing line

**Verification:**
- The rendered config includes `--add-dirs=<homeDir>/.gstack`
- `chezmoi apply --dry-run` shows the expected diff

- [x] **Unit 2: Add ~/.gstack/ to cco allow-paths**

**Goal:** Allow read-write access to `~/.gstack/` in the fallback sandbox.

**Requirements:** R2, R3

**Dependencies:** None

**Files:**
- Modify: `dot_config/cco/allow-paths.tmpl`

**Approach:**
- Add `{{ .chezmoi.homeDir }}/.gstack` (no `:ro` suffix = read-write) after the `.codex` entry, with a comment explaining gstack runtime state

**Patterns to follow:**
- Lines 29-30: `.codex` entry with comment — same pattern for a tool's runtime state directory

**Test scenarios:**
- Happy path: `chezmoi execute-template` renders the allow-paths with the new entry
- Edge case: verify no `:ro` suffix is present (must be read-write)

**Verification:**
- The rendered allow-paths includes `<homeDir>/.gstack` without `:ro`
- `chezmoi apply --dry-run` shows the expected diff

## System-Wide Impact

- **Interaction graph:** No callbacks or middleware affected — purely declarative config entries
- **Error propagation:** If the entries are malformed, safehouse/cco will fail to launch (loud failure, easy to diagnose)
- **State lifecycle risks:** None — adding allow entries is additive and safe
- **API surface parity:** Both sandbox configs (safehouse + cco) must stay in sync
- **Unchanged invariants:** All existing sandbox entries remain unchanged

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Typo in template variable breaks rendering | Follow exact pattern of adjacent entries; verify with `chezmoi apply --dry-run` |

## Sources & References

- Related code: `dot_config/safehouse/config.tmpl`, `dot_config/cco/allow-paths.tmpl`
- Related PR: #162 (gstack introduction), #163 (bun via mise)
- Learnings: `docs/solutions/runtime-errors/cco-sandbox-codex-mcp-eperm.md`
