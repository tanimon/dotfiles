---
title: "chore: Bring unmanaged Claude Code skills under chezmoi management"
type: chore
status: completed
date: 2026-04-05
---

# chore: Bring unmanaged Claude Code skills under chezmoi management

## Overview

The `ecc-observer-diagnosis` skill exists only at `~/.claude/skills/ecc-observer-diagnosis/SKILL.md` — it is deployed but not tracked by chezmoi. This means it will be lost on a new machine and is not version-controlled. Add it to the chezmoi source tree so it deploys consistently.

## Problem Frame

Skills in `~/.claude/skills/` come from four sources:

| Source | Example | Managed? |
|--------|---------|----------|
| Source tree (`dot_claude/skills/`) | `propose-harness-improvement`, `execplan`, etc. | Yes |
| `.chezmoiexternal.toml` | `claudeception` | Yes (SHA-pinned) |
| Plugin symlinks (`.agents/skills/`) | `find-skills`, `gemini-api-dev`, etc. | No (excluded in `.chezmoiignore`) |
| Runtime learned | `learned/` | No (excluded in `.chezmoiignore`) |

`ecc-observer-diagnosis` doesn't fit any managed category — it was created manually and currently sits untracked in the deploy target.

## Requirements Trace

- R1. `ecc-observer-diagnosis` skill must deploy to `~/.claude/skills/ecc-observer-diagnosis/SKILL.md` via `chezmoi apply`
- R2. The skill content must be version-controlled in the source tree
- R3. No existing managed skills or ignore patterns should be disrupted

## Scope Boundaries

- Only `ecc-observer-diagnosis` is in scope — it is the only unmanaged skill
- Plugin-provided symlink skills (`find-skills`, `gemini-api-dev`, `parallel-task`, `swarm-planner`) and `learned/` are intentionally unmanaged and should stay excluded
- No new declarative sync patterns needed — this is a simple source-tree addition

## Context & Research

### Relevant Code and Patterns

- Existing managed skills follow the pattern: `dot_claude/skills/<name>/SKILL.md` in source tree → deploys to `~/.claude/skills/<name>/SKILL.md`
- Five skills already use this pattern: `compound-harness-knowledge`, `execplan`, `node-typescript-mts-esm`, `propose-harness-improvement`, `validate-harness-proposal`
- `.chezmoiignore` excludes specific skill directories by name (symlinks, learned), not by glob — so new directories under `dot_claude/skills/` deploy automatically

### Institutional Learnings

- `docs/solutions/integration-issues/chezmoi-scripts-deployment-gap-repo-only-vs-deployed-2026-04-04.md` — scripts/files that are needed at runtime must be in `dot_*` paths, not `scripts/`
- Never edit deployed targets directly — always edit the chezmoi source file

## Key Technical Decisions

- **Direct source tree addition (not `.chezmoiexternal.toml`)**: The skill is locally authored (not an external repo), so it belongs in `dot_claude/skills/` like the other five local skills
- **No `.chezmoiignore` changes needed**: New directories under `dot_claude/skills/` deploy automatically — no ignore pattern blocks them

## Open Questions

### Resolved During Planning

- **Should the skill be a template?** No — the skill content contains no template variables (`.chezmoi.homeDir`, `.profile`, etc.). Regular file is correct.

### Deferred to Implementation

- None — this is straightforward file addition.

## Implementation Units

- [x] **Unit 1: Add ecc-observer-diagnosis to chezmoi source tree**

**Goal:** Track the skill in version control and enable consistent deployment via `chezmoi apply`.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Create: `dot_claude/skills/ecc-observer-diagnosis/SKILL.md`

**Approach:**
- Copy the content from the deployed `~/.claude/skills/ecc-observer-diagnosis/SKILL.md` into the source tree at `dot_claude/skills/ecc-observer-diagnosis/SKILL.md`
- Verify `chezmoi managed` shows the new file
- Verify `chezmoi diff` shows no drift (source matches deployed target)

**Patterns to follow:**
- `dot_claude/skills/propose-harness-improvement/SKILL.md` — same structure (directory + single SKILL.md)

**Test scenarios:**
- Happy path: `chezmoi managed | grep ecc-observer-diagnosis` returns the skill path
- Happy path: `chezmoi diff` shows no diff for the skill (source matches target)
- Edge case: `chezmoi apply --dry-run` does not attempt to overwrite or delete any other skills

**Verification:**
- `chezmoi managed` includes `.claude/skills/ecc-observer-diagnosis/SKILL.md`
- `chezmoi diff` shows no changes for the skill file
- Existing skills remain unaffected

## System-Wide Impact

- **Interaction graph:** None — adding a file to the source tree has no side effects
- **Unchanged invariants:** All existing skills, `.chezmoiignore` patterns, and `.chezmoiexternal.toml` entries remain unchanged

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Content drift between deployed and source | Verify with `chezmoi diff` immediately after adding |

## Sources & References

- Related memory: `ecc_observer_fix.md` — context on why this skill was created
- Related code: `dot_claude/skills/` — existing local skill pattern
