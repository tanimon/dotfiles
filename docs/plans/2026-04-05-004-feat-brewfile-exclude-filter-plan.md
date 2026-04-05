---
title: "feat: Add exclude filter to update-brewfile.sh"
type: feat
status: completed
date: 2026-04-05
---

# feat: Add exclude filter to update-brewfile.sh

## Overview

Add a post-dump filtering step to `scripts/update-brewfile.sh` that removes unwanted packages from the generated Brewfile. The user wants to exclude `vscode` (all VSCode-related lines including cask and extensions) and `go` (brew formula) from being tracked.

## Problem Frame

`brew bundle dump` captures the entire Homebrew state including packages the user does not want version-controlled (e.g., VSCode extensions managed separately, language runtimes managed by mise). The script currently has no filtering capability.

## Requirements Trace

- R1. Lines matching `vscode` entries (type `vscode "..."`) must be removed from the dumped Brewfile
- R2. The `cask "visual-studio-code"` line must be removed from the dumped Brewfile
- R3. The `brew "go"` line must be removed from the dumped Brewfile
- R4. The exclusion list must be easily extensible for future packages
- R5. Existing non-excluded Brewfile content must be preserved exactly

## Scope Boundaries

- Only modifies `scripts/update-brewfile.sh` — no changes to chezmoi templates or run_onchange scripts
- Does not affect `brew bundle install` behavior (Brewfile consumers)
- Removal is post-dump filtering, not a `brew bundle dump` flag (no such flag exists)

## Key Technical Decisions

- **Exclude list as array variable at top of script**: Easy to read, extend, and grep for. Preferable over a separate config file for this scale.
- **`grep -v` pipeline for filtering**: Simple, portable, and fits the existing script style. Each exclude pattern is applied via `grep -vE`.
- **Pattern matching strategy**: Use `^vscode ` to match all VSCode extension lines, `^cask "visual-studio-code"` for the cask, and `^brew "go"$` for the exact go formula (avoid matching `brew "gojq"` etc.).

## Implementation Units

- [ ] **Unit 1: Add exclude filter to update-brewfile.sh**

**Goal:** Filter out unwanted packages after `brew bundle dump`

**Requirements:** R1, R2, R3, R4, R5

**Dependencies:** None

**Files:**
- Modify: `scripts/update-brewfile.sh`
- Test: `scripts/tests/test-update-brewfile.sh` (if test infrastructure exists, otherwise verify manually)

**Approach:**
- Define an array of grep patterns to exclude at the top of the script
- After `brew bundle dump`, apply `grep -vE` with combined patterns to filter the file in-place
- Use a temporary file or `sed -i` to avoid partial write issues

**Patterns to follow:**
- Existing script style: `set -euo pipefail`, `SCRIPT_DIR`/`REPO_ROOT` variables
- Keep the entry count output accurate (count after filtering)

**Test scenarios:**
- Happy path: Run script → Brewfile contains no `vscode` lines, no `cask "visual-studio-code"`, no `brew "go"`
- Happy path: Run script → Brewfile still contains all other packages (e.g., `brew "gh"`, `cask "1password"`)
- Edge case: `brew "go"` pattern does not match `brew "gojq"`, `brew "go-task"`, or similar prefixed packages
- Edge case: Entry count in output message reflects post-filter line count

**Verification:**
- `grep -c '^vscode ' darwin/Brewfile` returns 0
- `grep -c 'visual-studio-code' darwin/Brewfile` returns 0
- `grep -c '^brew "go"$' darwin/Brewfile` returns 0
- Other brew/cask entries remain intact

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Overly broad pattern matches unintended packages | Use exact patterns: `^brew "go"$` not `go` |

## Sources & References

- Related code: `scripts/update-brewfile.sh`
- Related code: `darwin/Brewfile`
