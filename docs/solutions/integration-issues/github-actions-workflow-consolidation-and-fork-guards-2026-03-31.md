---
title: GitHub Actions workflow consolidation with conditional steps and fork PR guards
date: 2026-03-31
category: integration-issues
module: github-actions
problem_type: workflow_issue
component: development_workflow
severity: medium
applies_when:
  - Multiple GitHub Actions workflows share identical configuration but differ in conditional logic
  - Workflows triggered by PR events need fork PR exclusion guards
  - Event payload structure varies across trigger types (issue_comment vs pull_request_review)
tags:
  - github-actions
  - workflow-consolidation
  - fork-pr-guard
  - conditional-steps
  - claude-code-action
  - event-payload
---

# GitHub Actions workflow consolidation with conditional steps and fork PR guards

## Context

Two GitHub Actions workflows (`claude.yml` and `claude-code-review.yml`) shared nearly identical configuration — same action (`anthropics/claude-code-action`), permissions, OAuth token, and checkout step. The only difference was the review workflow added plugin configuration and a custom prompt when `/review` appeared in a PR comment. Maintaining two near-duplicate files created unnecessary drift risk. Additionally, neither workflow had fork PR exclusion guards, allowing workflows to potentially run on untrusted fork PR code.

## Guidance

### Consolidate with step-level `if` conditions

Merge workflows that differ only in conditional logic into a single workflow. Use an early detection step to set a flag, then branch with mutually exclusive step conditions:

```yaml
steps:
  - name: Detect review mode
    id: mode
    if: |
      (github.event_name == 'issue_comment' &&
        github.event.issue.pull_request &&
        contains(github.event.comment.body, '/review')) ||
      (github.event_name == 'pull_request_review_comment' &&
        contains(github.event.comment.body, '/review')) ||
      (github.event_name == 'pull_request_review' &&
        contains(github.event.review.body, '/review'))
    run: echo "is_review=true" >> "$GITHUB_OUTPUT"

  - name: Run normal mode
    if: steps.mode.outputs.is_review != 'true'
    uses: some-action@sha
    with: { ... }

  - name: Run review mode
    if: steps.mode.outputs.is_review == 'true'
    uses: some-action@sha
    with: { ... review-specific config ... }
```

When the detection step's `if` condition is false, the step is skipped and `steps.mode.outputs.is_review` is undefined (empty string). The `!= 'true'` / `== 'true'` pattern handles this correctly — undefined is not equal to `'true'`.

### Add fork PR exclusion guards

Add `github.event.pull_request.head.repo.full_name == github.repository` to job-level conditions for events where the full PR object is available:

```yaml
(github.event_name == 'pull_request_review_comment' &&
  contains(github.event.comment.body, '@claude') &&
  contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association) &&
  github.event.pull_request.head.repo.full_name == github.repository)
```

### Critical caveat: `issue_comment` payload limitation

**`issue_comment` events do NOT include `github.event.pull_request.head.repo.full_name`** in the payload. The `github.event.issue.pull_request` field is a minimal object containing only URL pointers (`url`, `html_url`, `diff_url`, `patch_url`). Fork guards using `head.repo.full_name` can therefore only be applied to:

- `pull_request_review_comment` — full `github.event.pull_request` object available
- `pull_request_review` — full `github.event.pull_request` object available

For `issue_comment` events, `author_association` checks (`OWNER`, `MEMBER`, `COLLABORATOR`) remain the primary defense against unauthorized fork PR triggers.

## Why This Matters

- **Reduced maintenance**: Single workflow means changes apply everywhere, no drift between duplicate files
- **Security**: Fork guards prevent workflows from executing on code from untrusted forks, blocking potential token leakage
- **Silent failure risk**: GitHub Actions expressions referencing nonexistent payload fields evaluate to empty/falsy without error. If you add `github.event.pull_request.head.repo.full_name` to an `issue_comment` condition, it silently evaluates to false and the job never runs — with no warning

## When to Apply

- Multiple workflows share event triggers, permissions, and action configuration but differ in conditional logic
- Any workflow using OAuth tokens or secrets that can be triggered by PR events
- When adding new event types to an existing workflow — verify which payload fields are available before writing conditions

## Examples

**Before** — two separate workflow files:

```
.github/workflows/claude.yml          # Triggered by @claude mentions
.github/workflows/claude-code-review.yml  # Triggered by /review on PRs
```

Both files: same action SHA, same permissions block, same OAuth token, same checkout step.

**After** — single workflow with conditional steps:

```
.github/workflows/claude.yml
  └─ job: claude
       ├─ step: Checkout
       ├─ step: Detect review mode (id: mode)
       ├─ step: Run Claude Code       (if: is_review != 'true')
       └─ step: Run Claude Code Review (if: is_review == 'true')
```

Fork guards applied to `pull_request_review_comment` and `pull_request_review` conditions at job level. `issue_comment` protected by `author_association` check only.

## Related

- [claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md](claude-code-review-no-pr-comments-classify-inline-filter-2026-03-29.md) — Review workflow `classify_inline_comments` and permission troubleshooting
- [claude-code-review-workflow-tool-permissions-2026-03-29.md](claude-code-review-workflow-tool-permissions-2026-03-29.md) — Two-layer permission model (`additional_permissions` + `claude_args --allowedTools`)
- [github-actions-bot-author-association-bypass-2026-03-30.md](github-actions-bot-author-association-bypass-2026-03-30.md) — Bot `author_association` is always NONE
- [claude-code-action-v1-parameter-migration-2026-03-29.md](claude-code-action-v1-parameter-migration-2026-03-29.md) — v1 parameter names (`prompt`, `claude_args`)
- PR: tanimon/dotfiles#104
