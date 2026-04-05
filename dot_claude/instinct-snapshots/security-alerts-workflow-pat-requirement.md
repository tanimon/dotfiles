---
id: security-alerts-workflow-pat-requirement
trigger: when working on the security-alerts.yml workflow or any workflow that accesses Dependabot/code-scanning/secret-scanning APIs
confidence: 0.75
domain: workflow
tags: [github-actions, security, pat]
created: "2026-04-06"
---

# Security Alerts Workflow Requires PAT for Dependabot API

The GitHub REST API for Dependabot alerts (`/repos/{owner}/{repo}/dependabot/alerts`) returns 403 when accessed with GITHUB_TOKEN, even with `security-events: read` permission. This is a GitHub platform limitation.

**Solution:** Pre-fetch security alerts using a PAT in a separate job step, then pass the data to claude-code-action via environment variables or files. This avoids giving the PAT directly to the AI agent.

**Key pattern from `.github/workflows/security-alerts.yml`:**
1. Step 1: Use PAT to call GitHub APIs and collect alert data
2. Step 2: Pass pre-fetched data as context to claude-code-action (which uses GITHUB_TOKEN)

This separation follows the principle of least privilege — the PAT is used only for the specific API calls that need it.
