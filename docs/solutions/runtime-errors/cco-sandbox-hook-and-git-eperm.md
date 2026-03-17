---
title: "cco --safe sandbox: hooks and git operations fail with EPERM"
date: 2026-03-18
category: runtime-errors
tags: [cco, sandbox, seatbelt, hooks, git, node, eperm, notify, keychain, ssh, statusline, secretlint, file-read-metadata]
module: cco sandbox configuration, Claude Code hooks, statusline
symptom: "Stop hook error: EPERM lstat '/Users/...'; git: unable to access ~/.gitconfig; gh auth: token invalid; statusline not displaying; secretlint EPERM"
root_cause: "cco --safe Seatbelt policy denies file-read* under $HOME; Node.js realpathSync needs lstat on every parent directory; git/gh/ssh configs are under $HOME"
---

# cco --safe sandbox: hooks and git operations fail with EPERM

## Problem

Three related failures when running Claude Code inside cco `--safe` sandbox:

1. **Stop/Notification hook crash**: `EPERM: operation not permitted, lstat '/Users/<user>'` — Node.js crashes during module resolution before any user code runs
2. **git operations fail**: `unable to access ~/.gitconfig: Operation not permitted`
3. **gh CLI auth fails**: `The token in default is invalid` — macOS Keychain inaccessible

Additionally, a pre-existing bug: the notify.mjs hook crashes with `Unexpected token 'i', "icable\n  "... is not valid JSON` when JSONL transcript entries exceed the 8KB tail-read buffer.

## Root Cause

### Hook EPERM
cco's `--safe` mode generates a macOS Seatbelt policy that denies **all** `file-read*` under `$HOME`, then selectively allows specific subpaths. Node.js's `Module._findPath` calls `realpathSync()` which does `lstat()` on every path component — including `$HOME` itself. Since `$HOME` is not a subpath of any allowed directory, the `lstat` fails and Node.js crashes at the runtime level, **before any user code (try/catch) executes**.

### Git/gh/SSH EPERM
git reads `~/.gitconfig`, `~/.gitignore`, `~/.config/git/`; gh CLI stores auth tokens in macOS Keychain (`~/Library/Keychains/`); SSH needs `~/.ssh/known_hosts` for host verification; 1Password SSH agent socket is at `~/Library/Group Containers/2BUA8C4S2C.com.1password/`. None of these were in the cco allow-paths.

### JSONL tail-read truncation
The notify.mjs hook reads the last 8192 bytes of the JSONL transcript to extract the last message for notification. When a JSONL entry exceeds 8KB (common with tool results), the read starts mid-entry, producing a truncated fragment that fails JSON.parse.

## Solution

### 1. Wrap hook command in bash for sandbox resilience

The Node.js EPERM happens before user code, so the script's try/catch can't handle it. Wrap in bash with stderr logging and `|| true`:

```json
"command": "bash -c 'mkdir -p \"$HOME/.claude/logs\" && node \"$HOME/.claude/scripts/notify.mjs\" 2>>\"$HOME/.claude/logs/notify-errors.log\" || true'"
```

Key design: separate "never block Claude Code" (`|| true`, `exit 0`) from "never tell anyone what went wrong" (log to file, not `/dev/null`).

### 2. Add allow-paths for git/gh/SSH operations

In `~/.config/cco/allow-paths` (read by the shell function that wraps cco):

```
# SSH config and known_hosts
~/.ssh:ro
# Git config files
~/.gitconfig:ro
~/.gitignore:ro
~/.config/git:ro
# mise-managed tools (prek for pre-commit hooks)
~/.local/share/mise:ro
# gh CLI config
~/.config/gh:ro
# macOS Keychain (gh CLI stores auth tokens here)
~/Library/Keychains:ro
# 1Password SSH agent socket (for git commit signing)
~/Library/Group Containers/2BUA8C4S2C.com.1password:ro
```

### 3. Fix JSONL tail-read resilience

