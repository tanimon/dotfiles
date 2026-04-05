---
id: workflow-error-investigation-order
trigger: when investigating GitHub Actions workflow failures
confidence: 0.7
domain: debugging
tags: [github-actions, debugging]
created: "2026-04-06"
---

# Workflow Error Investigation Order

When a GitHub Actions workflow fails:

1. **`gh run list --workflow=<name>.yml`** — Get recent run IDs and their status/conclusion
2. **`gh run view <id> --log-failed`** — See only the failed step logs (much faster than full logs)
3. **`gh run view --job=<job-id> --log`** with grep — Filter for specific error patterns
4. **Check the workflow source** — `git log --oneline -5 -- .github/workflows/<name>.yml` to see recent changes
5. **Compare with previous working version** — `git show <sha>:.github/workflows/<name>.yml`
6. **Test locally** — Run the same API calls or commands locally to isolate the issue

Avoid reading full workflow logs without filtering — they can be massive. Always grep for error keywords first.
