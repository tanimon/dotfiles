---
name: cco-seatbelt-nodejs-fix
description: |
  Fix Node.js EPERM errors inside macOS Seatbelt sandbox (cco --safe).
  Use when: (1) Node.js crashes with "EPERM: operation not permitted, lstat '/Users/...'"
  before any user code runs, (2) realpathSync fails on $HOME or intermediate directories,
  (3) any Node.js tool (secretlint, pnpm, hooks, statusline) fails inside cco sandbox.
  Covers: Seatbelt file-read-metadata vs file-read* distinction, awk patching pitfalls,
  --experimental-strip-types /dev/fd extension issue, chezmoi run_onchange idempotency.
author: Claude Code
version: 1.0.0
date: 2026-03-18
---

# cco Seatbelt Sandbox: Fixing Node.js EPERM Errors

## Problem

Every Node.js tool fails inside cco's `--safe` sandbox with:
```
Error: EPERM: operation not permitted, lstat '/Users/<user>'
```
This breaks secretlint, statusline, hooks, and any npm/pnpm tool.

## Context / Trigger Conditions

- Running Claude Code via `cco --safe` (macOS Seatbelt sandbox)
- Any Node.js process crashes with EPERM on `lstat` of `$HOME` or intermediate dirs
- Error occurs at the **runtime level** (before user code/try-catch can handle it)
- Seatbelt policy has `(deny file-read* (subpath "$HOME"))` with selective allows

## Root Cause

Node.js `Module._findPath` calls `realpathSync()` which does `lstat()` on **every path
component** from root to target. Seatbelt's `subpath` rule allows the path and children
but NOT parents. So even with `(allow file-read* (subpath "$HOME/.claude"))`, `lstat("$HOME")`
itself is denied because `$HOME` is under the deny rule and no allow covers it.

The `file-read*` wildcard covers ALL read operations including `file-read-metadata` (stat/lstat).
The key insight: `file-read-metadata` allows stat/lstat **without** allowing `file-read-data`
(actual file content reads).

## Solution

### Primary: Patch cco's Seatbelt profile

Add after the deny rule:
```scheme
(allow file-read-metadata (subpath "$HOME"))
```

This allows `lstat/stat` on ALL paths under `$HOME` (metadata only — no file content reads).
Security impact is minimal: it reveals only file existence, permissions, and timestamps.

**Critical: Use `subpath`, not `literal`!** `literal` only allows `$HOME` itself.
`realpathSync` also needs intermediate dirs like `$HOME/.local`, `$HOME/.local/share`, etc.

### Patching via chezmoi

Use a `run_onchange_after_` script that patches cco's `sandbox` file:

```bash
export PATCH_LINE
PATCH_LINE=$(printf '\t\t\tprintf '\''(allow file-read-metadata (subpath "%%s"))\\n'\'' "$(policy_quote "$HOME")"')

awk '
  { print }
  /deny file-read\* \(subpath/ && /policy_quote.*HOME/ { print ENVIRON["PATCH_LINE"] }
' "$SANDBOX" > "${SANDBOX}.patched" && mv "${SANDBOX}.patched" "$SANDBOX"
chmod u+x "$SANDBOX"
```

### Defense-in-depth: /tmp cache for TypeScript statusline

For the statusline command specifically, cache the `.ts` file to `/tmp`:
```bash
src="$HOME/.claude/statusline-command.ts"
cached="/tmp/claude-statusline-${UID}.ts"
if [[ ! -f "$cached" ]] || [[ "$src" -nt "$cached" ]]; then
  cat "$src" > "$cached" 2>/dev/null || { echo "Claude"; exit 0; }
fi
exec node --experimental-strip-types "$cached"
```

## Pitfalls Discovered

### 1. `--experimental-strip-types` requires `.ts` extension
Process substitution `<(cat file.ts)` creates `/dev/fd/N` — Node.js sees no `.ts` extension
and does NOT strip types, causing `SyntaxError`. The `/tmp` cache preserves the extension.

### 2. awk `-v` interprets `\n` as newline
`awk -v var="string\nwith\n"` converts `\n` to actual newlines.
Fix: Use `ENVIRON["VAR"]` instead — no escape interpretation.

### 3. awk `>` redirect loses executable permissions
`awk '...' file > file.new && mv file.new file` — the new file has default 644 permissions.
Fix: Add `chmod u+x file` after `mv`.

### 4. Idempotency checks must not skip essential operations
If a patch script does `grep -q 'marker' && exit 0` early, any `chmod` after the patch
section is skipped. Move permission fixes BEFORE the idempotency check.

## Verification

```bash
# 1. Check patch was applied
grep 'file-read-metadata' ~/.local/share/cco/sandbox

# 2. Verify sandbox script is executable
test -x ~/.local/share/cco/sandbox && echo "OK"

# 3. Test Node.js works inside sandbox
claude  # should start without EPERM errors

# 4. Test pre-commit hooks work
git commit --allow-empty -m "test"  # secretlint should pass
```

## Notes

- Changes to cco allow-paths only take effect on next `cco --safe` invocation
- `CCO_DEBUG=1 cco ...` shows the generated Seatbelt policy for debugging
- `bash` doesn't have the `realpathSync` issue — it uses kernel `open()` directly
- Consider filing an upstream PR to `nikvdp/cco` for the `file-read-metadata` fix

## References

- [Node.js Issue #18255: Support /dev/fd/XX as scripts](https://github.com/nodejs/node/issues/18255)
- [Node.js PR #13028: Fix realpath on pipes/sockets](https://github.com/nodejs/node/pull/13028)
- macOS Seatbelt operations: `file-read-data`, `file-read-metadata`, `file-read-xattr`
- Solution doc: `docs/solutions/runtime-errors/cco-sandbox-hook-and-git-eperm.md`
