---
title: "GitHub Actions expression `in` operator does not exist — use contains(fromJSON(...))"
date: "2026-03-29"
category: integration-issues
module: ci-cd
problem_type: integration_issue
component: tooling
symptoms:
  - "GitHub Actions workflow `if` condition with `in` operator silently evaluates to false"
  - "Workflow job never triggers despite matching values"
  - "No syntax error or warning in workflow run logs"
root_cause: wrong_api
resolution_type: code_fix
severity: critical
related_components:
  - development_workflow
tags:
  - github-actions
  - workflow-expressions
  - silent-failure
  - contains-fromjson
  - author-association
  - ci-security
---

# GitHub Actions expression `in` operator does not exist — use contains(fromJSON(...))

## Problem

GitHub Actions workflows using the `in` operator for set-membership checks (e.g., `value in ['A', 'B', 'C']`) silently fail because the `in` operator does not exist in GitHub Actions' expression language. The condition always evaluates to `false` with no error or warning, completely disabling the guarded job.

## Symptoms

- Workflow jobs with `in` operator guards never execute, regardless of the actual input value
- No error or warning appears in the workflow run logs — the `if` condition simply evaluates to `false`
- The workflow appears to "skip" the job as if the condition was intentionally not met
- Particularly dangerous for security gates (e.g., `author_association` checks) — the gate blocks everyone instead of just unauthorized users, which may go unnoticed until someone tries to use the workflow

## What Didn't Work

- Using Python/JavaScript-style `in` operator syntax: `value in ['A', 'B', 'C']`. The expression evaluator accepts this without error but silently returns `false` because the operator is unrecognized.

## Solution

Replace the `in` operator with `contains(fromJSON(...), ...)`.

**Before (broken):**
```yaml
if: github.event.comment.author_association in ['OWNER', 'MEMBER', 'COLLABORATOR']
```

**After (working):**
```yaml
if: contains(fromJSON('["OWNER", "MEMBER", "COLLABORATOR"]'), github.event.comment.author_association)
```

The JSON string must use double quotes for array elements inside single quotes for the YAML string literal.

## Why This Works

GitHub Actions uses a custom expression language with a limited set of operators (`==`, `!=`, `&&`, `||`, `!`, `<`, `<=`, `>`, `>=`) and built-in functions (`contains()`, `startsWith()`, `endsWith()`, `format()`, `join()`, `toJSON()`, `fromJSON()`, `hashFiles()`). It is neither JavaScript nor Python. The `in` operator does not exist. Rather than raising a syntax error, the evaluator silently returns `false` for unrecognized expressions.

`fromJSON()` parses a JSON string literal into an actual array at evaluation time, and `contains()` checks membership in that array — together they replicate the `in` operator's intended behavior using only supported primitives.

## Prevention

- **Harness rule**: GitHub Actions expressions do not support the `in` operator. For set-membership checks, always use `contains(fromJSON('["val1", "val2"]'), expression)`.
- **Code review**: Any PR modifying workflow `if` conditions should be verified against the [GitHub Actions expressions documentation](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/evaluate-expressions-in-a-workflow).
- **Test workflow changes**: Since invalid expressions fail silently, always trigger a test run of modified workflows to verify that `if` conditions evaluate to `true` when expected.
- **Linting**: Consider `actionlint` (a static checker for GitHub Actions) which catches unsupported expression syntax before commit.

## Related Issues

- `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md` — CI setup for this repo (cross-reference for GitHub Actions workflow configuration)
- `docs/solutions/integration-issues/renovate-managerfilepatterns-regex-delimiter.md` — Similar "silent syntax misinterpretation" gotcha pattern with Renovate
- PR: tanimon/dotfiles#68 — Original PR where this was discovered
