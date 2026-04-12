---
title: "chezmoi v2.70.1 strict mode rejects ref field in .chezmoiexternal.toml"
date: 2026-04-12
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: tooling
symptoms:
  - "chezmoi diff/apply fails: strict mode: fields in the document are missing in the target struct"
  - "All chezmoi commands fail after upgrading to v2.70.1"
root_cause: config_error
resolution_type: config_change
severity: high
tags:
  - chezmoi
  - chezmoiexternal
  - strict-mode
  - archive
  - renovate
  - supply-chain-security
  - harness-engineering
---

# chezmoi v2.70.1 strict mode rejects ref field in .chezmoiexternal.toml

## Problem

After upgrading chezmoi to v2.70.1 (via Homebrew auto-update), all chezmoi commands fail with:
```
chezmoi: .chezmoiexternal.toml: strict mode: fields in the document are missing in the target struct
```

## Symptoms

- `chezmoi diff`, `chezmoi apply`, and all other commands fail immediately
- Error points to `.chezmoiexternal.toml` as the source
- The error message mentions "strict mode" and "fields missing in target struct"

## What Didn't Work

- The `ref` field was documented in project solution docs as a valid way to pin `git-repo` entries to specific commit SHAs. Investigation revealed it was **never a valid chezmoi field** for `git-repo` type entries. Previous chezmoi versions silently ignored unknown TOML fields, so the `ref` value was discarded without error. SHA pinning via `ref` never actually worked.

## Solution

Migrate from `type = "git-repo"` + `ref` to `type = "archive"` with SHA-embedded GitHub archive URLs.

**Before (broken in v2.70.1):**

```toml
[".local/share/cco"]
  type = "git-repo"
  url = "https://github.com/nikvdp/cco.git"
  # renovate: branch=master
  ref = "42fc44e5ecc0e26ef9068743b52485ebbcd54cf9"
  refreshPeriod = "168h"
```

**After:**

```toml
[".local/share/cco"]
  type = "archive"
  url = "https://github.com/nikvdp/cco/archive/42fc44e5ecc0e26ef9068743b52485ebbcd54cf9.tar.gz"
  # renovate: branch=master
  stripComponents = 1
  refreshPeriod = "168h"
```

Key changes:
- `type` changed from `"git-repo"` to `"archive"`
- `url` now uses GitHub archive URL with SHA embedded: `https://github.com/{owner}/{repo}/archive/{sha}.tar.gz`
- `ref` field removed entirely
- `stripComponents = 1` added to strip the archive's top-level directory (e.g., `owner-repo-sha/`)
- `.git` suffix removed from URL

Also update the Renovate regex custom manager to match the new URL pattern:

```json
{
  "matchStrings": [
    "url\\s*=\\s*\"https://github\\.com/(?<depName>[^/]+/[^/]+)/archive/(?<currentDigest>[a-f0-9]{40})\\.tar\\.gz\"\\s+#\\s*renovate:\\s*branch=(?<currentValue>\\S+)"
  ]
}
```

GitHub archive URLs work for any commit SHA — no GitHub Releases required.

## Why This Works

chezmoi v2.70.1 introduced strict TOML parsing via commit [`dd03362`](https://github.com/twpayne/chezmoi/commit/dd03362165b4bbc6ff61cb89e2a5cb26a0d77647) ("Detect unknown fields when parsing config files"). The `ref` field was never part of chezmoi's internal struct for `git-repo` type entries — chezmoi's `git-repo` external type only supports `type`, `url`, `clone.args`, `pull.args`, and `refreshPeriod`. By switching to `type = "archive"` with the SHA in the URL, the commit is actually pinned (unlike the broken `ref` approach), and no unknown fields exist in the TOML.

## Prevention

- Use `type = "archive"` (not `git-repo`) when pinning to specific commit SHAs in `.chezmoiexternal.toml`
- Check chezmoi release notes when upgrading — strict parsing may surface previously-silent config issues
- Verify SHA pinning actually works by checking `chezmoi managed` output, not just trusting the config

## Related Issues

- [chezmoi v2.70.1 release notes](https://github.com/twpayne/chezmoi/releases/tag/v2.70.1)
- [Managing script-only GitHub repos in chezmoi](chezmoi-external-script-repo-with-renovate-sha-pinning.md) — original setup guide, updated to reflect archive pattern
- PR [#161](https://github.com/tanimon/dotfiles/pull/161) — the fix
