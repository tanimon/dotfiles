---
title: "fix: Enable commit signing for claude-code-action workflows"
type: fix
status: active
date: 2026-04-05
---

# fix: Enable commit signing for claude-code-action workflows

## Overview

GitHub rulesets enforce `Require signed commits` on this repository. Commits created by `claude-code-action` in CI workflows are unsigned, causing PRs to be blocked with "Commits must have verified signatures." Adding `use_commit_signing: true` to all commit-creating workflows resolves this.

## Problem Frame

The `harness-auto-remediate.yml` workflow successfully creates PRs (e.g., #139), but the commits are unsigned. The repository's ruleset requires verified signatures, making these PRs unmergeable. The same issue affects all other workflows that create commits via `claude-code-action`.

## Requirements Trace

- R1. PRs created by `claude-code-action` workflows must have verified commit signatures
- R2. All commit-creating workflows must be updated consistently
- R3. No changes to workflows that only read/comment (no commits)

## Scope Boundaries

- Only workflows that create commits/pushes/PRs are in scope
- `harness-analysis.yml` (creates issues only) is out of scope
- `claude.yml` review mode is out of scope (comments only, no commits)
- `claude.yml` non-review mode may create commits via user prompts — include for safety
- Ruleset configuration itself is not changed

## Context & Research

### Relevant Code and Patterns

- `claude-code-action` supports `use_commit_signing: true` input parameter
- When enabled, commits are signed using the GitHub API, producing verified signatures
- No SSH key or GPG setup required — uses the GitHub App's built-in signing
- All workflows pin to `anthropics/claude-code-action@58dbe8ed6879f0d3b02ac295b20d5fdfe7733e0c # v1.0.85`

### Institutional Learnings

- `docs/solutions/integration-issues/ci-workflow-branch-protection-requires-pr-flow-2026-04-05.md` — All code-generating workflows already use branch + PR flow

## Key Technical Decisions

- **`use_commit_signing: true` over SSH signing**: The GitHub API signing approach is simpler — no secret management, no key rotation, no additional setup. It covers all standard commit workflows used in this repo (commit, push, PR create). SSH signing would only be needed for advanced git operations (rebase, cherry-pick) which these workflows don't use.

## Open Questions

### Resolved During Planning

- **Which workflows create commits?** — `harness-auto-remediate.yml`, `auto-promote.yml`, `security-alerts.yml`, and `claude.yml` (non-review mode). `harness-analysis.yml` only creates issues.
- **Does `use_commit_signing` require additional permissions?** — No, the existing `contents: write` permission is sufficient.

### Deferred to Implementation

- None

## Implementation Units

- [ ] **Unit 1: Add `use_commit_signing: true` to all commit-creating workflows**

**Goal:** Enable verified commit signatures for all `claude-code-action` invocations that may create commits.

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/harness-auto-remediate.yml`
- Modify: `.github/workflows/auto-promote.yml`
- Modify: `.github/workflows/security-alerts.yml`
- Modify: `.github/workflows/claude.yml`

**Approach:**
- Add `use_commit_signing: true` to the `with:` block of each `claude-code-action` step that may create commits
- `harness-auto-remediate.yml`: 1 step (line 68)
- `auto-promote.yml`: 1 step (line 51)
- `security-alerts.yml`: 1 step (line 60)
- `claude.yml`: 1 step — non-review mode only (line 59). Review mode only posts comments and does not create commits, so signing is not needed

**Patterns to follow:**
- Existing `with:` block parameter style in each workflow
- Place `use_commit_signing` after `claude_code_oauth_token` for consistency

**Test scenarios:**
- Happy path: After merge, trigger `harness-auto-remediate.yml` via `workflow_dispatch` — resulting PR commits should show "Verified" badge
- Happy path: `actionlint` passes on all modified workflow files (`make actionlint`)

**Verification:**
- `make actionlint` passes
- All 4 workflow files include `use_commit_signing: true` in their commit-creating `claude-code-action` steps (claude.yml review step excluded — it only posts comments)

## System-Wide Impact

- **Interaction graph:** No behavioral change — commit signing is transparent to the action's prompt and claude_args
- **Error propagation:** If signing fails, the action itself will error (no silent degradation)
- **Unchanged invariants:** Workflow triggers, permissions, prompts, and `claude_args` are not modified

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `use_commit_signing` not available in pinned v1.0.85 | Verify parameter exists in the action's `action.yml` at the pinned SHA before merging. If not available, upgrade to a version that supports it |

## Sources & References

- Related PR: #139 (blocked by unsigned commits)
- Workflow run: https://github.com/tanimon/dotfiles/actions/runs/23998240010/job/69989898152
- claude-code-action docs: commit signing support via `use_commit_signing` and `ssh_signing_key` inputs
