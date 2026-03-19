---
title: "Managing script-only GitHub repos in chezmoi with pinned SHAs and Renovate auto-updates"
problem_type: integration-issues
severity: medium
modules: [chezmoi, renovate, mise]
symptoms:
  - "mise GitHub backend fails to install script-only repos (no GitHub Releases)"
  - "run_after_ script hash comments are inert (no change detection)"
  - "Renovate regex stops matching when TOML keys are reordered"
tags:
  - chezmoi
  - chezmoiexternal
  - renovate
  - git-refs
  - supply-chain-security
  - mise
  - run_onchange
  - symlink
date: 2026-03-13
---

# Managing script-only GitHub repos in chezmoi with pinned SHAs and Renovate auto-updates

How to declaratively install a script-only GitHub repo (no binaries, no releases) via chezmoi, with commit SHA pinning and automated updates.

## Problem

Needed to install [nikvdp/cco](https://github.com/nikvdp/cco) (a Claude Code sandbox wrapper). The tool is a bash script distributed as a git repo — no GitHub Releases, no pre-built binaries.

## Investigation

### Tool selection: sheldon, mise, chezmoi

| Tool | Purpose | Works for script repos? |
|------|---------|------------------------|
| **sheldon** | zsh plugin manager (source plugins into shell) | No — cco is a CLI tool, not a shell plugin |
| **mise** GitHub backend | Downloads pre-built binaries from GitHub Releases | **No** — requires release assets; script-only repos are unsupported |
| **chezmoi** `.chezmoiexternal.toml` | Clones git repos into managed paths | **Yes** — `type = "git-repo"` clones the entire repo |

### Key insight: mise GitHub backend limitations

The mise `github:` backend **only works with repos that have GitHub Releases with downloadable binary assets**. It uses smart asset matching (OS, arch, libc) to select the right binary. Repos that distribute tools as scripts in the repo tree are not supported.

## Solution

### 1. Add to `.chezmoiexternal.toml` with pinned SHA

```toml
[".local/share/cco"]
  type = "git-repo"
  url = "https://github.com/nikvdp/cco.git"
  # renovate: branch=master
  ref = "0b7265e4d629328a558364d86bb6a7f9a16b050b"
  refreshPeriod = "168h"
```

The `ref` field pins to a specific commit SHA for supply-chain safety.

### 2. Symlink script: `run_onchange_after_link-cco.sh.tmpl`

```bash
#!/usr/bin/env bash
# cco hash: {{ include ".chezmoiexternal.toml" | sha256sum }}
set -euo pipefail

CCO_BIN="{{ .chezmoi.homeDir }}/.local/share/cco/cco"
LINK="{{ .chezmoi.homeDir }}/bin/cco"

if [ ! -f "$CCO_BIN" ]; then
  echo "cco not found at $CCO_BIN, skipping"
  exit 0
fi

if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$CCO_BIN" ]; then
  exit 0
fi

mkdir -p "$(dirname "$LINK")"
ln -sf "$CCO_BIN" "$LINK"
```

### 3. Renovate regex custom manager for auto-updating SHAs

```json
{
  "customManagers": [{
    "customType": "regex",
    "managerFilePatterns": ["/\\.chezmoiexternal\\.toml$/"],
    "matchStrings": [
      "url\\s*=\\s*\"https://github\\.com/(?<depName>[^\"]+?)(?:\\.git)?\"\\s+#\\s*renovate:\\s*branch=(?<currentValue>\\S+)\\s+ref\\s*=\\s*\"(?<currentDigest>[a-f0-9]{40})\""
    ],
    "datasourceTemplate": "git-refs",
    "packageNameTemplate": "https://github.com/{{{depName}}}"
  }]
}
```

The regex extracts:
- `depName` from the `url` field (e.g., `nikvdp/cco`)
- `currentValue` (branch name) from the `# renovate: branch=` comment
- `currentDigest` (commit SHA) from the `ref` field

Per-entry `# renovate: branch=` comments handle repos with different default branches (e.g., `main` vs `master`).

## Key Insights

### 1. `run_after_` vs `run_onchange_after_` — hash comments are prefix-dependent

Hash-tracking comments like `# hash: {{ include "file" | sha256sum }}` **only work with `run_onchange_` prefix**. Using `run_after_` makes the hash comment inert — the script runs on every `chezmoi apply` regardless.

### 2. Renovate regex requires strict line adjacency

The TOML entries must keep `url`, `# renovate: branch=`, and `ref` lines strictly adjacent with no intervening blank lines or other keys. TOML doesn't mandate key ordering, so reordering silently breaks Renovate matching. Document this contract in CLAUDE.md.

### 3. `refreshPeriod` + `ref` interaction

When `ref` is set, `refreshPeriod` still controls how often chezmoi fetches — but since the ref is fixed, fetches are effectively no-ops until Renovate updates the SHA.

### 4. Shebang consistency matters

Use `#!/usr/bin/env bash` (not `#!/bin/bash`) to match the repo convention. Caught during code review.

## Prevention

- When adding new entries to `.chezmoiexternal.toml`, always include `ref` and `# renovate: branch=` comment
- Always use `run_onchange_after_` (not `run_after_`) for hash-tracked scripts
- Keep the Renovate contract documented in CLAUDE.md
- Verify Renovate `automerge` is disabled to maintain human review of SHA updates

## Related

- [Declarative gh extension management gotchas](chezmoi-gh-extension-declarative-management-gotchas.md)
- [Declarative marketplace sync pattern](chezmoi-declarative-marketplace-sync-over-bidirectional.md)
- PR #13: https://github.com/tanimon/dotfiles/pull/13
