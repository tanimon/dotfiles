---
title: GitHub App bot author_association is always NONE — workflow silently skips
date: 2026-03-30
category: integration-issues
module: .github/workflows/harness-auto-remediate.yml
problem_type: integration_issue
component: development_workflow
symptoms:
  - harness-auto-remediate workflow always skipped on harness-analysis labeled issues
  - github.event.sender.author_association is NONE for claude[bot]
  - auto-remediation pipeline never triggered despite issues being created correctly
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - github-actions
  - author-association
  - github-app-bot
  - harness-auto-remediate
  - claude-code-action
  - silent-failure
---

# GitHub App bot author_association is always NONE — workflow silently skips

## Problem

The `harness-auto-remediate.yml` workflow was always skipped when triggered by `harness-analysis` labeled issues because the sender (`claude[bot]`) has `author_association: NONE`, which failed the security guard that only allowed `OWNER`, `MEMBER`, or `COLLABORATOR`.

## Symptoms

- The auto-remediate workflow never ran despite `harness-analysis` labeled issues being created correctly by the scheduled harness-analysis workflow
- GitHub Actions run history showed the workflow status as "skipped" every time
- Querying the run via `gh api repos/.../actions/runs/<id> --jq '{conclusion, triggering_actor: .triggering_actor.login}'` returned `{"conclusion":"skipped","triggering_actor":"claude[bot]"}`
- Querying issue metadata confirmed `author_association: NONE` for all bot-created issues

## What Didn't Work

- **Adding `NONE` to allowed `author_association` values** -- Rejected because it would allow any external or untrusted user to trigger the workflow by labeling an issue, defeating the security guard entirely.
- **Checking `sender.type == 'Bot'`** -- Rejected as too broad; any GitHub App bot (including potentially unwanted ones) would pass the check.
- **Using a PAT instead of `GITHUB_TOKEN`** -- Rejected as overengineered; switching the token used by `claude-code-action` to a PAT would make the sender appear as a human user, but introduces secret management overhead for no real benefit.

## Solution

Add an explicit login check for `claude[bot]` as an OR alternative to the existing `author_association` guard.

**Before:**
```yaml
if: |
  (github.event_name == 'workflow_dispatch') ||
  (github.event_name == 'issues' &&
   github.event.label.name == 'harness-analysis' &&
   contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.sender.author_association))
```

**After:**
```yaml
if: |
  (github.event_name == 'workflow_dispatch') ||
  (github.event_name == 'issues' &&
   github.event.label.name == 'harness-analysis' &&
   (contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.sender.author_association) ||
    github.event.sender.login == 'claude[bot]'))
```

## Why This Works

GitHub App bots (like `claude[bot]` from `claude-code-action`) always have `author_association: NONE` regardless of the permissions granted to the app. They are not repository members, collaborators, or owners in the GitHub permission model -- they operate via installation tokens. The fix explicitly allows the known bot identity while keeping the `author_association` guard for all other senders, so untrusted external users still cannot trigger the workflow.

## Prevention

- **Document bot identity assumptions** -- When a GitHub Actions workflow is triggered by actions performed by a GitHub App (via `claude-code-action`, Renovate, Dependabot, etc.), document that the sender will be the app's bot account with `author_association: NONE`. Add a comment in the workflow explaining why the bot login is allowlisted.
- **Test workflow conditions with actual trigger data** -- After adding security guards to workflows, verify them by inspecting the actual event payload (`gh api repos/.../actions/runs/<id> --jq '.triggering_actor'`) rather than assuming sender properties.
- **Prefer sender login allowlists over type checks for bots** -- `sender.type == 'Bot'` is too broad. Use `sender.login == '<specific-bot>'` to allowlist only the intended bot identity.
- **Silent failure pattern** -- GitHub Actions `if` conditions that evaluate to `false` silently skip the job with no error or warning. Always verify new `if` guards by triggering the workflow and checking the run status.

## Related Issues

- [github-actions-expression-in-operator-does-not-exist-2026-03-29.md](github-actions-expression-in-operator-does-not-exist-2026-03-29.md) -- Another silent failure pattern with GitHub Actions expressions and `author_association` checks
- [claude-code-action-v1-parameter-migration-2026-03-29.md](claude-code-action-v1-parameter-migration-2026-03-29.md) -- Silent failure from deprecated `claude-code-action` parameters
- [claude-code-review-workflow-tool-permissions-2026-03-29.md](claude-code-review-workflow-tool-permissions-2026-03-29.md) -- Bot permissions in GitHub Actions workflows
- PR: https://github.com/tanimon/dotfiles/pull/101
