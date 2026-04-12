---
title: "fix: Move bun installation from Homebrew to mise"
type: fix
status: active
date: 2026-04-13
---

# fix: Move bun installation from Homebrew to mise

## Overview

`brew "bun"` in `darwin/Brewfile` fails because bun is not published to Homebrew core. Move bun installation to mise, which already manages node and pnpm in this repository and has built-in core support for bun.

## Problem Frame

PR #162 (gstack skills) added `brew "bun"` to the Brewfile, but bun has never been in `homebrew/core` — Homebrew requires formulae to build from source and bun cannot be compiled from source due to Zig build-system constraints. The result is that `brew bundle install` silently fails to install bun, and the downstream `run_onchange_after_setup-gstack.sh.tmpl` gracefully skips gstack setup due to the `command -v bun` guard.

## Requirements Trace

- R1. bun must be installable declaratively via the managed dotfiles
- R2. The installation method must be consistent with existing tool management patterns in this repo

## Scope Boundaries

- The `~/.bun` sandbox allowlist in `dot_config/safehouse/config.tmpl` stays as-is — bun's runtime cache directory may still use `~/.bun` regardless of install method
- The `command -v bun` guard in `run_onchange_after_setup-gstack.sh.tmpl` works with mise shims; the only change is improving the warning message with a remediation hint

## Context & Research

### Relevant Code and Patterns

- `dot_config/mise/config.toml` — already manages `node = "24"`, `pnpm = "10.33.0"`, `prek = "latest"`
- `darwin/Brewfile` — has `brew "bun"` (broken, not in Homebrew core)
- `.chezmoiscripts/run_onchange_after_setup-gstack.sh.tmpl` — uses `command -v bun` guard (works with mise shims)
- `dot_config/safehouse/config.tmpl` line 17 — `runtime-managers.sb` profile covers `~/.local/share/mise` (rw), so mise-installed bun is accessible in sandbox

### External References

- mise has a built-in `core:bun` backend — no external plugin needed
- `oven-sh/homebrew-bun` tap exists as an alternative but would introduce a tap dependency for a tool that fits better in mise

## Key Technical Decisions

- **mise over Homebrew tap**: node and pnpm are already managed by mise; bun is in the same category (JS runtime/toolchain). Using mise maintains consistency and enables version pinning across machines. The alternative (`tap "oven-sh/bun"` + `brew "oven-sh/bun/bun"`) would work but diverges from established patterns for JS tools in this repo.
- **`"latest"` version**: Matches the pattern used for `prek` and avoids manual version bumps. Can be pinned later if stability requires it.

## Implementation Units

- [x] **Unit 1: Remove bun from Brewfile**

**Goal:** Remove the broken `brew "bun"` entry from the Brewfile

**Requirements:** R1

**Files:**
- Modify: `darwin/Brewfile`

**Approach:**
- Delete line 11 (`brew "bun"`)

**Test expectation:** none — declarative config removal, verified by `make lint`

**Verification:**
- `brew "bun"` no longer appears in the Brewfile

- [x] **Unit 2: Add bun to mise config**

**Goal:** Declare bun in mise so it is installed and available on PATH via mise shims

**Requirements:** R1, R2

**Dependencies:** Unit 1

**Files:**
- Modify: `dot_config/mise/config.toml`

**Approach:**
- Add `bun = "latest"` under `[tools]`, alongside existing node/pnpm entries

**Patterns to follow:**
- `dot_config/mise/config.toml` existing entries (`node = "24"`, `pnpm = "10.33.0"`, `prek = "latest"`)

**Test scenarios:**
- Happy path: `mise ls bun` shows an installed version after `mise install`
- Happy path: `command -v bun` resolves to a mise shim path

**Verification:**
- `bun = "latest"` appears in `[tools]` section of `dot_config/mise/config.toml`
- `chezmoi apply --dry-run` shows the config change
- After `chezmoi apply && mise install`, `bun --version` returns a valid version

## System-Wide Impact

- **Interaction graph:** `run_onchange_after_setup-gstack.sh.tmpl` depends on `command -v bun` — this resolves via mise shims after the change, which works identically
- **Sandbox:** `runtime-managers.sb` profile already grants read-write access to `~/.local/share/mise`, so mise-managed bun is accessible in the Claude Code sandbox

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| mise not initialized before gstack setup script runs | mise is installed via Homebrew and initialized in zsh config; `run_onchange_after_` scripts run after file targets, so mise config is deployed first. The existing `command -v bun` guard provides a safe fallback |
