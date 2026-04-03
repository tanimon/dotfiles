---
title: "chore: Manage unmanaged ~/.claude files"
type: chore
status: completed
date: 2026-04-03
---

# chore: Manage unmanaged ~/.claude files

## Overview

Audit `chezmoi unmanaged ~/.claude` output, delete files that overlap with installed plugin functionality or are superseded by existing managed files, then bring remaining useful files under chezmoi management.

## Problem Frame

`~/.claude/` contains 17 unmanaged items — a mix of superseded scripts, plugin-duplicate skills/commands, runtime directories, and genuinely useful custom config that should be tracked. Without management, these files are invisible to version control, fragile across machines, and accumulate dead code.

## Requirements Trace

- R1. Delete files whose purpose is already covered by an installed plugin skill
- R2. Delete files superseded by existing managed files (old implementations replaced by newer managed versions)
- R3. Add remaining useful unmanaged files to chezmoi management
- R4. Add runtime/application-state directories to `.chezmoiignore`

## Scope Boundaries

- Plugin install/uninstall decisions are out of scope — only manage existing local files
- No changes to `settings.json` hooks or statusLine config
- No changes to plugin enable/disable state

## Context & Research

### Unmanaged Items Analysis

| Unmanaged Item | Disposition | Reason |
|---|---|---|
| `.claude/.claude` | IGNORE | Claude Code internal directory (`settings.local.json`) |
| `.claude/agents` | IGNORE | Agent definition files — application state, unchanged since 2025-08 |
| `.claude/logs` | IGNORE | Runtime log directory |
| `.claude/plugins/data` | IGNORE | Plugin runtime data |
| `.claude/commands/simplify.md` | DELETE | Overlaps with `compound-engineering:simplify` plugin skill (enabled) |
| `.claude/skills/swarm` | DELETE | Overlaps with `superpowers:dispatching-parallel-agents` + `superpowers:subagent-driven-development` (enabled) |
| `.claude/scripts/claude-code-status-line.py` | DELETE | Superseded by managed `statusline-command.ts` (settings.json uses `.ts`) |
| `.claude/scripts/status-line.js` | DELETE | Superseded by managed `statusline-command.ts` |
| `.claude/scripts/statusline-wrapper.sh` | DELETE | Not referenced in `settings.json`; `.ts` used directly |
| `.claude/scripts/harness-check.sh` | DELETE | Superseded by managed `harness-activator.sh` |
| `.claude/scripts/harness-feedback-collector.sh` | DELETE | Not referenced in any hook; dead code |
| `.claude/scripts/notify.mjs` | DELETE | Superseded by managed `notify.mts` + `notify-wrapper.sh` |
| `.claude/commands/gemini-search.md` | MANAGE | Custom command for Gemini CLI web search — no plugin overlap |
| `.claude/commands/pr-desc.md` | MANAGE | Custom Japanese-language PR description command — no plugin overlap |
| `.claude/skills/execplan` | MANAGE | ExecPlan methodology skill — no plugin overlap (distinct from ce:plan, planning-with-files) |
| `.claude/skills/node-typescript-mts-esm` | MANAGE | Node.js TypeScript ESM fix skill — no plugin overlap |

### Key Decisions

- **`simplify.md` deletion**: The local command (`"Would a senior engineer say this is overcomplicated? If yes, simplify."`) is a subset of `compound-engineering:simplify` which does the same plus reuse/efficiency review. No value retained by keeping both.
- **`swarm` deletion**: 48k skill for TeammateTool orchestration. `superpowers` plugin provides equivalent multi-agent coordination (`dispatching-parallel-agents` for independent parallel work, `subagent-driven-development` for plan execution). Removing 48k of context load is a net positive.
- **`harness-feedback-collector.sh` deletion**: Planned in `docs/plans/2026-03-28-002` but never wired into `settings.json` hooks. The Stop hook only calls `notify-wrapper.sh`. Dead code.
- **`statusline-wrapper.sh` deletion**: Created per `docs/plans/2026-03-17-004` but `settings.json` `statusLine.command` was later changed to call `node --experimental-strip-types $HOME/.claude/statusline-command.ts` directly. Wrapper is unused.

## Implementation Units

- [ ] **Unit 1: Delete plugin-overlapping and superseded files**

