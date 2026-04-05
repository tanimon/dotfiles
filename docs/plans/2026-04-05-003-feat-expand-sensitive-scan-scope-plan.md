---
title: "feat: Expand sensitive info scan to all repo .md files"
type: feat
status: completed
date: 2026-04-05
---

# Expand Sensitive Info Scan to All Repo .md Files

## Overview

Expand `scan-sensitive-info.sh` default scan scope from `docs/` directory only to all `.md` files under the repo root. This ensures PII and sensitive information is caught in files like `CLAUDE.md`, `README.md`, and any other markdown files outside `docs/`.

## Problem Frame

Currently, `scan-sensitive-info.sh` defaults to scanning only `docs/**/*.md`. Markdown files at the repo root or in other directories (e.g., `.claude/rules/`) are not scanned unless explicitly passed as arguments. This leaves a gap where sensitive information in non-`docs/` markdown files goes undetected.

## Requirements Trace

- R1. Default scan scope covers all `.md` files under repo root
- R2. Exclude directories that should never be scanned (`node_modules`, `.git`, vendor dirs)
- R3. Makefile variable and target reflect the new scope
- R4. Documentation updated to match new behavior
- R5. Pre-commit hook already covers all `.md` files (no change needed — `files: '\.md$'` already matches repo-wide)

## Scope Boundaries

- Pre-commit config already matches all `.md` files — no change needed there
- CI workflow calls `make scan-sensitive` — no change needed there (inherits Makefile change)
- Argument-passing mode (explicit files) unchanged

## Key Technical Decisions

- **Exclude `node_modules` and `.git`**: Use `-not -path` in find to avoid scanning vendored or git-internal files
- **Rename variable**: `DOCS_MD_FILES` → `ALL_MD_FILES` to reflect new scope accurately

## Implementation Units

- [x] **Unit 1: Expand scan scope in script and Makefile**

**Goal:** Change default find path from `docs/` to repo root with exclusions

**Requirements:** R1, R2, R3

**Files:**
- Modify: `scripts/scan-sensitive-info.sh`
- Modify: `Makefile`

**Approach:**
- In `scan-sensitive-info.sh` line 20: change `find "$REPO_ROOT/docs"` to `find "$REPO_ROOT"` with `-not -path` exclusions for `.git`, `node_modules`
- In `Makefile` line 21: change `find ./docs` to `find .` with same exclusions, rename variable
- Update Makefile target comment to reflect broader scope

**Patterns to follow:**
- Existing `find` exclusion patterns in `Makefile` (see `SHELL_FILES` definition lines 7-19)

**Test scenarios:**
- Happy path: Script with no args scans `.md` files from repo root (not just `docs/`)
- Happy path: `make scan-sensitive` picks up root-level `.md` files
- Edge case: `node_modules/**/*.md` files are excluded from scan

**Verification:**
- `make scan-sensitive` runs successfully
- `make lint` passes

- [x] **Unit 2: Update documentation**

**Goal:** Update CLAUDE.md to reflect new scan scope

**Requirements:** R4

**Files:**
- Modify: `CLAUDE.md`

**Approach:**
- Update the comment next to `make scan-sensitive` and any prose mentioning "docs" scope

**Test expectation:** none -- documentation-only change

**Verification:**
- CLAUDE.md accurately describes the scan scope

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| New false positives from scanning more files | Existing patterns file is specific enough; review initial run output |
