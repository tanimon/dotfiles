---
title: GitHub Actions security alert workflow pitfalls
date: 2026-04-02
category: integration-issues
module: github-actions
problem_type: integration_issue
component: tooling
symptoms:
  - "GITHUB_TOKEN cannot access Dependabot alerts or Secret Scanning alerts API endpoints"
  - "claude-code-action jobs with no timeout-minutes consume runners indefinitely on hang"
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - github-actions
  - security-alerts
  - github-token
  - timeout-minutes
  - dependabot
  - claude-code-action
---

# GitHub Actions security alert workflow pitfalls

## Problem

When building a GitHub Actions workflow to automatically handle security alerts (Dependabot, code scanning, secret scanning) via `claude-code-action`, two CI pipeline issues surfaced: (1) the default `GITHUB_TOKEN` cannot access Dependabot alerts or secret scanning alerts API endpoints, and (2) `claude-code-action` jobs without `timeout-minutes` risk consuming runners indefinitely.

## Symptoms

- `gh api repos/{owner}/{repo}/dependabot/alerts` returns 403 or empty results when using the default `GITHUB_TOKEN`, even with `security-events: read` in workflow permissions
- `gh api repos/{owner}/{repo}/secret-scanning/alerts` similarly fails with `GITHUB_TOKEN`
- `claude-code-action` steps that hang (API latency, service degradation) consume a runner for up to 360 minutes (GitHub's default timeout)

## What Didn't Work

- Setting `security-events: write` in the workflow `permissions:` block does not grant Dependabot or secret scanning API access -- the underlying GitHub Actions App lacks these permissions regardless of the `permissions:` key configuration
- Assuming `GITHUB_TOKEN` would work for all GitHub REST API endpoints related to the repository

## Solution

**For GITHUB_TOKEN limitation:**

Add `2>/dev/null || echo "0"` fallback for API calls that may fail due to token limitations. For full functionality, create a fine-grained Personal Access Token (PAT) with "Dependabot alerts: Read and write" and "Secret scanning alerts: Read and write" permissions, scoped to the specific repository. Store as a repository secret (e.g., `SECURITY_PAT`).

Note: `GITHUB_TOKEN` DOES work for code scanning alerts with `security-events: read/write`.

| Alert Type | GITHUB_TOKEN works? | Required |
|---|---|---|
| Dependabot alerts | No | Fine-grained PAT with "Dependabot alerts" permission |
| Code scanning alerts | Yes | `security-events: read` in workflow permissions |
| Secret scanning alerts | No | Fine-grained PAT with "Secret scanning alerts" permission |

**For timeout-minutes:**

Add `timeout-minutes` to every job that calls `claude-code-action`:

```yaml
jobs:
  dependabot:
    runs-on: ubuntu-latest
    timeout-minutes: 30  # Prevent indefinite runner consumption
    # ...
```

Use shorter timeouts for simpler jobs (e.g., `timeout-minutes: 15` for secret-scanning which only creates issues).

## Why This Works

The `GITHUB_TOKEN` limitation is a known GitHub platform constraint (see [community discussion #60612](https://github.com/orgs/community/discussions/60612)). The GitHub Actions App that generates `GITHUB_TOKEN` does not include Dependabot alerts or secret scanning alerts in its permission set. A fine-grained PAT bypasses this by granting permissions directly to the user/app level.

The `timeout-minutes` fix prevents resource waste by ensuring jobs fail cleanly rather than hanging. GitHub's default timeout is 360 minutes (6 hours), which is excessive for an AI-assisted remediation job.

## Prevention

- Always add `timeout-minutes` to jobs that call external AI services (`claude-code-action`, LLM APIs)
- When designing workflows that access security-related GitHub APIs, verify which endpoints work with `GITHUB_TOKEN` vs require a PAT
- Use `2>/dev/null || echo "0"` fallback pattern for API calls that may fail due to token limitations, ensuring the workflow degrades gracefully
- Consider a scheduled sweep job as a safety net for webhook events that may be missed

## Related Issues

- [GitHub issue #85](https://github.com/tanimon/dotfiles/issues/85) -- Original feature request
- [GitHub community discussion #60612](https://github.com/orgs/community/discussions/60612) -- GITHUB_TOKEN limitation documentation
- [claude-code-review-workflow-tool-permissions](./claude-code-review-workflow-tool-permissions-2026-03-29.md) -- Related two-layer permission model for claude-code-action
