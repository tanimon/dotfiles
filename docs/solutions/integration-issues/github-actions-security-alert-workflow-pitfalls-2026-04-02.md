---
title: GitHub Actions security alert workflow pitfalls
date: 2026-04-02
last_updated: 2026-04-13
category: integration-issues
module: github-actions
problem_type: integration_issue
component: tooling
symptoms:
  - "GITHUB_TOKEN cannot access Dependabot alerts or Secret Scanning alerts API endpoints"
  - "claude-code-action jobs with no timeout-minutes consume runners indefinitely on hang"
  - "Agent completes successfully but creates 0 issues despite open alerts due to silent error suppression"
root_cause: config_error
resolution_type: config_change
severity: high
tags:
  - github-actions
  - security-alerts
  - github-token
  - timeout-minutes
  - dependabot
  - claude-code-action
  - error-suppression
  - silent-failure
---

# GitHub Actions security alert workflow pitfalls

## Problem

When building a GitHub Actions workflow to automatically handle security alerts (Dependabot, code scanning, secret scanning) via `claude-code-action`, three CI pipeline issues surfaced: (1) the default `GITHUB_TOKEN` cannot access Dependabot alerts or secret scanning alerts API endpoints, (2) `claude-code-action` jobs without `timeout-minutes` risk consuming runners indefinitely, and (3) using `2>/dev/null || echo "0"` to handle API failures silently swallows permission errors, causing the agent to believe there are 0 alerts when access is denied.

## Symptoms

