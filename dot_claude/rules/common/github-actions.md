---
date: 2026-03-29
trigger: "Agent used invalid in operator or wrong permissions in GitHub Actions workflows"
---

# GitHub Actions Expressions

## Critical: `in` operator does not exist

GitHub Actions expressions do NOT support `in` with array literals. Invalid expressions silently evaluate to `false` — no error, no warning.

**Wrong:** `value in ['A', 'B', 'C']`
**Correct:** `contains(fromJSON('["A", "B", "C"]'), value)`

Always use `contains(fromJSON(...), ...)` for set-membership checks in workflow `if` conditions.

## Permissions

Template-generated workflows (e.g., from `claude-code-action`) default to read-only permissions. Verify permissions match the intended use:

- Posting PR review comments → `pull-requests: write`
- Posting issue comments → `issues: write`
- Reading CI results → `actions: read`

## Security Hardening

When adding workflows to public repositories:

- Pin actions to full commit SHAs (`action@<sha> # vN`), not mutable tags
- Add `author_association` guards to `@mention` triggers
- Add fork PR exclusion guards: `github.event.pull_request.head.repo.full_name == github.repository`
