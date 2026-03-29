---
title: "Claude Code Review workflow posts no PR comments due to classify_inline_comments filter"
date: 2026-03-29
problem_type: integration_issue
severity: medium
status: resolved
tags:
  - github-actions
  - claude-code-action
  - claude-code-review
  - permissions
  - workflow-configuration
module: ci-cd
component: claude-code-review-workflow
root_cause: >
  classify_inline_comments defaults to true, causing all buffered inline comments
  to be filtered out during classification. Secondary issues included missing
  permissions (actions: read, issues: write) and show_full_output: false hiding
  all diagnostic output.
fix_summary: >
  Set classify_inline_comments: false to bypass comment classification filter.
  Added show_full_output: true for debugging. Added actions: read to workflow
  permissions and additional_permissions. Changed issues: read to issues: write.
related_files:
  - .github/workflows/claude-code-review.yml
  - .github/workflows/claude.yml
related_issues:
  - "#83"
  - "#81"
  - "#68"
---

# Claude Code Review workflow posts no PR comments due to classify_inline_comments filter

## Problem

The Claude Code Review GitHub Actions workflow (`claude-code-action` v1 with `code-review` plugin) completed successfully on PRs but never posted any review comments, silently consuming $0.90-$1.18 per run with no visible output.

## Symptoms

- Workflow runs showed "No buffered inline comments" in logs despite the agent running 17 turns
- Some runs had 11-18 permission denials; others had 0 denials — but none posted comments regardless
- `show_full_output: false` (default) suppressed all diagnostic information, making the failure invisible
- No error messages or failures in the workflow run summary — everything appeared "successful"

### Workflow run data

| Run ID | PR | permission_denials | Cost | Result |
|--------|-----|-------------------|------|--------|
| 23701011894 | #82 (2nd) | **0** | $0.90 | No buffered inline comments |
| 23700930828 | #82 (1st) | 18 | $1.02 | No buffered inline comments |
| 23700528958 | #80 | 11 | $1.18 | No buffered inline comments |

## What Didn't Work

- **Fixing permissions alone was insufficient**: A run with 0 permission denials still produced zero comments, proving permissions were not the only cause
- **Checking plugin configuration**: `plugins`, `plugin_marketplaces`, and `prompt` parameters were all valid and correctly formatted per `action.yml` — the plugin was loading and executing
- **Reviewing workflow run logs**: With `show_full_output: false`, the logs contained almost no actionable information about why comments were being dropped

## Solution

Modified `.github/workflows/claude-code-review.yml` with four changes:

**Permissions block** — added `actions: read` and changed `issues: read` to `issues: write`:

```yaml
# Before
permissions:
  contents: read
  pull-requests: write
  issues: read
  id-token: write

# After
permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write
  actions: read
```

**Action inputs** — added `show_full_output`, `classify_inline_comments`, and `additional_permissions`:

```yaml
# Added these three inputs before the plugin config:
show_full_output: true
classify_inline_comments: false
additional_permissions: |
  actions: read
```

## Why This Works

The root cause was compound — three issues that individually might not have been caught:

1. **`classify_inline_comments: true` (default)** was the primary blocker. This feature buffers all inline comments and runs a classification step before posting. The classification was either dropping all comments or the plugin's output format did not match the buffering system's expectations. Setting it to `false` bypasses the classification pipeline and posts comments directly.

2. **Missing `actions: read`** caused the agent to be denied when trying to read CI check results and workflow artifacts — information the code-review plugin needs. Without `additional_permissions: actions: read`, the inner Claude Code process lacked this permission even when the job-level permission was set.

3. **`issues: read` instead of `issues: write`** may have blocked posting review comments through certain GitHub API paths that require write access.

4. **`show_full_output: false`** compounded everything by hiding all diagnostic output, making it impossible to distinguish "no comments generated" from "comments generated but dropped."

The key debugging insight was comparing the working `claude.yml` (interactive @claude workflow) with the broken `claude-code-review.yml` — the permission differences were immediately visible, and the `classify_inline_comments` default was found by examining the action's `action.yml`.

## Prevention

### Always enable diagnostic output on new workflows

Set `show_full_output: true` on new `claude-code-action` workflows until confirmed working. Debugging silent failures without output is extremely costly (multiple $1+ runs with no feedback).

### Explicitly set classify_inline_comments

Don't rely on the `classify_inline_comments: true` default unless you have verified the classification pipeline works with your specific plugin. The default can silently drop all comments.

### Mirror permissions in additional_permissions

The outer GitHub Actions job permissions and the inner Claude Code process permissions are separate. `actions: read` at job level does not automatically grant it to the Claude Code subprocess — you must also set `additional_permissions: actions: read`.

### Compare with working workflows

When a new workflow doesn't produce expected output, diff its configuration against a working workflow in the same repository. The `claude.yml` vs `claude-code-review.yml` comparison immediately surfaced the permission gaps.

### Verify workflow output before considering it operational

Template-generated workflows need permission auditing — template defaults are read-only (per `~/.claude/rules/common/github-actions.md`). Test new CI workflows with a known-good PR and verify the expected output actually appears.

## Related

- [claude-code-action v1 parameter migration](claude-code-action-v1-parameter-migration-2026-03-29.md) — Same theme of silent workflow failures from configuration issues
- [GitHub Actions `in` operator does not exist](github-actions-expression-in-operator-does-not-exist-2026-03-29.md) — Another silent failure pattern in workflow expressions
- PR #83: fix: resolve Claude Code Review workflow producing no PR comments
- PR #81: fix: allow Renovate and Dependabot in Claude Code Review workflow
- PR #68: ci: add Claude Code GitHub Actions workflows (original introduction)
