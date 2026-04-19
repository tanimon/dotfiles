---
title: "fix: Bypass codex internal sandbox inside safehouse Seatbelt"
type: fix
status: active
date: 2026-04-13
---

# fix: Bypass codex internal sandbox inside safehouse Seatbelt

## Overview

When `codex` is invoked from within Claude Code (running inside safehouse's Seatbelt sandbox), codex tries to apply its own macOS Seatbelt sandbox via `sandbox-exec`, which fails because macOS denies nested `sandbox_apply` syscalls. Add a shell wrapper that detects the outer sandbox and automatically bypasses codex's internal sandbox.

## Problem Frame

The user creates a temp file with `mktemp` inside Claude Code and passes it to `codex` as input. Codex fails before it can read the file because its own sandbox initialization triggers `sandbox_apply`, which macOS denies when already inside a Seatbelt jail. This is the same class of issue as the Claude Code internal sandbox conflict documented in `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md`.

## Requirements Trace

- R1. `codex` CLI must function correctly when invoked from within a sandboxed Claude Code session (safehouse or cco)
- R2. `codex` sandbox must remain active when invoked outside a Seatbelt sandbox (standalone use)
- R3. Temp files created by `mktemp` must be readable by codex inside the sandbox

## Scope Boundaries

- Only addresses the nested sandbox conflict for `codex` CLI
- Does not modify codex configuration files (`~/.codex/config.toml`)
- Does not change safehouse or cco sandbox policies (they already allow `/tmp` and `$TMPDIR`)

## Context & Research

### Relevant Code and Patterns

- `dot_config/zsh/sandbox.zsh` — existing `claude()` wrapper function that adds safehouse/cco sandboxing. The `codex()` wrapper follows the inverse pattern: detecting an existing sandbox and disabling codex's internal one
- `dot_claude/settings.json.tmpl` — Claude Code's internal sandbox disabled with `"sandbox": { "enabled": false }` to avoid the same nested Seatbelt conflict

### Institutional Learnings

- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` — identical root cause class. macOS denies nested `sandbox_apply`. Fix pattern: disable the inner sandbox when an outer sandbox already provides isolation
- `docs/solutions/runtime-errors/cco-sandbox-codex-mcp-eperm.md` — prior codex sandbox issue (`~/.codex` not in allow-paths). Already resolved but confirms codex runs as a child process inside the sandbox

## Key Technical Decisions

- **Shell wrapper over config file**: A `codex()` shell function in `sandbox.zsh` is chosen over a managed `~/.codex/config.toml` because (1) the bypass should be conditional on being inside a sandbox, (2) config.toml cannot express conditional logic, and (3) the wrapper pattern already exists for `claude`
- **`APP_SANDBOX_CONTAINER_ID` for detection**: This env var is set by macOS when any Seatbelt sandbox is active. Covers both safehouse and cco backends without tool-specific checks
- **`--dangerously-bypass-approvals-and-sandbox` flag**: Codex's own documentation states this flag is "intended solely for running in environments that are externally sandboxed" — exactly this use case

## Open Questions

### Resolved During Planning

- **Does `/tmp` access need a sandbox config change?** No. Both safehouse and cco base policies unconditionally allow read-write to `/tmp`, `/private/tmp`, `/var/folders`, and `/private/var/folders`. `mktemp` on macOS uses `$TMPDIR` (under `/var/folders/`) by default, which is also covered
- **Does the bypass flag work in all codex modes?** `codex exec --help` explicitly lists `--dangerously-bypass-approvals-and-sandbox`. The main `codex` help states "options will be forwarded to the interactive CLI", so it should work for interactive mode too. Verify during implementation
- **Could codex detect the outer sandbox itself?** Codex could check `APP_SANDBOX_CONTAINER_ID` internally, but that requires an upstream change. The shell wrapper is the immediate fix

### Deferred to Implementation

- **Exact error message confirmation**: The plan assumes the error is `sandbox-exec: sandbox_apply: Operation not permitted` based on the identical Claude Code pattern. Verify the actual error during implementation

## Implementation Units

- [x] **Unit 1: Add codex wrapper to sandbox.zsh**

**Goal:** Detect outer Seatbelt sandbox and bypass codex's internal sandbox automatically

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `dot_config/zsh/sandbox.zsh`

**Approach:**
- Add a `codex()` shell function after the existing `claude()` function
- Check `$APP_SANDBOX_CONTAINER_ID` env var to detect outer Seatbelt sandbox
- When inside sandbox: pass `--dangerously-bypass-approvals-and-sandbox` to codex
- When outside sandbox: pass through to `command codex` unchanged
- Include comment explaining the safety rationale (outer sandbox provides isolation)

**Patterns to follow:**
- `claude()` function in `dot_config/zsh/sandbox.zsh` for shell wrapper structure
- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` for the "disable inner sandbox" pattern

**Test scenarios:**
- Happy path: `codex exec "echo hello"` succeeds inside a safehouse-sandboxed Claude Code session
- Happy path: `mktemp` file created inside Claude Code is readable by codex via the wrapper
- Happy path: `codex` invoked outside any sandbox runs with its own sandbox active (no bypass)
- Edge case: `command codex` or `\codex` bypasses the wrapper for manual control

**Verification:**
- Inside sandboxed Claude Code: `codex exec "echo hello"` completes without `sandbox_apply: Operation not permitted`
- Outside sandbox: `codex exec "echo hello"` uses codex's own sandbox (no `--dangerously-bypass-approvals-and-sandbox` in process args)

- [x] **Unit 2: Document the solution**

**Goal:** Record the solution for future reference and prevention

**Requirements:** R1

**Dependencies:** Unit 1

**Files:**
- Create: `docs/solutions/integration-issues/codex-nested-seatbelt-sandbox-bypass.md`

**Approach:**
- Follow the existing solution document format (frontmatter with title, date, category, tags, module, symptom, root_cause)
- Reference the Claude Code internal sandbox solution as the same root cause class
- Include diagnostic and prevention guidance

**Patterns to follow:**
- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` for structure and format

**Test scenarios:**
Test expectation: none -- documentation file with no behavioral change

**Verification:**
- Solution doc exists with correct frontmatter and references the prior art

## System-Wide Impact

- **Interaction graph:** The wrapper intercepts all `codex` invocations in the user's shell. The `ecc:codex` skill and MCP server (`codex mcp-server`) are not affected — MCP server runs as a subprocess of Claude Code (not through the shell wrapper) and its sandbox conflict was already resolved in `settings.json.tmpl`
- **Error propagation:** If `--dangerously-bypass-approvals-and-sandbox` is not recognized by a future codex version, codex will fail with an unknown flag error. The error is visible and diagnosable
- **Unchanged invariants:** safehouse/cco sandbox policies are not modified. Claude Code's own sandbox configuration is not modified. Codex MCP server configuration is not modified

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| `--dangerously-bypass-approvals-and-sandbox` not accepted in interactive mode | Verify during implementation; fallback to `-c sandbox_type=none` or similar config override if needed |
| Future codex updates change the flag name | The wrapper is in the chezmoi source tree and easy to update. Error would be visible |

## Sources & References

- Related code: `dot_config/zsh/sandbox.zsh` (existing sandbox wrapper)
- Related solution: `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md`
- Related solution: `docs/solutions/runtime-errors/cco-sandbox-codex-mcp-eperm.md`
- Codex CLI help: `codex exec --help` documents `--dangerously-bypass-approvals-and-sandbox` as "intended solely for running in environments that are externally sandboxed"
