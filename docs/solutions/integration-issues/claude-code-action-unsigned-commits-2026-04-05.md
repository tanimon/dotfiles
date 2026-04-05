---
title: claude-code-action workflows create unsigned commits blocked by signed-commit rulesets
date: 2026-04-05
category: integration-issues
module: GitHub Actions / claude-code-action
problem_type: integration_issue
component: tooling
symptoms:
  - "PRs created by claude-code-action workflows show 'Commits must have verified signatures'"
  - "Merging is blocked when repository rulesets enforce 'Require signed commits'"
root_cause: missing_workflow_step
resolution_type: config_change
severity: high
tags:
  - harness-engineering
  - github-actions
  - commit-signing
  - claude-code-action
---

# claude-code-action workflows create unsigned commits blocked by signed-commit rulesets

## Problem

PRs created by `claude-code-action` workflows (harness-auto-remediate, auto-promote, security-alerts, claude) cannot be merged when the repository has a ruleset enforcing "Require signed commits." The commits are unsigned, triggering the "Commits must have verified signatures" block.

## Symptoms

- PR merge is blocked with "Commits must have verified signatures"
- GitHub shows commits without the "Verified" badge
- Workflow runs succeed but the resulting PR is unmergeable

## What Didn't Work

- N/A — direct investigation of `claude-code-action` parameters found the solution. No failed approaches.

## Solution

Add `use_commit_signing: true` to the `with:` block of every `claude-code-action` step that may create commits:

```yaml
# Before
- uses: anthropics/claude-code-action@<sha>
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    prompt: |
      ...

# After
- uses: anthropics/claude-code-action@<sha>
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    use_commit_signing: true
    prompt: |
      ...
```

Workflows updated:
- `.github/workflows/harness-auto-remediate.yml`
- `.github/workflows/auto-promote.yml`
- `.github/workflows/security-alerts.yml`
- `.github/workflows/claude.yml` (non-review step only)

Also added `id-token: write` permission to `security-alerts.yml` for consistency with other commit-creating workflows.

## Why This Works

`use_commit_signing: true` tells `claude-code-action` to use the GitHub API for creating commits instead of the git CLI. The GitHub API automatically signs commits using the GitHub App's built-in signing key, producing verified signatures without any SSH key or GPG configuration.

Two signing options exist in `claude-code-action`:
- `use_commit_signing: true` — GitHub API signing (simpler, no secrets management)
- `ssh_signing_key` — SSH key signing (for advanced git operations like rebase/cherry-pick)

The GitHub API approach is sufficient for standard commit/push/PR workflows.

## Prevention

- **When adding new `claude-code-action` workflows that create commits**, always include `use_commit_signing: true` in the `with:` block
- **When enabling signed-commit rulesets**, audit all existing workflows for unsigned commit paths
- **Checklist for commit-creating workflows:**
  - [ ] `use_commit_signing: true` in `claude-code-action` `with:` block
  - [ ] `contents: write` permission on the job
  - [ ] `id-token: write` permission on the job (for consistency)

## Related Issues

- PR [#139](https://github.com/tanimon/dotfiles/pull/139) — blocked PR that surfaced this issue
- PR [#140](https://github.com/tanimon/dotfiles/pull/140) — fix PR adding commit signing
- `docs/solutions/integration-issues/ci-workflow-branch-protection-requires-pr-flow-2026-04-05.md` — complementary: PR flow alone is insufficient if rulesets also require signed commits
- `docs/solutions/integration-issues/claude-code-action-v1-parameter-migration-2026-03-29.md` — related parameter configuration patterns
- `docs/solutions/integration-issues/claude-code-review-workflow-tool-permissions-2026-03-29.md` — related permission model documentation
