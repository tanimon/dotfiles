---
title: "chore: sync ~/.claude/settings.json into source and drop deprecated everything-claude-code plugin entry"
type: chore
status: active
date: 2026-04-08
---

# chore: sync ~/.claude/settings.json into source and drop deprecated everything-claude-code plugin entry

## Overview

The deployed target `~/.claude/settings.json` has drifted from its chezmoi source `dot_claude/settings.json.tmpl`. A new plugin enable entry (`ecc@everything-claude-code`) was added at runtime via `claude plugin enable` and never reflected back to the source. At the same time, the legacy `everything-claude-code@everything-claude-code` plugin slug is deprecated (replaced by `ecc@everything-claude-code` from the same marketplace) and must be removed from both source and target.

The active "Edit Source Files, Not Deployed Targets" instinct still applies — we are not editing the target by hand. We update the source so the next `chezmoi apply` produces the correct target.

## Problem Frame

- `~/.claude/settings.json` line 238: contains `"ecc@everything-claude-code": true` (new — not in source)
- `dot_claude/settings.json.tmpl` line 233: still contains `"everything-claude-code@everything-claude-code": true,` (deprecated)
- The shared marketplace `everything-claude-code` (lines 248–254) is still required because the new `ecc@everything-claude-code` plugin lives in the same marketplace. Marketplace registration must NOT be removed.

## Requirements Trace

- R1. Source file `dot_claude/settings.json.tmpl` reflects the runtime plugin enablement state of the target file (specifically: include the `ecc@everything-claude-code` entry).
- R2. Deprecated plugin slug `everything-claude-code@everything-claude-code` is removed from both source and target.
- R3. All chezmoi template variables (`{{ .chezmoi.homeDir }}`, `{{ .ghOrg }}`, `_ZO_DOCTOR` comment block) in the source file are preserved verbatim — do not clobber them with hardcoded paths from the target.
- R4. The `everything-claude-code` marketplace entry under `extraKnownMarketplaces` is preserved (still used by `ecc@everything-claude-code`).
- R5. After applying, JSON remains valid (trailing commas correct, last key has no trailing comma).
- R6. `make lint` passes locally.

## Scope Boundaries

- Non-goal: rewriting any other section of `settings.json.tmpl`.
- Non-goal: removing the `everything-claude-code` marketplace registration.
- Non-goal: editing other Claude config files.

## Context & Research

### Relevant Code and Patterns

- `dot_claude/settings.json.tmpl` — fully chezmoi-managed (`.tmpl`, not `modify_`). `chezmoi apply` will overwrite the target with whatever the source produces, so editing only the source is sufficient.
- `CLAUDE.md` "Choosing chezmoi file patterns" — confirms regular `.tmpl` for fully-owned files.

### Institutional Learnings

- Active instinct: "Edit Source Files, Not Deployed Targets" — never hand-edit `~/.claude/settings.json`. Edit `dot_claude/settings.json.tmpl` then `chezmoi apply`.
- Active instinct: "Run make lint After Source Tree Edits" — required after any source edit.

## Key Technical Decisions

- Edit the source file with surgical `Edit` calls rather than `Write`, to avoid accidentally rewriting template variables or JSON structure.
- Place the new `"ecc@everything-claude-code": true` entry as the new last key in `enabledPlugins`, matching the target file's ordering. Adjust the previous last entry to add a trailing comma.
- Run `chezmoi apply` to deploy and confirm target/source convergence by `chezmoi diff` returning empty.

## Implementation Units

- [ ] **Unit 1: Update source settings.json.tmpl**

**Goal:** Remove the deprecated `everything-claude-code@everything-claude-code` enable entry and add the new `ecc@everything-claude-code` enable entry.

**Requirements:** R1, R2, R3, R4, R5

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- Delete line `"everything-claude-code@everything-claude-code": true,` inside `enabledPlugins`.
- Add a trailing comma to the existing last entry `"claude-md-management@claude-plugins-official": true`.
- Append `"ecc@everything-claude-code": true` as the new last entry.
- Leave `extraKnownMarketplaces.everything-claude-code` block intact.

**Verification:**
- `grep -n "everything-claude-code@everything-claude-code" dot_claude/settings.json.tmpl` returns nothing.
- `grep -n "ecc@everything-claude-code" dot_claude/settings.json.tmpl` returns one match.
- `chezmoi execute-template` (or `chezmoi diff`) shows no JSON parse error.

- [ ] **Unit 2: Apply and verify convergence**

**Goal:** Deploy the source change to the target and confirm both files agree.

**Requirements:** R2, R5

**Files:**
- Modify: `~/.claude/settings.json` (indirectly, via `chezmoi apply`)

**Approach:**
- Run `chezmoi diff` to preview.
- Run `chezmoi apply`.
- Confirm `chezmoi diff` is empty afterward.
- Confirm deprecated entry is gone from target.

**Verification:**
- `chezmoi diff` produces no output.
- `grep "everything-claude-code@everything-claude-code" ~/.claude/settings.json` returns nothing.
- `grep "ecc@everything-claude-code" ~/.claude/settings.json` returns one match.

- [ ] **Unit 3: Lint and snapshot instincts**

**Goal:** Satisfy repo CI gates before commit.

**Requirements:** R6

**Files:**
- None modified.

**Approach:**
- Run `make lint`.
- Run `scripts/snapshot-instincts.sh` so the auto-promote workflow has fresh data.

**Verification:**
- `make lint` exits 0.
- Snapshot script exits 0.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Accidentally clobber template variables in source | Use surgical `Edit` calls scoped to the two affected lines, never `Write` the whole file. |
| Removing the marketplace breaks `ecc@everything-claude-code` plugin loading | Explicitly leave `extraKnownMarketplaces.everything-claude-code` intact. |
| Trailing comma error producing invalid JSON | Verify JSON validity after edit via `chezmoi execute-template` and `make lint`. |

## Sources & References

- Source: `dot_claude/settings.json.tmpl`
- Target: `~/.claude/settings.json`
- Project rule: `CLAUDE.md` (chezmoi file pattern guidance)
