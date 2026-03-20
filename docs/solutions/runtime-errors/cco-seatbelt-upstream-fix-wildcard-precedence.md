---
title: "cco --safe mode: upstream fix for file-read-metadata and Seatbelt wildcard precedence discovery"
category: runtime-errors
date: 2026-03-20
tags:
  - cco
  - macOS
  - seatbelt
  - sandbox
  - file-read-metadata
  - node.js
severity: high
modules:
  - nikvdp/cco
  - macOS Seatbelt
related:
  - docs/solutions/runtime-errors/cco-sandbox-hook-and-git-eperm.md
  - docs/solutions/runtime-errors/cco-sandbox-codex-mcp-eperm.md
upstream_pr: https://github.com/nikvdp/cco/pull/50
upstream_issue: https://github.com/nikvdp/cco/issues/49
---

# cco --safe mode: upstream fix for file-read-metadata and Seatbelt wildcard precedence discovery

## Problem

Node.js tools (secretlint, hooks, statusline) fail with `EPERM` inside `cco --safe` on macOS. The root cause is that `--safe` mode's Seatbelt policy uses `(deny file-read* (subpath "$HOME"))` which blocks `file-read-metadata` (stat/lstat), and the upstream only re-allows metadata on CWD ancestor paths via `literal` rules.

Any tool calling `lstat()` on a path under `$HOME` that is NOT a CWD ancestor fails:

```
Error: EPERM: operation not permitted, lstat '/Users/akito/.local/share/mise/...'
```

## Root Cause

The upstream cco `sandbox` script generates this Seatbelt policy in `--safe` mode:

```scheme
(deny file-read* (subpath "$HOME"))
;; Only ancestors of CWD get metadata access (too narrow)
(allow file-read-metadata (literal "$HOME"))
(allow file-read-metadata (literal "$HOME/ghq"))
(allow file-read-metadata (literal "$HOME/ghq/github.com"))
;; ... etc, only CWD ancestors
```

The `file-read*` wildcard matches `file-read-data`, `file-read-metadata`, and `file-read-xattr`. The `literal` ancestor allows are insufficient because tools like Node.js call `realpathSync` which needs `lstat` on **arbitrary** paths under `$HOME`, not just CWD ancestors.

## Solution: Upstream PR

Submitted [PR #50](https://github.com/nikvdp/cco/pull/50) and [Issue #49](https://github.com/nikvdp/cco/issues/49) to nikvdp/cco.

The fix replaces the per-ancestor `literal` loop with a single `subpath` allow:

```scheme
(deny file-read* (subpath "$HOME"))
(allow file-read-metadata (subpath "$HOME"))
```

This permits stat/lstat on ALL paths under `$HOME` while still denying:
- `file-read-data` (file content reads)
- `file-read-xattr` (extended attribute reads)

### Code change in `sandbox` script

**Before** (lines 539-546):
```bash
local ancestor="$PWD_ABS"
while [[ "$ancestor" != "$HOME" && "$ancestor" == "$HOME"/* ]]; do
    ancestor="$(dirname "$ancestor")"
    printf '(allow file-read-metadata (literal "%s"))\n' "$(policy_quote "$ancestor")"
done
printf '(allow file-read-metadata (literal "%s"))\n' "$(policy_quote "$HOME")"
```

**After** (single line):
```bash
printf '(allow file-read-metadata (subpath "%s"))\n' "$(policy_quote "$HOME")"
```

### Security tradeoff

With `subpath`, a sandboxed process can stat any path under `$HOME` (existence, size, mtime, permissions). This is acceptable because:

- `--safe` mode already uses `(allow default)`, full network access, env var inheritance, and Mach port access
- Linux `--safe` mode (tmpfs overlay) allows stat on the mount — this makes macOS consistent
- The previous `literal` approach already leaked metadata for CWD ancestors

## Key Discovery: Seatbelt Wildcard Precedence

During testing, we discovered that **Seatbelt prioritizes specific operation allows over wildcard denies, regardless of rule order**.

```scheme
(allow file-read-metadata (subpath "$HOME"))   ;; specific allow
(deny file-read* (subpath "$SOME_PATH"))       ;; wildcard deny (comes AFTER)
```

Even though the `deny file-read*` rule comes **after** the `allow file-read-metadata` rule, `stat` on `$SOME_PATH` still succeeds. The specific `file-read-metadata` allow wins over the `file-read*` wildcard deny.

**Confirmed as pre-existing behavior** — the same interaction exists with the original `literal` ancestor allows on the upstream `master` branch. Not introduced by this change.

**Practical implication**: `--deny` paths in cco cannot block stat/lstat when a broad metadata allow is in place. To deny metadata on a specific path, an explicit `(deny file-read-metadata ...)` rule would be needed. This is a minor limitation since `--deny` still blocks file content reads and directory listings.

### Seatbelt operation hierarchy

```
file-read*                (wildcard — matches all three below)
├── file-read-data        (open/read file content)
├── file-read-metadata    (stat/lstat/readlink)
└── file-read-xattr       (extended attributes)
```

When authoring policies, prefer specific operations (`file-read-data`) over wildcards (`file-read*`) when possible. If a wildcard deny is necessary, explicitly re-allow `file-read-metadata` afterward.

## Verification

- All 35 tests pass on macOS (`tests/test_sandbox.sh`)
- `shellcheck` and `shfmt` clean
- New tests added:
  - `stat` on non-CWD-ancestor path under `$HOME` — succeeds
  - `readlink` on symlink under `$HOME` — succeeds
  - Existing tests preserved: content reads and directory listings still denied

## Post-Merge Follow-up

Once PR #50 merges and Renovate bumps the ref in `.chezmoiexternal.toml`:

1. The local patch script (`run_onchange_after_patch-cco-sandbox.sh.tmpl`) will self-disable — its idempotency check detects `file-read-metadata (subpath` and skips patching
2. Eventually remove the patch script entirely in a cleanup commit

## Prevention

### For Seatbelt policy authors

1. **Prefer specific operations over wildcards** — use `(deny file-read-data ...)` instead of `(deny file-read* ...)` when you only want to block content reads
2. **If using wildcard deny, always re-allow metadata** — add `(allow file-read-metadata (subpath ...))` after `(deny file-read* (subpath ...))`
3. **Use `subpath` not `literal`** for broad allows — `literal` only matches the exact path, not descendants
4. **Test with real tools** — Node.js `realpathSync`, symlink resolution, and other common operations

### For cco users

- Use `CCO_DEBUG=1` to inspect the generated Seatbelt policy file
- If a tool fails with EPERM on stat/lstat, the issue is likely a missing `file-read-metadata` allow

## Related Documentation

- [cco-sandbox-hook-and-git-eperm.md](cco-sandbox-hook-and-git-eperm.md) — Original local workaround (awk patch). Covers `literal` vs `subpath`, awk pitfalls (chmod, ENVIRON, idempotency)
- [cco-sandbox-codex-mcp-eperm.md](cco-sandbox-codex-mcp-eperm.md) — Related issue where codex MCP needs `file-read-data` (not just metadata). The metadata fix alone is insufficient for tools needing content reads
- Project memory: `seatbelt_wildcard_precedence.md` (auto memory [claude])
- Project memory: `cco_seatbelt_file_read_metadata.md` (auto memory [claude])
