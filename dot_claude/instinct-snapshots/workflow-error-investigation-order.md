---
id: workflow-error-investigation-order
trigger: when investigating GitHub Actions workflow failures
confidence: 0.7
domain: debugging
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# Workflow Error Investigation Order

## Action
When a GitHub Actions workflow fails:

1. **`gh run list --workflow=<name>.yml`** — Get recent run IDs and their status/conclusion
2. **`gh run view <id> --log-failed`** — See only the failed step logs (much faster than full logs)
3. **`gh run view --job=<job-id> --log`** with grep — Filter for specific error patterns
4. **Check the workflow source** — `git log --oneline -5 -- .github/workflows/<name>.yml` to see recent changes
5. **Compare with previous working version** — `git show <sha>:.github/workflows/<name>.yml`
6. **Test locally** — Run the same API calls or commands locally to isolate the issue

Avoid reading full workflow logs without filtering — they can be massive. Always grep for error keywords first.

## Evidence
- Observed across 3+ sessions debugging security-alerts.yml and harness-analysis.yml (2026-04-05)
- Pattern: Consistently used `gh run view --log-failed` before full logs, saving significant time
- Last observed: 2026-04-05
