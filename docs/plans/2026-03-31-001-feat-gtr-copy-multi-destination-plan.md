---
title: "feat: Support multiple destination worktrees in gtr-copy"
type: feat
status: completed
date: 2026-03-31
---

# feat: Support multiple destination worktrees in gtr-copy

## Overview

Modify `gtr-copy` to allow selecting multiple destination worktrees via fzf `--multi`, so files can be copied to several worktrees in a single invocation.

## Problem Frame

Currently `gtr-copy` uses single-select fzf for the destination worktree. When working with multiple worktrees (e.g., feature branches), users must run the command repeatedly to copy the same files to different destinations. This is tedious and error-prone.

## Requirements Trace

- R1. Destination worktree selection uses fzf `--multi` (Tab to toggle, Enter to confirm)
- R2. Selected files are copied to every selected destination worktree
- R3. Summary output shows per-destination copy counts
- R4. Existing behavior preserved when only one destination is selected
- R5. Script continues to pass `shellcheck` and `shfmt -i 4`

## Scope Boundaries

- File selection behavior is unchanged (already supports `--multi`)
- No new dependencies introduced
- No change to path safety checks

## Context & Research

### Relevant Code and Patterns

- `dot_local/bin/executable_gtr-copy` — current script (49 lines)
- `dot_local/bin/executable_git-clean-squashed` — sibling script following same conventions
- Conventions: `set -euo pipefail`, tool guards, stderr error messages with script name prefix, `|| exit 0` for fzf cancellation, 4-space indent

### Institutional Learnings

- `docs/solutions/integration-issues/gtr-shell-integration-over-custom-wrapper.md` — gtr ecosystem context
- Shell scripts must pass `make shellcheck && make shfmt`

## Key Technical Decisions

- **Loop over destinations, not files**: The outer loop iterates over selected destinations, inner loop over files. This keeps the copy logic simple and produces per-destination output.
- **fzf `--multi` on destination selection**: Same UX pattern already used for file selection — consistent user experience.

## Implementation Units

- [ ] **Unit 1: Add multi-select to destination worktree fzf**

**Goal:** Allow multiple worktree destinations via fzf `--multi` and copy files to each.

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `dot_local/bin/executable_gtr-copy`

**Approach:**
- Change the destination fzf call from single-select to `--multi` with updated header text
- Parse each selected line to extract the worktree path (first field via `awk`)
- Wrap the existing copy loop in an outer loop over selected destinations
- Adjust summary output to show per-destination counts

**Patterns to follow:**
- File selection fzf call on line 24-31 (already uses `--multi`)
- Existing `while IFS= read -r` loop pattern for iterating fzf output

**Test scenarios:**
- Happy path: single destination selected → same behavior as before (R4)
- Happy path: multiple destinations selected → files copied to each destination with per-destination summary (R2, R3)
- Edge case: user cancels at destination selection → exits 0 gracefully
- Edge case: file with directory nesting → `mkdir -p` creates intermediate dirs in all destinations

**Verification:**
- `make shellcheck && make shfmt` passes
- Manual test: select 2+ worktrees, verify files appear in each

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| User confusion with changed fzf header | Clear header text indicating multi-select capability |

## Sources & References

- Related plan: `docs/plans/2026-03-19-002-feat-gtr-copy-worktree-file-copier-plan.md` (original gtr-copy)
