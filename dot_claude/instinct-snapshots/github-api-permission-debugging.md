---
id: github-api-permission-debugging
trigger: when debugging GitHub Actions workflow failures related to API permissions (403 errors, OIDC failures, token scope issues)
confidence: 0.7
domain: debugging
tags: [github-actions, security, permissions]
created: "2026-04-06"
---

# GitHub API Permission Debugging Pattern

When a GitHub Actions workflow fails with permission errors (403, OIDC token failures):

1. **Check the workflow's `permissions:` block first** — GitHub Actions defaults to read-only. Verify the workflow requests the specific permissions needed (e.g., `security-events: read` for code scanning alerts)
2. **Distinguish GITHUB_TOKEN vs PAT scope** — Some GitHub APIs (Dependabot alerts, secret scanning) require a PAT with specific scopes; GITHUB_TOKEN cannot access them regardless of workflow permissions
3. **Use `gh run view --job=<id> --log` to inspect actual API calls** — Filter for error codes and permission-related messages
4. **Check `gh api` locally first** — Test the exact API endpoint with your local token before debugging the workflow
5. **For security-related APIs**, refer to GitHub docs for which token types are supported — the answer is often "PAT only"
