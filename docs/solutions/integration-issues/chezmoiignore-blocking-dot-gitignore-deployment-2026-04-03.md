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

2. **The entry was unnecessary in the first place.** chezmoi only recognizes files with its naming conventions (`dot_`, `private_`, etc.) as source files. The repository's own `.gitignore` (without a `dot_` prefix) is never treated as a source file by chezmoi, so it would never be deployed to `~/` regardless of `.chezmoiignore`.

The combination means the `.gitignore` entry had no useful effect (the repo `.gitignore` was never at risk of deployment) but did have a harmful side effect (blocking `dot_gitignore` deployment).

## Prevention

1. **Understand `.chezmoiignore` target-path semantics.** Before adding entries, verify what target path they match using `chezmoi managed | grep <pattern>`. If the pattern matches a legitimately managed file, the entry will break it.

2. **Do not ignore repo-only files that lack chezmoi prefixes.** Files like `.gitignore`, `Makefile`, `README.md` at the repo root are not recognized by chezmoi as source files (they lack `dot_`, `private_`, etc. prefixes). Adding them to `.chezmoiignore` is unnecessary and risks collateral damage if a `dot_`-prefixed variant exists.

3. **Test after modifying `.chezmoiignore`.** Run `chezmoi managed` and verify all expected files are still listed:

   ```bash
   chezmoi managed | grep gitignore
   # Should show .gitignore when dot_gitignore exists in source
   ```

## Related Issues

- [chezmoi gh extension declarative management gotchas](chezmoi-gh-extension-declarative-management-gotchas.md) — Sibling `.chezmoiignore` gotcha covering glob semantics (`*.txt` not matching nested paths). Both involve `.chezmoiignore` causing unexpected non-deployment, but via different mechanisms.
