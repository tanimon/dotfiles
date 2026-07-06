---
title: "Makefile test targets silently PASS on mktemp failure; macOS mktemp ignores TMPDIR in sandbox"
category: integration-issues
date: 2026-07-06
tags: [makefile, mktemp, sandbox, tmpdir, macos, silent-failure, lint, harness-engineering]
module: makefile
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "make check-templates prints 'mktemp: mkstemp failed on /tmp/...: Operation not permitted' followed by 'PASS: all templates valid' and exits 0"
  - "make lint test targets pass without actually validating anything inside a sandboxed Claude Code session"
  - "bare `mktemp -d` and `mktemp -d -t` fail in the sandbox even though $TMPDIR points to a writable directory"
root_cause: "Unguarded mktemp command substitution left the temp path empty so downstream commands ran against invalid/empty paths, and the target still reached its final PASS echo; separately, macOS BSD mktemp ignores an exported $TMPDIR unless given an explicit full-path template."
resolution_type: bugfix
---

# Makefile test targets silently PASS on mktemp failure; macOS mktemp ignores TMPDIR in sandbox

## Problem

The `check-templates` target in the repo `Makefile` printed `PASS: all templates valid` and exited 0 even when `mktemp` failed to create its temp config. Observed output was `mktemp: mkstemp failed on /tmp/chezmoi-test-XXXXXX.toml: Operation not permitted` immediately followed by `PASS: all templates valid`. The template validation never actually ran, but `make lint` reported success — a silent failure that could mask broken templates.

## Symptoms

- `make check-templates` (and sibling `test-modify`, `test-sensitive`, `test-harness-scripts`) failed to create temp files/dirs in a sandboxed Claude Code session where `/tmp` is not writable, yet still reported PASS.
- After adding guards, `mktemp -d` (bare) and `mktemp -d -t name` **still** failed inside the sandbox with `Operation not permitted`, despite `$TMPDIR` being set to a writable path (`/tmp/claude-501`).

## What Didn't Work

- **Guarding `mktemp` alone was necessary but not sufficient.** Adding `tmpconfig=$(mktemp ...) || { echo "FAIL: mktemp"; exit 1; }` correctly turned the silent PASS into a loud failure, but the targets still could not run in the sandbox because the temp path was hardcoded to `/tmp`, which the sandbox denies.
- **Bare `mktemp -d` and `mktemp -d -t` did not fix the sandbox case on macOS.** Even with `TMPDIR` exported to a writable dir, macOS BSD `mktemp` resolved to `_CS_DARWIN_USER_TEMP_DIR` (`/var/folders/.../T/`), which the sandbox also denies. Verified empirically: `mktemp -d` reported `mkdtemp failed on /var/folders/...: Operation not permitted` while `$TMPDIR=/tmp/claude-501`.

## Solution

Two changes at every `mktemp` call site in the `Makefile`:

1. **Guard the result** so failure aborts loudly (matches the pattern already used in `test-harness-scripts`):

   ```makefile
   # before
   tmpconfig=$$(mktemp /tmp/chezmoi-test-XXXXXX.toml); \

   # after
   tmpconfig=$$(mktemp "$${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml") || { echo "FAIL: mktemp failed"; exit 1; }; \
   ```

2. **Use an explicit `${TMPDIR:-/tmp}` template** so mktemp honors a sandbox-writable `$TMPDIR` while remaining identical to the old behavior when `TMPDIR` is unset (e.g. CI ubuntu-latest):

   ```makefile
   # bare mktemp -d ignores exported TMPDIR on macOS — give it an explicit path
   TMPDIR="$$(mktemp -d "$${TMPDIR:-/tmp}/test-karabiner-XXXXXX")" || { echo "FAIL: mktemp failed"; exit 1; }; \
   ```

Preserve the `.toml` suffix on the check-templates temp file — chezmoi infers config format from the extension.

## Why This Works

- **POSIX assignment exit status propagates.** `var=$(cmd) || guard` *does* fire the guard when `cmd` fails: a command substitution's exit status becomes the assignment's exit status (POSIX Shell 2.9.1). Verified: `sh -c 'v=$(false) || echo fired'` prints `fired`. (An earlier reviewer hypothesis that the guard never fires was refuted by this test.)
- **`${TMPDIR:-/tmp}` gives mktemp an explicit target.** macOS BSD mktemp only consults `$TMPDIR` for the *bare*/`-t` forms, and even then prefers the confstr Darwin temp dir — passing a full-path template makes it write exactly where told. When `TMPDIR` is unset the expansion reduces to the original `/tmp/...` string, so CI behavior is unchanged.

## Prevention

- **Never leave a `mktemp` command substitution unguarded in a Makefile recipe.** Always `|| { echo "FAIL: mktemp failed"; exit 1; }`. A recipe with a final `echo "PASS"` will otherwise report success even when the temp setup silently produced an empty path.
- **When a temp path must be sandbox-portable, use `"${TMPDIR:-/tmp}/name-XXXXXX"`, not hardcoded `/tmp` and not bare `mktemp -d`.** On macOS the bare form ignores `$TMPDIR`.
- **Treat "error message immediately followed by PASS" as a silent-failure smell.** If a target can print a tool error and still reach its success line, the success line is lying.
- Verify both ways: run the target inside the sandbox (should now fail loudly or pass legitimately) and unsandboxed (should still pass). In this repo, `make check-templates test-modify test-sensitive test-harness-scripts` covers all four call sites.
