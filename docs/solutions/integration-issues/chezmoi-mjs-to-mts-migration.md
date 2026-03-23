---
title: "TypeScript migration of Claude Code hook script (notify.mjs → notify.mts)"
category: integration-issues
date: 2026-03-23
tags:
  - typescript
  - chezmoi
  - claude-code-hooks
  - node-esm
  - seatbelt-sandbox
  - pre-commit
  - mts
module: dot_claude/scripts
severity: low
---

# TypeScript Migration: notify.mjs → notify.mts

## Problem

Rewriting `executable_notify.mjs` (JavaScript ESM) to TypeScript exposed three integration issues:

1. **ESM warning**: `.ts` extension with `node --experimental-strip-types` produces `MODULE_TYPELESS_PACKAGE_JSON` warning when no `package.json` with `"type": "module"` exists in scope
2. **Seatbelt sandbox incompatibility**: `--experimental-strip-types` triggers Node.js `realpathSync` which calls `lstat($HOME)`, blocked by Seatbelt deny rules
3. **Pre-commit hook collision**: shellcheck/shfmt matched `.mts` files via the `executable_` prefix glob pattern

## Root Cause

The `.ts` extension is module-type-ambiguous in Node.js. Without a `"type": "module"` field in `package.json`, Node.js defaults to CJS parsing, fails on ESM syntax, then re-parses as ESM with a performance warning. Adding `"type": "module"` to `package.json` would affect the entire project — too broad for one script.

The Seatbelt issue is a known pattern (auto memory [claude]): Node.js `Module._findPath` calls `realpathSync()` which does `lstat()` on every path component including `$HOME`, denied by the sandbox's `(deny file-read* (subpath "$HOME"))` rule.

The pre-commit issue stems from `.pre-commit-config.yaml` using `files: '(\.sh$|\.bash$|\.chezmoiscripts/|executable_)'` — the `executable_` pattern is interpreter-agnostic but shellcheck/shfmt are shell-only.

## Investigation Steps

1. Renamed `.mjs` → `.ts`, added TypeScript interfaces (`HookInput`, `TranscriptEntry`, `TranscriptMessage`), typed error catch clause as `(error as Error).message`
2. Ran with `node --experimental-strip-types` → got `MODULE_TYPELESS_PACKAGE_JSON` warning
3. Tested `.mts` extension → warning eliminated. `.mts` signals ESM via filename (like `.mjs` for JS)
4. Created wrapper script following `statusline-wrapper.sh` pattern for Seatbelt compatibility
5. First commit failed: shellcheck parsed `.mts` as shell → added exclusion pattern

## Solution

### 1. Use `.mts` extension (not `.ts`)

```
executable_notify.mjs → executable_notify.mts
```

The `.mts` extension is the TypeScript equivalent of `.mjs` — it explicitly signals ESM to Node.js without needing `package.json` changes.

### 2. Wrapper script for Seatbelt sandbox

`executable_notify-wrapper.sh` — same `/tmp` cache pattern as `statusline-wrapper.sh`:

```bash
#!/bin/bash
src="$HOME/.claude/scripts/notify.mts"
cached="/tmp/claude-notify-${UID}.mts"

if [[ ! -f "$cached" ]] || [[ "$src" -nt "$cached" ]]; then
    cat "$src" >"$cached" 2>/dev/null || exit 0
fi

exec node --experimental-strip-types "$cached"
```

Key: preserve `.mts` extension in the cached copy — Node.js uses extension for module type detection.

### 3. Update hook commands

In `settings.json.tmpl`, change Notification/Stop hooks from:
```
node "$HOME/.claude/scripts/notify.mjs"
```
to:
```
"$HOME/.claude/scripts/notify-wrapper.sh"
```

### 4. Exclude non-shell files from pre-commit hooks

In `.pre-commit-config.yaml`:
```yaml
exclude: '(\.tmpl$|\.mts$|\.ts$|\.mjs$)'
```

## What Didn't Work

| Approach | Why it failed |
|----------|--------------|
| `.ts` extension | MODULE_TYPELESS_PACKAGE_JSON warning without `"type": "module"` in package.json |
| Adding `"type": "module"` to package.json | Too broad — affects entire project's module resolution |
| Running `.mts` directly from `$HOME` under Seatbelt | `--experimental-strip-types` triggers `realpathSync` → `lstat($HOME)` → EPERM |

## Prevention

### Checklist for new `executable_` TypeScript files in chezmoi

- [ ] Use `.mts` extension (ESM) or `.cts` (CJS), never bare `.ts`
- [ ] Create a wrapper script if it runs inside Seatbelt sandbox
- [ ] Preserve file extension in `/tmp` cached copy
- [ ] Add extension to pre-commit `exclude` pattern before first commit
- [ ] Test inside sandbox with `chezmoi apply --dry-run`
- [ ] Verify shebang matches runtime and sandbox `$PATH`

### General principle

Each problem stems from implicit assumptions — Node.js assumes `package.json` exists, the sandbox assumes scripts won't touch `$HOME` metadata, pre-commit assumes `executable_` means shell. Make everything explicit: explicit extensions, explicit sandbox testing, explicit hook exclusions.

## Related Documentation

- [`cco-sandbox-hook-and-git-eperm.md`](../runtime-errors/cco-sandbox-hook-and-git-eperm.md) — Seatbelt EPERM with Node.js hooks (references old `notify.mjs` — needs update)
- [`claude-code-hook-exit-code-and-stderr-semantics.md`](./claude-code-hook-exit-code-and-stderr-semantics.md) — Hook exit code contract (references old `executable_notify.mjs` — needs update)
- [`chezmoi-tmpl-shellcheck-shfmt-incompatibility.md`](./chezmoi-tmpl-shellcheck-shfmt-incompatibility.md) — Pre-commit patterns for chezmoi files
- [`chezmoi-full-template-drift.md`](./chezmoi-full-template-drift.md) — Template drift with `--experimental-strip-types`
- Skill: `node-typescript-mts-esm` — Reusable knowledge for `.mts` vs `.ts` ESM resolution
- Skill: `cco-seatbelt-nodejs-fix` — Seatbelt EPERM fixes for Node.js
