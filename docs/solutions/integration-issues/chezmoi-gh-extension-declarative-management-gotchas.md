---
title: "Declarative gh CLI extension management via chezmoi: gotchas"
problem_type: integration-issues
severity: medium
modules: [chezmoi, gh-cli]
symptoms:
  - "update-gh-extensions.sh outputs wrong value (e.g., 'markdown-preview' instead of 'yusukebe/gh-markdown-preview')"
  - "chezmoi deploys extensions.txt to ~/.config/gh/ despite *.txt in .chezmoiignore"
tags:
  - chezmoi
  - gh-cli
  - chezmoiignore
  - awk-parsing
  - tab-separated-values
  - glob-scope
  - run_onchange
  - declarative-package-management
date: 2026-03-11
---

# Declarative gh CLI extension management via chezmoi: gotchas

Two non-obvious issues discovered while implementing declarative gh extension management following the marketplace sync pattern.

## Issue 1: `gh extension list` tab-delimited parsing

### Problem

`scripts/update-gh-extensions.sh` outputted `markdown-preview` instead of `yusukebe/gh-markdown-preview`.

### Root Cause

`gh extension list` outputs tab-separated columns: `name\towner/repo\tversion`. The name field contains spaces (e.g., "gh markdown-preview"). Using `awk '{print $2}'` with the default whitespace delimiter splits the name field on spaces, returning the second word of the name instead of the second tab-delimited column.

```
# Raw output (^I = tab):
gh markdown-preview^Iyusukebe/gh-markdown-preview^Ie0579cac

# awk '{print $2}' sees 4 fields split by whitespace:
#   $1="gh"  $2="markdown-preview"  $3="yusukebe/gh-markdown-preview"  $4="e0579cac"
```

### Solution

Use explicit tab delimiter:

```bash
# WRONG
gh extension list | awk '{print $2}'

# CORRECT
gh extension list | awk -F'\t' '{print $2}'
```

### Verification

```bash
# Inspect raw output to confirm tab separators
gh extension list | cat -v -e -t
# Shows ^I (tab) between columns
```

## Issue 2: chezmoi `.chezmoiignore` glob only matches root level

### Problem

After removing the explicit `.config/gh/extensions.txt` entry from `.chezmoiignore`, `chezmoi managed` showed `.config/gh/extensions.txt` as managed — despite `*.txt` being on line 8 of `.chezmoiignore`.

Multiple AI review agents (security, architecture, simplicity) incorrectly flagged the explicit entry as redundant.

### Root Cause

chezmoi's `.chezmoiignore` uses Go's `doublestar` library. A bare `*.txt` pattern only matches files at the root level of the target directory. It does NOT recursively match nested paths like `.config/gh/extensions.txt`. This differs from `.gitignore` where `*.txt` matches at any depth.

### Solution

Add explicit entries for nested paths:

```
# .chezmoiignore

# This only matches root-level .txt files (e.g., ~/foo.txt)
*.txt

# Nested paths MUST be listed explicitly
.config/gh/extensions.txt
```

### Verification

```bash
# Confirm the file is NOT managed
chezmoi managed | grep extensions
# Should show only the run_onchange script, NOT .config/gh/extensions.txt
```

## Prevention

### For CLI output parsing

- **Always inspect raw output** with `cat -v -e -t` or `od -c` before writing awk commands
- **Always use `-F'\t'`** when parsing tab-delimited CLI output
- **Consider `cut -f2`** as a simpler alternative (defaults to tab delimiter)
- **Prefer `--json` output** when available to avoid delimiter ambiguity

### For `.chezmoiignore` patterns

- **Never assume `.chezmoiignore` works like `.gitignore`** — `*` does not cross directory boundaries
- **Use `**/*.txt`** for recursive matching across all depths
- **Always verify** with `chezmoi managed | grep <pattern>` after editing `.chezmoiignore`
- **Do not trust AI review** for glob correctness in `.chezmoiignore` — the `.gitignore` mental model is deeply ingrained and causes confident but incorrect assessments

## Related Documentation

- [chezmoi-declarative-marketplace-sync-over-bidirectional.md](chezmoi-declarative-marketplace-sync-over-bidirectional.md) — The pattern this implementation follows; also documents the `*.txt` root-level-only gotcha
- [chezmoi-apply-overwrites-runtime-plugin-changes.md](chezmoi-apply-overwrites-runtime-plugin-changes.md) — Decision tree for chezmoi file patterns
- [CLAUDE.md](../../../CLAUDE.md) — Project pitfalls including `.chezmoiignore` behavior
