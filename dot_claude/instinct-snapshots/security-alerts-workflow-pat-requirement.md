---
id: security-alerts-workflow-pat-requirement
trigger: when working on the security-alerts.yml workflow or any workflow that accesses Dependabot/code-scanning/secret-scanning APIs
confidence: 0.75
domain: workflow
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# Security Alerts Workflow Uses GitHub App Token for Dependabot and Secret Scanning APIs

## Action
The GitHub REST API for Dependabot alerts (`/repos/{owner}/{repo}/dependabot/alerts`) returns 403 when accessed with `GITHUB_TOKEN`, even with `security-events: read` permission. In this repository, the workflow addresses that limitation by generating a GitHub App token for Dependabot and secret-scanning API access, while code scanning continues to use `GITHUB_TOKEN`.

**Solution:** Pre-fetch security alerts in a separate job step using a GitHub App token created via `actions/create-github-app-token`, then pass the data to `claude-code-action` via environment variables or files. This avoids giving the elevated GitHub App token directly to the AI agent.

**Key pattern from `.github/workflows/security-alerts.yml`:**
1. Step 1: Use a GitHub App token to call the Dependabot and secret-scanning APIs and collect alert data
2. Step 2: Pass pre-fetched data as context to `claude-code-action` (which uses `GITHUB_TOKEN`)

This separation follows the principle of least privilege — the GitHub App token is used only for the specific API calls that need elevated access, while the downstream action continues using `GITHUB_TOKEN`.

## Evidence
- Observed during security-alerts.yml debugging when GITHUB_TOKEN returned 403 for Dependabot API (2026-04-05)
- Workflow migrated from PAT to GitHub App token via `actions/create-github-app-token` in PR #147
- Last observed: 2026-04-05