**Goal:** Remove 8 files/directories that duplicate plugin functionality or are superseded by managed versions.

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Delete: `~/.claude/commands/simplify.md`
- Delete: `~/.claude/skills/swarm/` (directory)
- Delete: `~/.claude/scripts/claude-code-status-line.py`
- Delete: `~/.claude/scripts/status-line.js`
- Delete: `~/.claude/scripts/statusline-wrapper.sh`
- Delete: `~/.claude/scripts/harness-check.sh`
- Delete: `~/.claude/scripts/harness-feedback-collector.sh`
- Delete: `~/.claude/scripts/notify.mjs`

**Approach:**
- Delete from `~/.claude/` (target directory) only — these are NOT in the chezmoi source tree
- No chezmoi source changes needed for this unit

**Test expectation:** none — file deletion with no behavioral change

**Verification:**
- Deleted files no longer appear in `chezmoi unmanaged ~/.claude`

- [ ] **Unit 2: Add runtime directories to `.chezmoiignore`**

**Goal:** Prevent 4 runtime/application-state directories from appearing in future `chezmoi unmanaged` output.

**Requirements:** R4

**Dependencies:** None

**Files:**
- Modify: `.chezmoiignore`

**Approach:**
- Add entries to the existing `# ~/.claude/ auto-managed` section
- Entries: `.claude/.claude`, `.claude/agents`, `.claude/logs`, `.claude/plugins/data`

**Patterns to follow:**
- Existing `.chezmoiignore` entries under `# ~/.claude/ auto-managed` comment block

**Test expectation:** none — ignore list change

**Verification:**
- `chezmoi unmanaged ~/.claude` no longer lists these directories

- [ ] **Unit 3: Add custom commands to chezmoi management**

**Goal:** Bring 2 custom command files under chezmoi source control.

**Requirements:** R3

**Dependencies:** Unit 1 (simplify.md must be deleted first to avoid adding it)

**Files:**
- Create: `dot_claude/commands/gemini-search.md` (via `chezmoi add`)
- Create: `dot_claude/commands/pr-desc.md` (via `chezmoi add`)

**Approach:**
- Use `chezmoi add ~/.claude/commands/gemini-search.md` and `chezmoi add ~/.claude/commands/pr-desc.md`
- These are plain markdown files — no template needed
- Verify the files are placed alongside existing managed commands (`apply-harness-proposal.md`, etc.)

**Patterns to follow:**
- Existing `dot_claude/commands/*.md` files

**Test scenarios:**
- Happy path: `chezmoi managed | grep commands/` shows both new files alongside existing ones

**Verification:**
- `chezmoi managed` includes `.claude/commands/gemini-search.md` and `.claude/commands/pr-desc.md`
- `chezmoi diff` shows no differences for these files

- [ ] **Unit 4: Add custom skills to chezmoi management**

**Goal:** Bring 2 custom skill directories under chezmoi source control.

**Requirements:** R3

**Dependencies:** Unit 1 (swarm must be deleted first to avoid adding it)

**Files:**
- Create: `dot_claude/skills/execplan/SKILL.md` (via `chezmoi add`)
- Create: `dot_claude/skills/execplan/PLANS.md` (via `chezmoi add`)
- Create: `dot_claude/skills/node-typescript-mts-esm/SKILL.md` (via `chezmoi add`)

**Approach:**
- Use `chezmoi add` for each file in the skill directories
- These are plain markdown files — no template needed
- Verify placement alongside existing managed skills (`compound-harness-knowledge/`, `propose-harness-improvement/`, etc.)

**Patterns to follow:**
- Existing `dot_claude/skills/*/SKILL.md` structure

**Test scenarios:**
- Happy path: `chezmoi managed | grep skills/` shows new skills alongside existing ones

**Verification:**
- `chezmoi managed` includes the new skill files
- `chezmoi diff` shows no differences for these files
- `chezmoi unmanaged ~/.claude` returns empty (all items now managed or ignored)

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Deleting a script that's still referenced elsewhere | Verified: none of the deleted scripts are referenced in `settings.json` hooks or `statusLine` config |
| `swarm` skill might be needed for team-based orchestration not covered by superpowers | `superpowers` provides `dispatching-parallel-agents` and `subagent-driven-development`; if team features are needed later, the skill can be reinstalled from git history |
