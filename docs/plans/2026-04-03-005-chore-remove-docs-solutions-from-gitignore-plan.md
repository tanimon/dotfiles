---
title: "chore: Remove docs/solutions/ from .gitignore"
type: refactor
status: active
date: 2026-04-03
---

# chore: Remove docs/solutions/ from .gitignore

## Overview

Remove the `docs/solutions/` entry from `dot_gitignore` (the chezmoi source for `~/.gitignore`). This line was added manually but `docs/solutions/` is a repo-only directory already excluded via `.chezmoiignore` — it does not need to be in the global gitignore.

## Problem Frame

`dot_gitignore` contains `docs/solutions/` which is a project-specific path that does not belong in a global gitignore deployed to `~/`. The repo's `.chezmoiignore` already prevents chezmoi from deploying `docs/` to the home directory.

## Requirements Trace

- R1. Remove `docs/solutions/` line from `dot_gitignore`

## Scope Boundaries

- Only `dot_gitignore` is modified
- No other gitignore entries are changed

## Implementation Units

- [ ] **Unit 1: Remove docs/solutions/ from dot_gitignore**

**Goal:** Delete the `docs/solutions/` line from the gitignore source file.

**Files:**
- Modify: `dot_gitignore`

**Approach:**
- Remove the line containing `docs/solutions/`

**Test expectation:** none -- single line deletion from a config file, no behavioral change

**Verification:**
- `docs/solutions/` no longer appears in `dot_gitignore`
- `make lint` passes
