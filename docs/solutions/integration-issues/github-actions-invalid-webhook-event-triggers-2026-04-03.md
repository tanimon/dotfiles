---
title: GitHub Actions workflow fails silently when using webhook event names as workflow triggers
date: 2026-04-03
category: integration-issues
module: ci
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "security-alerts.yml workflow fails on every push with 'Unexpected value' errors"
  - "GitHub Actions run page shows 'This run likely failed because of a workflow file issue' with 0 jobs"
  - "actionlint passes locally because .github/actionlint.yaml suppresses the warnings"
  - "Three event-triggered jobs never execute since the workflow was added"
root_cause: config_error
resolution_type: config_change
tags:
  - github-actions
  - workflow-triggers
  - webhook-events
  - actionlint
  - security-alerts
  - ci-pipeline
---

# GitHub Actions workflow fails silently when using webhook event names as workflow triggers

## Problem

The `security-alerts.yml` GitHub Actions workflow used `dependabot_alert`, `code_scanning_alert`, and `secret_scanning_alert` as `on:` triggers. These names exist as GitHub webhook events but are NOT valid GitHub Actions workflow trigger events. GitHub Actions rejected the workflow file on every push, producing zero jobs and a cryptic "workflow file issue" error. Additionally, `.github/actionlint.yaml` ignore rules suppressed the actionlint warnings for these invalid events, masking the problem from both local and CI lint checks.

## Symptoms

- Every push to `main` triggers the workflow but produces **zero jobs**; the run page shows only "This run likely failed because of a workflow file issue"
- `gh run view <id>` shows `Triggered via push` with `jobs: []` (empty)
- GitHub Actions error (visible on the web UI): `Invalid workflow file: (Line: 4, Col: 3): Unexpected value 'dependabot_alert'`
- `actionlint` passes locally — `.github/actionlint.yaml` contains ignore rules for `unknown Webhook event "dependabot_alert"` etc.
- The three event-triggered jobs (`dependabot`, `code-scanning`, `secret-scanning`) never executed since the workflow was created

## What Didn't Work

- **Running actionlint locally** — appeared clean because `.github/actionlint.yaml` silently suppressed the `unknown Webhook event` warnings. This gave false confidence that the workflow was valid.
- **Assuming webhook event names work as Actions triggers** — the names `dependabot_alert`, `code_scanning_alert`, and `secret_scanning_alert` exist in GitHub's webhook event namespace, which led to the assumption they could be used in the `on:` block of a workflow file. They cannot.
- **Checking `gh run view`** — shows the run failed but does not include the specific "Unexpected value" error message. The error is only visible on the GitHub Actions web UI via annotations.

## Solution

Removed the three invalid event triggers and their associated dead jobs. Kept only the `sweep` job which already handled all alert types via `schedule` and `workflow_dispatch`. Also removed the stale actionlint suppressions.

**Before** (`.github/workflows/security-alerts.yml`):
```yaml
on:
  dependabot_alert:
    types: [created, reopened]
  code_scanning_alert:
    types: [created, reopened]
  secret_scanning_alert:
    types: [created]
  schedule:
    - cron: "0 0 * * 6"
  workflow_dispatch:
```

**After**:
```yaml
on:
  schedule:
    - cron: "0 0 * * 6"
  workflow_dispatch:
```

**Before** (`.github/actionlint.yaml`):
```yaml
paths:
  .github/workflows/security-alerts.yml:
    ignore:
      - 'unknown Webhook event "dependabot_alert"'
      - 'unknown Webhook event "code_scanning_alert"'
      - 'unknown Webhook event "secret_scanning_alert"'
```

**After**: Removed all three ignore patterns (`paths: {}`).

Also removed the three dead jobs (`dependabot`, `code-scanning`, `secret-scanning`) that could never execute (~260 lines), and removed the always-true `if` condition from the `sweep` job.

## Why This Works

GitHub Actions workflow triggers (`on:` block) and GitHub webhook events are **different namespaces**. A name that exists as a webhook event does NOT necessarily work as an Actions workflow trigger. GitHub Actions validates the `on:` block at workflow parse time and rejects unrecognized event names, preventing **all** jobs in the file from running — even valid ones like the `sweep` job.

The `sweep` job already queried all three alert types (Dependabot, code scanning, secret scanning) via `gh api`, making the event-triggered jobs redundant. Removing the actionlint suppressions restores the lint tool's ability to catch similar invalid-event issues in the future.

## Prevention

- **Never suppress actionlint `unknown Webhook event` warnings without verifying the event is actually valid as an Actions trigger** — consult the [GitHub Actions events documentation](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows), not the webhook events documentation
- **Verify new workflows produce at least one job** after the first push — a workflow with 0 jobs on every trigger is a signal of a file-level validation error
- **Review actionlint suppressions periodically** — each entry in `.github/actionlint.yaml` should have a clear justification, and suppressions that mask real errors should be removed
- **Check the GitHub Actions web UI** for workflow file errors — `gh run view` does not surface "Unexpected value" annotations; the error is only visible on the web run page

## Related Issues

- `docs/solutions/developer-experience/github-actions-workflow-linting-actionlint-zizmor-2026-04-03.md` — contains now-incorrect guidance recommending suppression of these event warnings (needs refresh)
- `docs/solutions/integration-issues/github-actions-security-alert-workflow-pitfalls-2026-04-02.md` — documents other pitfalls in the same workflow (GITHUB_TOKEN limitations)
- `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md` — analogous case of GitHub Actions silently handling invalid syntax
- PR: tanimon/dotfiles#119
