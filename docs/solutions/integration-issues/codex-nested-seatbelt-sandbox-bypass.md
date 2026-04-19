---
title: "Codex CLI nested Seatbelt sandbox conflict inside safehouse/cco"
date: 2026-04-13
category: integration-issues
problem_type: integration_issue
component: tooling
severity: high
module: sandbox configuration, codex CLI
symptoms:
  - "sandbox-exec: sandbox_apply: Operation not permitted when running codex from within sandboxed Claude Code"
  - "All codex modes (interactive, exec, review) fail before processing input"
root_cause: config_error
resolution_type: config_change
tags: [codex, sandbox, safehouse, cco, seatbelt, nested-sandbox, sandbox-exec, mktemp, harness-engineering]
---

# Codex CLI nested Seatbelt sandbox conflict inside safehouse/cco

## Problem

When invoking `codex` from within a sandboxed Claude Code session (safehouse or cco), codex fails before processing any input:

```
sandbox-exec: sandbox_apply: Operation not permitted
```

This affects all codex modes (interactive, `exec`, `review`) and prevents using temp files (e.g., from `mktemp`) as input specifications for codex.

## Root Cause

Same class as the Claude Code internal sandbox conflict (`claude-code-internal-sandbox-nested-seatbelt-conflict.md`).

Two independent sandbox layers conflict:

1. **External sandbox (safehouse/cco)**: `sandbox.zsh` wraps `claude` with safehouse/cco, running Claude Code inside a Seatbelt sandbox via `sandbox-exec`
2. **Internal sandbox (Codex CLI)**: Codex applies its own macOS Seatbelt sandbox for executing model-generated shell commands (`codex sandbox macos`)

macOS denies nested `sandbox_apply` syscalls. When Codex (already inside safehouse's sandbox) tries to apply a second sandbox, the kernel returns EPERM.

### Why `/tmp` access is not the issue

Both safehouse and cco base policies unconditionally allow read-write to `/tmp`, `/private/tmp`, `/var/folders`, and `/private/var/folders`. `mktemp` on macOS creates files under `$TMPDIR` (typically `/var/folders/...`), which is already accessible. The error occurs before codex attempts to read any file — sandbox initialization itself fails.

## Solution

Add a `codex()` shell wrapper in `dot_config/zsh/sandbox.zsh` that detects the outer Seatbelt sandbox and bypasses codex's internal sandbox:

```zsh
codex() {
  if [[ -n "$APP_SANDBOX_CONTAINER_ID" ]]; then
    command codex --dangerously-bypass-approvals-and-sandbox "$@"
  else
    command codex "$@"
  fi
}
```

`$APP_SANDBOX_CONTAINER_ID` is set by macOS when any Seatbelt sandbox is active. The `--dangerously-bypass-approvals-and-sandbox` flag is documented by codex as "intended solely for running in environments that are externally sandboxed."

### Why this is safe

- **safehouse already provides comprehensive sandboxing** — deny-all default with granular allow rules
- **The outer sandbox is strictly stronger** than codex's internal Seatbelt profile
- **`command codex` or `\codex`** bypasses the wrapper for manual control when needed

## Prevention

When integrating a new CLI tool that uses macOS Seatbelt sandboxing internally, check whether it will run as a subprocess of an already-sandboxed process. If so, the tool needs a sandbox bypass option, and the wrapper should conditionally disable it.

**Detection pattern**: `sandbox-exec: sandbox_apply: Operation not permitted` in stderr is the definitive signal of a nested Seatbelt conflict.

## Related

- [Claude Code internal sandbox conflicts with external Seatbelt sandbox](claude-code-internal-sandbox-nested-seatbelt-conflict.md) — identical root cause, same class of fix
- [cco --safe sandbox: codex MCP server fails with EPERM on config.toml](../runtime-errors/cco-sandbox-codex-mcp-eperm.md) — prior codex sandbox issue (path access, not nested sandbox)
