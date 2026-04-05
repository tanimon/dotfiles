---
title: "feat: Exclude vscode extensions and go packages from Brewfile dump"
type: feat
status: completed
date: 2026-04-05
---

# feat: Exclude vscode extensions and go packages from Brewfile dump

## Overview

Add `--no-vscode` and `--no-go` flags to `brew bundle dump` in `scripts/update-brewfile.sh` to prevent VSCode extensions and Go packages from being tracked in the Brewfile.

## Problem Frame

`brew bundle dump` captures the entire Homebrew state including package types the user does not want version-controlled (e.g., VSCode extensions managed separately, Go packages managed by mise). The script currently dumps everything without filtering.

## Requirements Trace

- R1. VSCode extensions (`vscode "..."` lines) must not appear in the dumped Brewfile
- R2. Go packages (`go "..."` lines) must not appear in the dumped Brewfile
- R3. Existing non-excluded Brewfile content (formulae, casks, taps, mas) must be preserved exactly

## Scope Boundaries

- Only modifies `scripts/update-brewfile.sh` — no changes to chezmoi templates or run_onchange scripts
- Does not exclude `cask "visual-studio-code"` or `brew "go"` (the formula) — only the `vscode` and `go` package types
- Does not affect `brew bundle install` behavior (Brewfile consumers)

## Key Technical Decisions

- **Use `brew bundle dump` built-in flags (`--no-vscode`, `--no-go`)**: Discovered that `brew bundle dump` natively supports excluding package types via `--no-vscode` and `--no-go` flags. This is cleaner than post-dump `grep` filtering — no regex edge cases, no `set -e` compatibility issues, and the exclusion happens at dump time.

## Implementation Units

- [x] **Unit 1: Add --no-vscode --no-go flags to brew bundle dump**

**Goal:** Exclude VSCode extensions and Go packages at dump time

**Requirements:** R1, R2, R3

**Files:**
- Modify: `scripts/update-brewfile.sh`

**Approach:**
- Add `--no-vscode --no-go` to the existing `brew bundle dump` command
- No post-processing needed — flags handle exclusion natively

**Verification:**
- `grep -c '^vscode ' darwin/Brewfile` returns 0 after running the script
- `grep -c '^go ' darwin/Brewfile` returns 0 after running the script
- Other brew/cask/tap/mas entries remain intact

## Sources & References

- Related code: `scripts/update-brewfile.sh`
- Related code: `darwin/Brewfile`
- `brew bundle dump --help` — documents `--no-vscode`, `--no-go` flags
