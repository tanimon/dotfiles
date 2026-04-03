---
title: "feat: Enable everything-claude-code plugin and manage via chezmoi"
type: feat
status: completed
date: 2026-04-03
---

# feat: Enable everything-claude-code plugin and manage via chezmoi

## Overview

Enable the `everything-claude-code` (ECC) plugin which is already installed as a marketplace plugin but explicitly disabled in `settings.json.tmpl`. ECC provides agents, skills, commands, and hooks that extend Claude Code capabilities. The plugin system handles all content delivery — no separate `install.sh` is needed since the user's own curated rules already cover the same directories.

## Problem Frame

ECC v1.9.0 is registered as a marketplace, downloaded to `~/.claude/plugins/marketplaces/everything-claude-code/`, and listed in `installed_plugins.json`, but disabled via `enabledPlugins` in `settings.json.tmpl` (line 232: `"everything-claude-code@everything-claude-code": false`). The marketplace registration is already managed declaratively via `dot_claude/plugins/marketplaces.txt` and `extraKnownMarketplaces` in settings. The only missing piece is flipping the enable flag.

## Requirements Trace

- R1. Enable ECC plugin so its 37+ agents, 142+ skills, 68+ commands, and hooks are active
- R2. Maintain chezmoi as the single source of truth for the plugin enable/disable state
- R3. Avoid conflicts with existing user-managed rules in `dot_claude/rules/`
- R4. Ensure hooks from ECC `hooks.json` don't conflict with existing hooks in `settings.json.tmpl`

## Scope Boundaries

- NOT running ECC's `install.sh` — user already has curated rules in `dot_claude/rules/` that cover the same directories (common/, golang/, typescript/)
- NOT adding ECC's `.mcp.json` servers — these are project-scoped configs, not user-scoped
- NOT modifying the marketplace registration — already correctly managed

## Context & Research

### Relevant Code and Patterns

- `dot_claude/settings.json.tmpl:232` — current `enabledPlugins` with ECC set to `false`
- `dot_claude/plugins/marketplaces.txt:1` — `affaan-m/everything-claude-code` already registered
- `dot_claude/settings.json.tmpl:249-252` — `extraKnownMarketplaces` entry for ECC already present

### Hook Conflict Analysis

ECC's `hooks.json` provides hooks via the plugin system (`$CLAUDE_PLUGIN_ROOT` paths). User's `settings.json.tmpl` has hooks in the top-level `hooks` key. These use different mechanisms:
- **User hooks** (settings.json): SessionStart cleanup, Notification, PostToolUse formatters, Stop notification, UserPromptSubmit activators
- **ECC hooks** (plugin hooks.json): PreToolUse guards (block-no-verify, commit-quality, config-protection), PostToolUse logging, Stop format/typecheck/session-end, SessionStart bootstrap

These are additive — plugin hooks run alongside settings hooks. The only potential overlap is PostToolUse file formatting (user has gofmt/pnpm lint, ECC has Biome/Prettier at Stop time). Since ECC's format runs at Stop phase (not per-edit) and targets JS/TS specifically, there's no direct conflict. ECC hooks also use a flag system (`run-with-flags.js`) gated by `ECC_HOOK_PROFILE` environment variable (minimal/standard/strict), defaulting to disabled for most hooks unless explicitly enabled.

## Key Technical Decisions

- **Enable via settings.json.tmpl only**: The `enabledPlugins` key in chezmoi-managed settings is the correct and only control point. No runtime mutation needed.
- **No rules installation**: User's existing `dot_claude/rules/` are more specific and curated than ECC's generic rules. ECC's plugin system doesn't install rules — those require `install.sh` which we intentionally skip.
- **No ECC hook profile environment variable**: Leave ECC hooks at their default gating. User can later set `ECC_HOOK_PROFILE` in `settings.json.tmpl` `env` section if desired.

## Implementation Units

- [ ] **Unit 1: Enable ECC plugin in settings.json.tmpl**

**Goal:** Flip `everything-claude-code@everything-claude-code` from `false` to `true` in `enabledPlugins`

**Requirements:** R1, R2

**Dependencies:** None

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- Change line 232 from `"everything-claude-code@everything-claude-code": false` to `"everything-claude-code@everything-claude-code": true`

**Patterns to follow:**
- Other enabled plugins in the same file (e.g., `"compound-engineering@compound-engineering-plugin": true`)

**Test scenarios:**
- Happy path: `chezmoi apply --dry-run` shows the settings.json change with the flag flipped to true
- Happy path: After `chezmoi apply`, `claude plugin list` shows ECC as enabled
- Integration: ECC skills appear in the skill list for a new Claude Code session

**Verification:**
- `chezmoi diff` shows only the boolean change from false to true
- `claude plugin list` shows `everything-claude-code@everything-claude-code` with `Status: ✔ enabled`

## System-Wide Impact

- **Interaction graph:** ECC plugin hooks will now fire alongside user's existing hooks. ECC's `run-with-flags.js` system gates most hooks by `ECC_HOOK_PROFILE` — only `session:start`, `post:bash:command-log-audit`, `post:bash:command-log-cost`, and `pre:bash:block-no-verify` run by default
- **Error propagation:** ECC hooks that fail should not block Claude Code operation (most are async with timeouts)
- **State lifecycle risks:** ECC's session-start bootstrap may create state files in `~/.claude/`. These are not managed by chezmoi (excluded via `.chezmoiignore`)
- **Unchanged invariants:** User's own rules in `dot_claude/rules/`, user's own hooks in `settings.json.tmpl`, marketplace registration — all unchanged

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| ECC hooks add latency to Claude Code sessions | Most ECC hooks are async with short timeouts (5-30s). Monitor and disable if problematic |
| ECC skills conflict with user's existing skills from other plugins | ECC skills are namespaced under `everything-claude-code:`. User can disable individual skills if needed |
| ECC hooks fail due to missing Node.js dependencies | ECC marketplace directory includes its own `node_modules`. If missing, hooks fail gracefully (exit 0 with warning) |

## Sources & References

- ECC repository: https://github.com/affaan-m/everything-claude-code
- ECC plugin.json: `.claude-plugin/plugin.json` (37 agents, skills directory, commands directory)
- ECC hooks.json: `hooks/hooks.json` (PreToolUse, PostToolUse, Stop, SessionStart, SessionEnd)
