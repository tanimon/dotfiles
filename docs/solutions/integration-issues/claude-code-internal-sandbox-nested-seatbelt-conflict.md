---
title: "Claude Code internal sandbox conflicts with external Seatbelt sandbox (safehouse/cco)"
category: integration-issues
tags: [claude-code, sandbox, safehouse, seatbelt, sandbox-exec, nested-sandbox, skills, plugins]
date: 2026-03-24
module: Claude Code sandbox configuration
symptom: "sandbox-exec: sandbox_apply: Operation not permitted when running skills/plugins"
root_cause: "Claude Code's built-in sandbox (sandbox.enabled: true) calls sandbox-exec for Bash tool commands, which fails inside an existing Seatbelt sandbox because macOS denies nested sandbox_apply syscalls"
---

# Claude Code internal sandbox conflicts with external Seatbelt sandbox

## Problem

When running Claude Code inside a safehouse (or cco) Seatbelt sandbox, skill/plugin shell commands fail:

```
Skill(ralph-loop:ralph-loop)
  ⎿  Initializing…
  ⎿  Error: Shell command failed for pattern "...": [stderr]
     sandbox-exec: sandbox_apply: Operation not permitted
```

This affects ALL skills that execute shell commands via Claude Code's Bash tool, not just ralph-loop.

## Root Cause

Two independent sandbox layers conflict:

1. **External sandbox (safehouse)**: `sandbox.zsh` wraps `claude` with `safehouse` → runs Claude Code inside a Seatbelt sandbox via `sandbox-exec`
2. **Internal sandbox (Claude Code)**: `settings.json` has `sandbox.enabled: true` → Claude Code uses `sandbox-exec` internally for Bash tool commands

macOS denies nested `sandbox_apply` syscalls. When Claude Code (already inside safehouse's sandbox) tries to apply a second sandbox for a Bash command, the kernel returns EPERM.

### Verification

From inside a safehouse sandbox:

```bash
# Confirm we're inside a sandbox
echo $APP_SANDBOX_CONTAINER_ID
# → agent-safehouse

# Attempt nested sandbox-exec
sandbox-exec -p '(version 1)(allow default)' echo "test"
# → sandbox-exec: sandbox_apply: Operation not permitted
```

## Solution

Disable Claude Code's internal sandbox in global settings (`dot_claude/settings.json.tmpl`):

```json
"sandbox": {
  "enabled": false
}
```

### Why this is safe

- **safehouse already provides comprehensive sandboxing** — deny-all default with granular allow rules for file access, network, and process control
- **`--dangerously-skip-permissions` is passed by the safehouse wrapper** — making `autoAllowBashIfSandboxed` redundant
- **The internal sandbox is strictly weaker** than safehouse's Seatbelt profile

### Settings precedence note

The project-level `.claude/settings.local.json` already had `sandbox.enabled: false`, but:
- Skills may execute in contexts where project settings don't fully override global settings
- Other projects without a `settings.local.json` override would still hit this conflict

Fixing the global settings ensures all projects work correctly under safehouse.

## Prevention

- When using an external sandbox (safehouse, cco), always disable Claude Code's internal sandbox to avoid nested `sandbox_apply` conflicts
- If Claude Code adds support for detecting external sandboxes (e.g., via `APP_SANDBOX_CONTAINER_ID`), the internal sandbox could auto-disable

## Related

- [cco-sandbox-args-file-backend-passthrough-only.md](cco-sandbox-args-file-backend-passthrough-only.md) — cco arg file limitations
- [migrate-cco-to-agent-safehouse.md](migrate-cco-to-agent-safehouse.md) — safehouse migration
- [safehouse-cli-flag-internals-and-config-patterns.md](safehouse-cli-flag-internals-and-config-patterns.md) — safehouse config patterns
- (auto memory [claude]) Seatbelt Wildcard Precedence — specific allow > wildcard deny, relevant to understanding Seatbelt behavior