- `gh api repos/{owner}/{repo}/dependabot/alerts` returns 403 or empty results when using the default `GITHUB_TOKEN`, even with `security-events: read` in workflow permissions
- `gh api repos/{owner}/{repo}/secret-scanning/alerts` similarly fails with `GITHUB_TOKEN`
- `claude-code-action` steps that hang (API latency, service degradation) consume a runner for up to 360 minutes (GitHub's default timeout)
- Workflow completes successfully (green check) but creates 0 issues despite open alerts — step summary shows "all alerts handled or already tracked" with 0 alert counts across all categories
- With `show_full_output: false`, the agent conversation is hidden, making it difficult to diagnose why the agent did nothing

## What Didn't Work

- Setting `security-events: write` in the workflow `permissions:` block does not grant Dependabot or secret scanning API access -- the underlying GitHub Actions App lacks these permissions regardless of the `permissions:` key configuration
- Assuming `GITHUB_TOKEN` would work for all GitHub REST API endpoints related to the repository
- Using `2>/dev/null || echo "0"` as a universal API fallback -- this hides permission errors (403) alongside expected "feature not enabled" errors (404), causing the agent to silently skip all alerts. The Generate Summary step using the same pattern reinforced the false impression by showing 0 for all counts
- Trusting the step summary as diagnostic truth when it also uses error-swallowing patterns

## Solution

**For GITHUB_TOKEN limitation (updated 2026-04-06):**

Use a dedicated **GitHub App** with `actions/create-github-app-token` to generate short-lived installation tokens with the required permissions. This is preferred over a fine-grained PAT because tokens auto-expire, don't depend on a personal account, and require no manual rotation.

| Alert Type | GITHUB_TOKEN works? | Recommended token |
|---|---|---|
| Dependabot alerts | No | GitHub App with `dependabot_alerts: read` |
| Code scanning alerts | Yes | `github.token` with `security-events: read` |
| Secret scanning alerts | No | GitHub App with `secret_scanning_alerts: read` |

**Pre-fetch pattern**: Gather alert data in a dedicated step before the `claude-code-action` agent, using the appropriate token per API:

```yaml
- name: Check GitHub App availability
  id: check-app
  env:
    APP_ID: ${{ secrets.SECURITY_APP_ID }}
  run: |
    if [ -n "$APP_ID" ]; then
      echo "available=true" >> "$GITHUB_OUTPUT"
    else
      echo "available=false" >> "$GITHUB_OUTPUT"
    fi

- name: Generate security alerts token
  if: steps.check-app.outputs.available == 'true'
  id: app-token
  uses: actions/create-github-app-token@v3
  with:
    app-id: ${{ secrets.SECURITY_APP_ID }}
    private-key: ${{ secrets.SECURITY_APP_PRIVATE_KEY }}
    # v3 uses individual permission-* inputs (not a permissions JSON blob)
    permission-vulnerability-alerts: read
    permission-secret-scanning-alerts: read

- name: Gather security alerts
  env:
    APP_TOKEN: ${{ steps.app-token.outputs.token }}
    GH_DEFAULT_TOKEN: ${{ github.token }}
  run: |
    # Use App token for Dependabot/Secret Scanning, github.token for code-scanning
    # When APP_TOKEN is empty (secrets not configured), skip restricted APIs gracefully
    dep=$(GH_TOKEN="$APP_TOKEN" gh api repos/.../dependabot/alerts ...)
    cs=$(GH_TOKEN="$GH_DEFAULT_TOKEN" gh api repos/.../code-scanning/alerts ...)
    ss=$(GH_TOKEN="$APP_TOKEN" gh api repos/.../secret-scanning/alerts ...)
    # Write to /tmp/security-alerts.json for the agent to read
```

**Note on `create-github-app-token` versions:** v2 accepted a `permissions` JSON input, but v3 replaced it with individual `permission-*` inputs (e.g., `permission-vulnerability-alerts: read`). Using the old `permissions` JSON in v3 produces a warning and the permissions are silently ignored.

The agent reads pre-fetched data from a file instead of calling APIs directly, avoiding token permission issues entirely. Skip the agent step if no alerts are found (cost savings).

**Setup:** Create a GitHub App with `dependabot_alerts: read` + `secret_scanning_alerts: read`, install on the repository, and store App ID and private key as repository secrets (`SECURITY_APP_ID`, `SECURITY_APP_PRIVATE_KEY`).

**Alternative (PAT):** A fine-grained Personal Access Token with "Dependabot alerts: Read" and "Secret scanning alerts: Read" also works but requires manual rotation and is tied to a personal account.

**For silent error suppression (updated 2026-04-06):**

Do NOT use `2>/dev/null || echo "0"` as a universal fallback for API calls. This pattern hides permission errors (403) alongside expected "feature not enabled" errors (404). Instead, let errors be visible and handle them explicitly:

In **agent prompts**, remove error suppression entirely and instruct the agent to check for and report errors:

```yaml
# BAD: silently swallows all errors including permission denied
gh api repos/.../dependabot/alerts --jq '...' 2>/dev/null || echo "0"

# GOOD: let the agent see and report errors
gh api repos/.../dependabot/alerts --jq '...'
# Add to prompt: "If an API returns an error, report it — do NOT silently skip"
```

In **shell steps** (e.g., Generate Summary), capture stderr and report error state:

```bash
# BAD: hides all errors
dep_count=$(gh api .../dependabot/alerts --jq '...' 2>/dev/null || echo "0")

# GOOD: surfaces errors in summary
dep_count=$(gh api .../dependabot/alerts --jq '...' 2>&1) || dep_count="error"

# BEST: distinguish error types
result=$(gh api .../code-scanning/alerts 2>&1) || {
  case "$result" in
    *"404"*) result="0" ;;  # Feature not enabled (expected)
    *) result="error: $result" ;;  # Permission denied (report)
  esac
}
```

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

The `GITHUB_TOKEN` limitation is a known GitHub platform constraint (see [community discussion #60612](https://github.com/orgs/community/discussions/60612)). The GitHub Actions App that generates `GITHUB_TOKEN` does not include Dependabot alerts or secret scanning alerts in its permission set. A dedicated GitHub App bypasses this by providing its own installation token with the required permissions. The `claude-code-action` OIDC-exchanged token also lacks these permissions — the Claude Code GitHub App's installation scope does not include security alert access.

The `2>/dev/null || echo "0"` pattern was originally designed to handle a legitimate case: the code-scanning API returns 404 when the feature is not enabled. However, applying the same pattern to all alert APIs also suppresses 403 (permission denied) errors. When the OIDC-exchanged token or `GITHUB_TOKEN` lacks sufficient permissions, every `gh api` call fails silently, and the `|| echo "0"` fallback makes all counts appear as zero. The agent or shell script sees "0 alerts" for every category and concludes nothing needs processing — a success state that masks complete failure. By removing error suppression from agent prompts and using `2>&1` capture in shell steps, permission problems become visible rather than masquerading as empty results.

The `timeout-minutes` fix prevents resource waste by ensuring jobs fail cleanly rather than hanging. GitHub's default timeout is 360 minutes (6 hours), which is excessive for an AI-assisted remediation job.

## Prevention

- Always add `timeout-minutes` to jobs that call external AI services (`claude-code-action`, LLM APIs)
- When designing workflows that access security-related GitHub APIs, verify which endpoints work with `GITHUB_TOKEN` vs require a dedicated GitHub App token
- **Pre-fetch data with the right token** before the agent step — agents should read from files, not call restricted APIs directly. Use per-API token selection: `github.token` for code-scanning, App token for Dependabot/Secret Scanning
- **Never use `2>/dev/null || echo "0"` as a universal fallback for API calls** — distinguish between "feature not enabled" (expected 404) and "permission denied" (unexpected 403). Use explicit error reporting so failures are visible to both agents and human reviewers
- In agent prompts, let API commands run without error suppression and instruct the agent to check for and report errors. Agents are better at handling errors when they can see them
- In shell scripts (summary steps, diagnostics), capture stderr with `2>&1` and set error state variables rather than discarding errors to `/dev/null`
- Enable `show_full_output: true` during development of `claude-code-action` workflows to see the agent's reasoning; disable only after the workflow is proven stable
- Consider a scheduled sweep job as a safety net for webhook events that may be missed

## Related Issues

- [GitHub issue #85](https://github.com/tanimon/dotfiles/issues/85) -- Original feature request
- [GitHub community discussion #60612](https://github.com/orgs/community/discussions/60612) -- GITHUB_TOKEN limitation documentation
- [claude-code-review-workflow-tool-permissions](./claude-code-review-workflow-tool-permissions-2026-03-29.md) -- Related two-layer permission model for claude-code-action
- [github-actions-invalid-webhook-event-triggers](./github-actions-invalid-webhook-event-triggers-2026-04-03.md) -- Prior silent failure in the same workflow (invalid triggers)
- [chezmoi-scripts-deployment-gap-repo-only-vs-deployed](./chezmoi-scripts-deployment-gap-repo-only-vs-deployed-2026-04-04.md) -- Analogous `|| true` error suppression anti-pattern
- [PR #145](https://github.com/tanimon/dotfiles/pull/145) -- Fix that removed silent error suppression from security-alerts.yml
- [PR #147](https://github.com/tanimon/dotfiles/pull/147) -- Pre-fetch alerts with GitHub App token to bypass GITHUB_TOKEN limitation
