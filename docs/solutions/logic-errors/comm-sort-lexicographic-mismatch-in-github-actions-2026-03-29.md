---
title: "comm requires lexicographic sort — sort -n causes silent incorrect results"
date: "2026-03-29"
category: logic-errors
module: .github/workflows/harness-analysis.yml
problem_type: logic_error
component: tooling
symptoms:
  - "comm -23 produces incorrect diff when issue numbers span different digit lengths"
  - "sort -n gives numeric order (9, 10) but comm requires lexicographic order (10, 9)"
  - "Generate summary step fails when prior step did not create /tmp/issues-before.txt"
root_cause: logic_error
resolution_type: code_fix
severity: medium
tags:
  - github-actions
  - comm
  - sort
  - lexicographic-vs-numeric
  - shell-scripting
  - if-always-guard
---

# comm requires lexicographic sort — sort -n causes silent incorrect results

## Problem

A GitHub Actions workflow using `comm -23` to compute the set difference of issue IDs (before vs after) produced incorrect results because the input files were sorted with `sort -n` (numeric order), which is incompatible with `comm`'s requirement for lexicographic order. A secondary bug left the workflow vulnerable to failure when an upstream step didn't create the expected snapshot file.

## Symptoms

- False positives: existing issues incorrectly reported as newly created
- False negatives: genuinely new issues silently omitted from the summary
- Intermittent workflow failures in the summary step when the before-snapshot step failed, because `comm` tried to read a nonexistent file under `bash -e`

## What Didn't Work

```bash
# Both before and after snapshots used sort -n (numeric sort)
gh issue list --json number --jq '.[].number' | sort -n > /tmp/issues-before.txt

# comm expects lexicographic order, not numeric order
comm -23 /tmp/issues-after.txt /tmp/issues-before.txt
```

`sort -n` produces `9, 10, 100` while `comm` expects lexicographic order `10, 100, 9`. The mismatch causes `comm` to silently produce wrong output — POSIX spec states behavior is undefined on non-lexicographically-sorted input.

Additionally, the summary step used `if: always()` but depended on `/tmp/issues-before.txt` existing from a prior step. If that step failed, `comm` would abort.

## Solution

```bash
# Use plain sort (lexicographic) — correct for comm
gh issue list --json number --jq '.[].number' | sort > /tmp/issues-before.txt

# In the summary step: guard for missing file before comm
touch /tmp/issues-before.txt
comm -23 /tmp/issues-after.txt /tmp/issues-before.txt
```

## Why This Works

`comm` performs a line-by-line merge comparison that assumes LC_COLLATE lexicographic ordering. `sort` without flags produces exactly this ordering. `sort -n` reorders lines by numeric value, which diverges for multi-digit numbers, making `comm`'s merge algorithm walk the two files out of sync.

The `touch` guard ensures the before-file always exists — an empty file is semantically correct ("no prior issues known"), so all issues in the after-file are treated as new, which is the safe default when the baseline is unavailable.

## Prevention

- **Rule**: `comm` always requires plain `sort` (lexicographic). Never pair `comm` with `sort -n`, `sort -V`, or `sort -k`. If numeric ordering is needed for display, sort numerically *after* the `comm` operation.
- **Defensive file guards**: Any `if: always()` step that reads files created by prior steps must `touch` or test for those files first, since prior steps may have been skipped or failed.
- **Alternative**: `grep -Fxvf before.txt after.txt` performs set difference without sort-order sensitivity (O(n*m) vs `comm`'s O(n+m), acceptable for small sets).

## Related Issues

- `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md` — Same "silent failure" pattern in GitHub Actions
- `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md` — Harness analysis CI infrastructure context
