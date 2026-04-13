---
title: "fix: Handle missing GitHub App secrets and fix permission inputs in security-alerts workflow"
type: fix
status: active
date: 2026-04-13
---

# fix: Handle missing GitHub App secrets and fix permission inputs in security-alerts workflow

## Overview

The `security-alerts.yml` workflow fails at the "Generate security alerts token" step because (1) the `SECURITY_APP_ID` / `SECURITY_APP_PRIVATE_KEY` repository secrets are not configured, and (2) the `permissions` input format is incompatible with `create-github-app-token@v2.2.2`. The fix makes the workflow degrade gracefully when the GitHub App is not configured, and corrects the permission input format for when it is.

## Problem Frame

GitHub Actions run [#24273060475](https://github.com/tanimon/dotfiles/actions/runs/24273060475/job/70881653371) fails with:

```
Error: [@octokit/auth-app] appId option is required
```

Two root causes:

1. **Missing secrets**: `secrets.SECURITY_APP_ID` resolves to empty string because the repository secret is not configured. The `create-github-app-token` action requires a non-empty `app-id`.

2. **Wrong input format**: The action uses individual `permission-*` inputs (e.g., `permission-vulnerability-alerts: read`), not a single `permissions` JSON blob. The current format triggers a warning but does not cause the failure on its own.

## Requirements Trace

- R1. The workflow must not fail when `SECURITY_APP_ID` / `SECURITY_APP_PRIVATE_KEY` secrets are absent
- R2. When secrets are absent, code-scanning alerts (which work with `GITHUB_TOKEN`) must still be processed
- R3. When secrets are present, the `create-github-app-token` step must use the correct `permission-*` input format
- R4. The solution document must be updated to reflect the correct permission input format

## Scope Boundaries

- This fix does NOT set up the GitHub App or configure repository secrets — that is a manual step the user must perform separately
- No changes to the `claude-code-action` prompt or the sweep logic

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/security-alerts.yml` — the failing workflow
- `docs/solutions/integration-issues/github-actions-security-alert-workflow-pitfalls-2026-04-02.md` — documents the GitHub App token approach but contains the incorrect `permissions` format

### Institutional Learnings

- The `GITHUB_TOKEN` cannot access Dependabot or secret-scanning APIs (documented in the solution file above)
- `create-github-app-token@v2.2.2` accepts individual `permission-<name>: <level>` inputs, not a `permissions` JSON blob (from the workflow warning output)

## Key Technical Decisions

- **Conditional token generation via `if: secrets.SECURITY_APP_ID != ''`**: GitHub Actions evaluates `secrets.*` to empty string when the secret does not exist. This is the standard pattern for optional secret-dependent steps.
- **Conditional alert gathering for Dependabot/secret-scanning**: When the app token is unavailable, these alert types are skipped entirely rather than failing. The `Gather security alerts` step checks whether `APP_TOKEN` is non-empty before calling restricted APIs.
- **Individual `permission-*` inputs**: The `create-github-app-token@v2` action changed its input interface. Use `permission-vulnerability-alerts: read` and `permission-secret-scanning-alerts: read`.

## Open Questions

### Resolved During Planning

- **Which permission inputs are correct?** The action's warning message lists valid inputs: `permission-vulnerability-alerts` (maps to Dependabot alerts) and `permission-secret-scanning-alerts`. Values are `read` or `write`.

### Deferred to Implementation

- None

## Implementation Units

- [x] **Unit 1: Add secret existence check and fix permission inputs**

  **Goal:** Make the token generation step conditional and use the correct input format

  **Requirements:** R1, R3

  **Dependencies:** None

  **Files:**
  - Modify: `.github/workflows/security-alerts.yml`

  **Approach:**
  - Add `if: secrets.SECURITY_APP_ID != ''` to the "Generate security alerts token" step
  - Replace `permissions: >- {"dependabot_alerts": "read", "secret_scanning_alerts": "read"}` with individual inputs: `permission-vulnerability-alerts: read` and `permission-secret-scanning-alerts: read`

  **Patterns to follow:**
  - Standard GitHub Actions pattern for optional secrets: `if: secrets.FOO != ''`

  **Test scenarios:**
  - Happy path: `actionlint` passes on the modified workflow
  - Happy path: When secrets are configured, the step runs and generates a token with the correct permissions
  - Edge case: When secrets are not configured, the step is skipped (not failed)

  **Verification:**
  - `actionlint .github/workflows/security-alerts.yml` produces no errors
  - `make actionlint` passes

- [x] **Unit 2: Make alert gathering handle missing app token**

  **Goal:** When the GitHub App token is unavailable, skip Dependabot and secret-scanning alerts gracefully and process only code-scanning

  **Requirements:** R1, R2

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `.github/workflows/security-alerts.yml`

  **Approach:**
  - In the "Gather security alerts" step, check if `APP_TOKEN` is non-empty before calling restricted APIs
  - When empty, set Dependabot and secret-scanning arrays to `[]` with a warning message
  - Code-scanning always uses `GITHUB_TOKEN` and proceeds regardless

  **Test scenarios:**
  - Happy path: When `APP_TOKEN` is available, all three alert types are fetched
  - Edge case: When `APP_TOKEN` is empty, Dependabot and secret-scanning return `[]` with `::warning::` annotations, and code-scanning still works
  - Edge case: The `has_alerts` output is correctly computed even when some arrays are empty due to missing token

  **Verification:**
  - The workflow completes successfully on the next scheduled run (or manual dispatch) even without the GitHub App configured

- [x] **Unit 3: Update solution document with correct permission format**

  **Goal:** Fix the incorrect `permissions` example in the existing solution document

  **Requirements:** R4

  **Dependencies:** Unit 1

  **Files:**
  - Modify: `docs/solutions/integration-issues/github-actions-security-alert-workflow-pitfalls-2026-04-02.md`

  **Approach:**
  - Update the YAML example in the "Solution" section to use individual `permission-*` inputs
  - Add a note about the format change in `create-github-app-token@v2`

  **Test expectation:** none -- documentation-only change

  **Verification:**
  - The example YAML matches the actual workflow syntax

## System-Wide Impact

- **Interaction graph:** No other workflows depend on the security alerts token step. The `claude-code-action` sweep step is downstream and receives pre-fetched data — unaffected by this change.
- **Error propagation:** When the App token step is skipped, the `APP_TOKEN` env var is empty. The gather step must handle this explicitly rather than passing an empty token to `gh api`.
- **Unchanged invariants:** The sweep job prompt, `claude-code-action` configuration, and code-scanning alert handling remain identical.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `secrets.SECURITY_APP_ID != ''` may not evaluate correctly in all contexts | This is the standard GitHub Actions pattern for optional secrets, widely used and documented |
| Skipping Dependabot/secret-scanning reduces coverage | The workflow logs `::warning::` annotations making the gap visible. Users are guided to set up the GitHub App |

## Sources & References

- Failed run: https://github.com/tanimon/dotfiles/actions/runs/24273060475/job/70881653371
- Solution doc: `docs/solutions/integration-issues/github-actions-security-alert-workflow-pitfalls-2026-04-02.md`
- `create-github-app-token` action: valid inputs listed in the workflow warning output
