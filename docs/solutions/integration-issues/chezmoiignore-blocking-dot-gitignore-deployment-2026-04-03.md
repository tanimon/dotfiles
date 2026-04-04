---
title: ".chezmoiignore entry blocks dot_gitignore deployment"
date: 2026-04-03
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "chezmoi source-path ~/.gitignore reported 'not managed' despite dot_gitignore existing in source directory"
  - "~/.gitignore was not created or updated by chezmoi apply"
  - "chezmoi managed | grep gitignore returned no results"
root_cause: config_error
resolution_type: config_change
tags:
  - chezmoi
  - chezmoiignore
  - dot-prefix
  - target-path-evaluation
  - gitignore
  - harness-engineering
---

# .chezmoiignore entry blocks dot_gitignore deployment

## Problem

`.chezmoiignore` contained a `.gitignore` entry that prevented `dot_gitignore` from deploying to `~/.gitignore`. The entry was intended to prevent the repository's own `.gitignore` from being deployed to the home directory, but it was unnecessary and caused a side effect that silently broke management of the global gitignore.

## Symptoms

- `chezmoi source-path ~/.gitignore` reported "not managed" despite `dot_gitignore` existing in the source directory
- `~/.gitignore` was not created or updated by `chezmoi apply`
- `chezmoi managed | grep gitignore` returned no results

## What Didn't Work

The investigation was relatively direct. The initial assumption might have been that `dot_gitignore` was malformed or missing, but the file existed correctly. The actual blocker was a `.chezmoiignore` entry that was not immediately obvious because `.chezmoiignore` evaluates against **target paths** (relative to `~/`), not source paths.

## Solution

Removed the `.gitignore` line from `.chezmoiignore`.

Before (`.chezmoiignore` excerpt):

```
.secretlintrc.json
.secretlintignore
.gitignore
```

After (`.chezmoiignore` excerpt):

```
.secretlintrc.json
.secretlintignore
```

## Why This Works

Two key chezmoi behaviors explain the root cause:

1. **`.chezmoiignore` evaluates target paths, not source paths.** The entry `.gitignore` matches the target `~/.gitignore`, which is exactly what `dot_gitignore` deploys to. So the ignore rule blocked the legitimate managed file.

2. **The entry was unnecessary in this repo.** While chezmoi can manage non-prefixed files as sources (a file named `foo` in the source directory deploys as `~/foo`), this repository's `.chezmoiignore` already excludes repo-only files broadly. The repo-root `.gitignore` was not at risk of deployment. However, the `.gitignore` ignore entry matched the **target path** `~/.gitignore` -- the same target that `dot_gitignore` deploys to.

The combination means the `.gitignore` entry had no useful effect (the repo `.gitignore` was already excluded by other means) but did have a harmful side effect (blocking `dot_gitignore` → `~/.gitignore` deployment).

## Prevention

1. **Understand `.chezmoiignore` target-path semantics.** Before adding entries, verify what target path they match using `chezmoi managed | grep <pattern>`. If the pattern matches a legitimately managed file, the entry will break it.

2. **Beware that `.chezmoiignore` patterns match target paths, not source paths.** A bare entry like `.gitignore` matches the target `~/.gitignore` -- which blocks deployment of `dot_gitignore`. Before adding an entry, check whether a `dot_`-prefixed source exists that maps to the same target. If you need to exclude a repo-only file that chezmoi would otherwise deploy, prefer specific exclusion strategies (broader glob patterns, existing ignore coverage) over bare filename entries that can collide with managed targets.

3. **Test after modifying `.chezmoiignore`.** Run `chezmoi managed` and verify all expected files are still listed:

   ```bash
   chezmoi managed | grep gitignore
   # Should show .gitignore when dot_gitignore exists in source
   ```

## Related Issues

- [chezmoi gh extension declarative management gotchas](chezmoi-gh-extension-declarative-management-gotchas.md) — Sibling `.chezmoiignore` gotcha covering glob semantics (`*.txt` not matching nested paths). Both involve `.chezmoiignore` causing unexpected non-deployment, but via different mechanisms.
