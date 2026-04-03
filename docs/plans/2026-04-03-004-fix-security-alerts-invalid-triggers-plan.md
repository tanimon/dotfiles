---
title: "fix: Remove invalid GitHub Actions event triggers from security-alerts workflow"
type: fix
status: completed
date: 2026-04-03
---

# fix: Remove invalid GitHub Actions event triggers from security-alerts workflow

## Overview

The `security-alerts.yml` workflow fails on every push because it uses three event trigger names (`dependabot_alert`, `code_scanning_alert`, `secret_scanning_alert`) that are not recognized by GitHub Actions as valid workflow triggers. These exist as GitHub webhook event types but are not supported in the `on:` block of workflow files. The fix removes the invalid triggers and the associated dead jobs, keeping only the `schedule` + `workflow_dispatch` triggers and the `sweep` job which already provides comprehensive coverage of all alert types.

## Problem Frame

GitHub Actions error on every push to `main`:
```
Invalid workflow file: .github/workflows/security-alerts.yml#L1
(Line: 4, Col: 3): Unexpected value 'dependabot_alert'
(Line: 6, Col: 3): Unexpected value 'code_scanning_alert'
(Line: 8, Col: 3): Unexpected value 'secret_scanning_alert'
```

The workflow was designed with four jobs: three reactive handlers (one per alert type) and one sweep job (schedule + manual). Since the reactive event triggers are invalid, the three individual jobs could never execute. The sweep job — which already handles all three alert types — is the only functional component.

## Requirements Trace

- R1. The workflow file must pass GitHub Actions validation (no "Unexpected value" errors)
- R2. Weekly scheduled sweep and manual dispatch must continue to work
- R3. All alert types (Dependabot, code scanning, secret scanning) must still be handled by the sweep job
- R4. CLAUDE.md documentation must reflect the actual trigger behavior

## Scope Boundaries

- This fix does NOT attempt to implement reactive alert handling via alternative mechanisms (e.g., `repository_dispatch` with webhook forwarding)
- No changes to the sweep job's prompt or logic — it already handles all alert types

## Key Technical Decisions

- **Remove individual handler jobs entirely**: The `dependabot`, `code-scanning`, and `secret-scanning` jobs are dead code — they can never trigger. Keeping them adds maintenance burden and confusion.
- **Remove `if` condition from sweep job**: With only `schedule` and `workflow_dispatch` triggers remaining, the `if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'` condition is always true and adds noise.
- **No reactive alternative**: Implementing webhook-to-`repository_dispatch` forwarding would add significant complexity for marginal benefit. The weekly sweep + manual dispatch covers the use case adequately.

## Implementation Units

- [ ] **Unit 1: Remove invalid triggers and dead jobs from workflow**

  **Goal:** Make the workflow file pass GitHub Actions validation

  **Requirements:** R1, R2, R3

  **Dependencies:** None

  **Files:**
  - Modify: `.github/workflows/security-alerts.yml`

  **Approach:**
  - Remove the three invalid event triggers (`dependabot_alert`, `code_scanning_alert`, `secret_scanning_alert`) from the `on:` block
  - Keep `schedule` and `workflow_dispatch` triggers unchanged
  - Remove the `dependabot` job (lines 27-125)
  - Remove the `code-scanning` job (lines 127-216)
  - Remove the `secret-scanning` job (lines 218-281)
  - Remove the `if` condition from the `sweep` job (always true now)
  - Keep the `sweep` job, the "Snapshot existing issues" step, "Determine alert scope" step, and "Generate summary" step intact

  **Patterns to follow:**
  - `harness-analysis.yml` uses the same `schedule` + `workflow_dispatch` pattern without `if` conditions

  **Test scenarios:**
  - Happy path: `actionlint .github/workflows/security-alerts.yml` produces no errors
  - Happy path: `make actionlint` passes
  - Edge case: `workflow_dispatch` input for `alert_type` still works (choice options preserved)

  **Verification:**
  - `actionlint` and `zizmor` pass locally
  - Push to GitHub does not produce "workflow file issue" failures

- [ ] **Unit 2: Update CLAUDE.md documentation**

  **Goal:** Reflect actual trigger behavior in project documentation

  **Requirements:** R4

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `CLAUDE.md`

  **Approach:**
  - Update the "Automated security alert handling" paragraph to describe the workflow as schedule + manual dispatch only, removing mention of reactive event triggers

  **Test expectation:** none -- documentation-only change

  **Verification:**
  - CLAUDE.md accurately describes the workflow's triggers

## System-Wide Impact

- **Interaction graph:** No other workflows depend on `security-alerts.yml`. The sweep job's behavior (creating PRs, issues) is unchanged.
- **Unchanged invariants:** The sweep job prompt, alert processing logic, and `claude-code-action` configuration remain identical.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Loss of reactive alert handling | The sweep job already handles all alert types on a weekly schedule. Manual dispatch (`gh workflow run security-alerts.yml`) provides on-demand coverage. |

## Sources & References

- GitHub Actions run: `tanimon/dotfiles` actions/runs/23931891804
- Related pattern: `.github/workflows/harness-analysis.yml` (schedule + workflow_dispatch)
