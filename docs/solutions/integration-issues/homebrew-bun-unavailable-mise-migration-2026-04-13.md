---
title: bun unavailable in Homebrew core — migrate to mise
date: 2026-04-13
category: integration-issues
module: tool-installation
problem_type: integration_issue
component: tooling
symptoms:
  - "brew bundle install silently fails to install bun (no error, just skips)"
  - "gstack setup permanently skipped with WARNING: bun not found"
  - "command -v bun returns non-zero after chezmoi apply on fresh machine"
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - homebrew
  - mise
  - bun
  - chezmoi
  - gstack
  - tool-installation
---

# bun unavailable in Homebrew core — migrate to mise

## Problem

`brew "bun"` in `darwin/Brewfile` fails silently because bun is not in Homebrew core. Homebrew requires formulae to build from source, but bun cannot be compiled from source due to Zig build-system constraints. This left gstack setup permanently skipped on fresh machines with no remediation path visible to the user.

## Symptoms

- `brew bundle install` completes without error but does not install bun
- `run_onchange_after_setup-gstack.sh.tmpl` prints "WARNING: bun not found, skipping gstack setup" on every `chezmoi apply`
- `command -v bun` returns non-zero even after a full `chezmoi apply`

## What Didn't Work

- `brew "bun"` in Brewfile (bun is not and has never been in `homebrew/core`)
- The official tap `oven-sh/bun` was considered but rejected to maintain consistency with existing JS tool management via mise

## Solution

Move bun from Brewfile to mise config. mise already manages node and pnpm and has a built-in `core:bun` backend (no external plugin needed).

**Before (`darwin/Brewfile`):**
```
brew "bun"
```

**After (`dot_config/mise/config.toml`):**
```toml
[tools]
bun = "latest"
node = "24"
pnpm = "10.33.0"
prek = "latest"
```

Additional fixes applied:
- Updated gstack setup script warning to include remediation hint: "Run 'mise install && chezmoi apply' to enable"
- Updated solution doc Pattern 3 (`chezmoi-external-skill-collection-patterns-2026-04-13.md`) to direct JS build dependencies to mise instead of Brewfile

**Decision rule:** JS runtimes and toolchains (node, pnpm, bun) go in mise. macOS system tools not managed by a version manager go in `darwin/Brewfile`.

## Why This Works

mise has first-class bun support via its built-in `core:bun` backend. The shim at `~/.local/share/mise/shims/bun` is on PATH after `mise install`, and the sandbox config already grants read-write access to `~/.local/share/mise` via the `runtime-managers.sb` profile.

## Prevention

- Before adding a tool to the Brewfile, verify it exists in Homebrew core with `brew info <tool>`. If not in core, check whether mise supports it (`mise ls-remote <tool>`) before resorting to a tap
- For JS runtimes and toolchains, prefer mise over Homebrew — it provides version pinning and consistency with existing node/pnpm management
- When a `run_onchange_` script guards on tool availability, always include a remediation hint in the warning message (e.g., "Run 'mise install && chezmoi apply' to enable")

## Related Issues

- PR #162: introduced gstack skills with the broken `brew "bun"` entry
- `docs/solutions/integration-issues/node-pnpm-version-sync-mise-ci-2026-03-29.md`: established the pattern for mise-managed JS tools
- `docs/solutions/integration-issues/chezmoi-external-skill-collection-patterns-2026-04-13.md`: Pattern 3 updated to reflect mise for JS build deps