- Increase buffer from 8KB to 64KB
- Skip the first line when tail-reading (it's almost always a truncated fragment)
- Parse lines backwards to find the first valid JSON entry
- Exit 0 on all errors with `console.error` logging

## Key Insights

1. **Seatbelt `subpath` allows the path itself AND children, but NOT parents.** `(allow file-read* (subpath "~/.claude"))` allows reading `~/.claude/foo` but NOT `lstat("~")`. Node.js's `realpathSync` needs parent `lstat`, so it fails.

2. **macOS Keychain access requires `~/Library/Keychains:ro`.** gh CLI stores tokens in the login keychain. Without this, `gh auth status` reports "token invalid" (misleading — it can't read the token at all).

3. **Each new cco allow-path requires a sandbox restart.** Changes to `allow-paths` only take effect on the next `cco --safe` invocation. The current session uses the Seatbelt policy generated at launch.

4. **Error suppression layers should be orthogonal.** Don't use `2>/dev/null` + bare `catch {}` + `|| true` together. Use `|| true` for exit code, file logging for stderr, and `catch(error) { console.error(...); exit(0) }` for JS-level errors. This preserves debuggability.

5. **`GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null` bypasses git config access** when you need git to work despite sandbox restrictions (useful for bootstrapping).

## Root Fix: Patch cco Seatbelt Profile (2026-03-18)

The workarounds above (bash wrapping, individual allow-paths) treat symptoms. The root fix patches cco's Seatbelt profile to allow `file-read-metadata` on all paths under `$HOME`:

```scheme
(allow file-read-metadata (subpath "$HOME"))
```

This permits `lstat/stat` (metadata only — no file content reads) so Node.js `realpathSync` succeeds. All Node.js tools (secretlint, statusline, hooks, pnpm) work inside the sandbox.

### Implementation

A chezmoi `run_onchange_after_` script patches cco's `sandbox` script using awk:

```bash
export PATCH_LINE
PATCH_LINE=$(printf '\t\t\tprintf '\''(allow file-read-metadata (subpath "%%s"))\\n'\'' "$(policy_quote "$HOME")"')

awk '
  { print }
  /deny file-read\* \(subpath/ && /policy_quote.*HOME/ { print ENVIRON["PATCH_LINE"] }
' "$SANDBOX" > "${SANDBOX}.patched" && mv "${SANDBOX}.patched" "$SANDBOX"
chmod u+x "$SANDBOX"
```

### Pitfalls Encountered

1. **`literal` vs `subpath`**: `(allow file-read-metadata (literal "$HOME"))` only allows `lstat($HOME)` itself. `realpathSync` also needs `lstat` on intermediate dirs like `$HOME/.local`, `$HOME/.local/share`, etc. Use `subpath` to cover all descendants.

2. **awk `-v` interprets `\n`**: `awk -v var="string\n"` converts `\n` to newline. Use `ENVIRON["VAR"]` instead — no escape interpretation.

3. **awk `>` redirect loses executable permission**: `awk '...' file > file.new && mv file.new file` creates file.new with 644. Add `chmod u+x file` after `mv`.

4. **Idempotency check skips chmod**: `grep -q 'marker' && exit 0` placed before `chmod` means chmod is skipped when the file is already patched. Move `chmod u+x` BEFORE the idempotency check.

### Additional allow-paths needed

```
~/.claude    # Claude Code config (rw for sessions, cache, logs)
~/.cache     # XDG cache (prek log files)
```

### Statusline defense-in-depth

Even with the root fix, a bash wrapper caches `statusline-command.ts` to `/tmp` as fallback:
- `/tmp` is outside `$HOME` — no `realpathSync` issue
- `.ts` extension preserved — `--experimental-strip-types` works
- Process substitution `<(cat file.ts)` does NOT work — `/dev/fd/N` has no `.ts` extension

## Prevention

- When adding new tools to the cco sandbox that need `$HOME` access, check what config/credential files the tool reads with: `strace -e openat <command>` (Linux) or `dtruss -f <command> 2>&1 | grep open` (macOS, outside sandbox)
- Test hooks both inside and outside the sandbox
- Prefer logging errors to `~/.claude/logs/` over suppressing them with `/dev/null`
- When patching external tools via chezmoi, always preserve file permissions (`chmod` after `awk`/`sed` redirects)
- Use `ENVIRON[]` instead of `awk -v` when passing strings containing escape sequences
- Place essential operations (like `chmod`) BEFORE idempotency early-exit checks
