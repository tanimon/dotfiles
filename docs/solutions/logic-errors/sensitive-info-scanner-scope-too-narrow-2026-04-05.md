---
title: "Sensitive info scanner defaulted to docs/ only, missing repo-wide .md files"
date: 2026-04-05
category: logic-errors
module: Harness Tooling
problem_type: logic_error
component: tooling
symptoms:
  - "make scan-sensitive only scanned docs/**/*.md, not root-level or .claude/rules/*.md files"
  - "CLAUDE.md, README.md, and rule files excluded from PII detection"
root_cause: scope_issue
resolution_type: code_fix
severity: medium
tags:
  - scan-sensitive
  - pii-detection
  - makefile
  - harness-engineering
related_components:
  - scan-sensitive-info.sh
  - Makefile
  - CLAUDE.md
---

# Sensitive info scanner defaulted to docs/ only, missing repo-wide .md files

## Problem

`scripts/scan-sensitive-info.sh` and the Makefile `scan-sensitive` target only scanned `.md` files within the `docs/` directory. Other markdown files at the repo root (CLAUDE.md, README.md) and in subdirectories (`.claude/rules/*.md`) were not checked for PII or sensitive information.

## Symptoms

- `make scan-sensitive` reported scanning ~30 files instead of the full set of ~161 `.md` files in the repo
- Root-level files like CLAUDE.md (which contains path examples) were not covered by PII detection
- Pre-commit hook already had `files: '\.md$'` matching all `.md` files repo-wide, creating an inconsistency with the Makefile target

## What Didn't Work

N/A -- The fix was straightforward. The only complication was discovering during review that the Makefile's exclusion patterns were inconsistent with the script (Makefile was missing `.git` exclusion).

## Solution

**scripts/scan-sensitive-info.sh** (default find path, line 20):

Before:
```bash
done < <(find "$REPO_ROOT/docs" -type f -name '*.md' -print0 2>/dev/null)
```

After:
```bash
done < <(find "$REPO_ROOT" -type f -name '*.md' -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 2>/dev/null)
```

**Makefile** (variable definition):

Before:
```makefile
DOCS_MD_FILES := $(shell find ./docs -type f -name '*.md' 2>/dev/null)
```

After:
```makefile
ALL_MD_FILES := $(shell find . -type f -name '*.md' \
    ! -path './node_modules/*' ! -path './.git/*' 2>/dev/null)
```

All references to `DOCS_MD_FILES` in the `scan-sensitive` target were updated to `ALL_MD_FILES`. CLAUDE.md documentation was updated to reflect the new scope.

## Why This Works

The root cause was a scope limitation in the original `find` command that hardcoded `$REPO_ROOT/docs` as the search path. Changing it to `$REPO_ROOT` (with appropriate exclusions for `node_modules` and `.git`) ensures all managed markdown files are scanned. The variable rename from `DOCS_MD_FILES` to `ALL_MD_FILES` reflects the broader scope and prevents future confusion.

## Prevention

- When adding file-scanning tools, default to scanning the full repo with explicit exclusions rather than limiting to a single directory
- Keep exclusion patterns consistent across all invocation paths (script default, Makefile variable, pre-commit hook)
- After changing scan scope, verify the file count to confirm the expansion worked as expected (e.g., 30 files -> 161 files)

## Related Issues

- `docs/plans/2026-04-03-003-feat-pii-scan-plans-harness-plan.md` -- original plan that created scan-sensitive-info.sh (scoped to docs/ at the time)
- `docs/plans/2026-04-05-003-feat-expand-sensitive-scan-scope-plan.md` -- plan for this scope expansion
