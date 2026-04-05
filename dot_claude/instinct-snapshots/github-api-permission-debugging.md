---
id: github-api-permission-debugging
trigger: when debugging GitHub Actions workflow failures related to API permissions (403 errors, OIDC failures, token scope issues)
confidence: 0.7
domain: debugging
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# GitHub API Permission Debugging Pattern

## Action
When a GitHub Actions workflow fails with permission errors (403, OIDC token failures):

1. **Check the workflow's `permissions:` block first** — GitHub Actions defaults to read-only. Verify the workflow requests the specific permissions needed (e.g., `security-events: read` for code scanning alerts)
2. **Distinguish `GITHUB_TOKEN` vs non-`GITHUB_TOKEN` credentials** — Some GitHub APIs (for example, Dependabot alerts and secret scanning) cannot be accessed with `GITHUB_TOKEN` regardless of workflow permissions, and instead require another credential type such as a PAT or a GitHub App installation token
3. **Use `gh run view --job=<id> --log` to inspect actual API calls** — Filter for error codes and permission-related messages
4. **Check `gh api` locally first** — Test the exact API endpoint with your local token before debugging the workflow
5. **For security-related APIs**, refer to GitHub docs for which token types are supported — in this repo, `.github/workflows/security-alerts.yml` uses a GitHub App installation token for Dependabot + secret scanning, while `GITHUB_TOKEN` is still used for code scanning

## Evidence
- Observed across 3 sessions debugging security-alerts.yml 403 errors (2026-04-05)
- Pattern: GITHUB_TOKEN always fails for Dependabot/secret scanning APIs regardless of permissions block
- Workflow now uses `actions/create-github-app-token` for elevated API access
- Last observed: 2026-04-05
