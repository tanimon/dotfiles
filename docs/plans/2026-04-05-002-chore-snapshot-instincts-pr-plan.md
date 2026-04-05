---
title: "chore: Snapshot instincts and create PR"
type: chore
status: active
date: 2026-04-05
---

# chore: Snapshot instincts and create PR

## Overview

Run `scripts/snapshot-instincts.sh` to refresh the instinct snapshot in `dot_claude/instinct-snapshots/`, then create a PR with the updated snapshot. This keeps the CI auto-promote workflow supplied with fresh instinct data.

## Problem Frame

The instinct snapshot in the source tree is stale (3 instincts), while the live directory has 8 instincts including 5 newly created ones. The auto-promote CI workflow reads from the snapshot, not the live directory, so it needs refreshing.

## Scope Boundaries

- Only snapshot refresh and PR creation — no code changes
- No observer bug fixes in this PR

## Implementation Units

- [ ] **Unit 1: Run snapshot script**

**Goal:** Refresh `dot_claude/instinct-snapshots/` with all 8 current instincts

**Files:**
- Modify: `dot_claude/instinct-snapshots/*.md` (8 instinct files)
- Modify: `dot_claude/instinct-snapshots/metadata.json`

**Approach:**
- Run `scripts/snapshot-instincts.sh` from repo root
- Verify output shows 8 instincts copied

**Test expectation:** none — operational script execution

**Verification:**
- Script reports 8 instincts copied, 0 skipped
- `dot_claude/instinct-snapshots/metadata.json` timestamp is current

- [ ] **Unit 2: Create branch, commit, and PR**

**Goal:** Land the snapshot update via PR (main branch is protected)

**Approach:**
- Create feature branch `chore/snapshot-instincts-2026-04-05`
- Commit all snapshot files
- Open PR targeting main

**Test expectation:** none — git operations only

**Verification:**
- PR is created and CI passes
