---
title: "fix: Add allowed_bots to harness-auto-remediate workflow"
type: fix
status: completed
date: 2026-04-05
---

# fix: Add allowed_bots to harness-auto-remediate workflow

## Overview

The `harness-auto-remediate.yml` workflow fails because `claude-code-action` v1.0.85 rejects bot-initiated triggers unless `allowed_bots` is explicitly set.

## Problem Frame

The workflow's `if` condition correctly allows `claude[bot]` (fixed in 2026-03-30), so the job now runs instead of being skipped. However, `claude-code-action` itself has an internal actor validation that rejects non-human actors unless listed in `allowed_bots`.

Error: `Workflow initiated by non-human actor: claude (type: Bot). Add bot to allowed_bots list or use '*' to allow all bots.`

Three consecutive failures on 2026-04-05 confirm this.

## Requirements Trace

- R1. `claude-code-action` must execute when triggered by `claude[bot]` via `harness-analysis` label
- R2. Security: only `claude[bot]` should be allowed, not all bots
- R3. No changes to remediation logic or other workflows

## Implementation

Single change: add `allowed_bots: 'claude[bot]'` to the `claude-code-action` step's `with` inputs.

**File:** `.github/workflows/harness-auto-remediate.yml` (line ~69)

**Verification:** `make lint` (includes actionlint + zizmor)
