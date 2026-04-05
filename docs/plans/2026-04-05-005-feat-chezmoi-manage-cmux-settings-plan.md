---
title: "feat: Add cmux settings.json to chezmoi management"
type: feat
status: completed
date: 2026-04-05
---

# feat: Add cmux settings.json to chezmoi management

## Overview

Add `~/.config/cmux/settings.json` to chezmoi management so cmux configuration is declarative and portable across machines.

## Problem Frame

cmux (terminal multiplexer app) is installed via Homebrew cask but its configuration is not yet managed by chezmoi. The app has not been launched yet on this machine, so no settings file exists. We need to create a settings.json with sensible defaults and manage it through chezmoi.

## Requirements Trace

- R1. Create `~/.config/cmux/settings.json` with a baseline configuration
- R2. Manage the file through chezmoi using the appropriate pattern
- R3. Follow existing chezmoi patterns in this repository

## Scope Boundaries

- Not configuring custom keybindings or themes — those can be added later
- Not managing cmux's Application Support directory or runtime state
- Not adding cmux CLI to PATH (already handled by Homebrew symlink)

## Context & Research

### Relevant Code and Patterns

- `dot_config/ghostty/config` — static config file managed by chezmoi (no `.tmpl`)
- `dot_config/helix/config.toml` — another static config file
- `dot_config/zellij/config.kdl` — same pattern
- `.chezmoiignore` — currently has `*.txt` and `*.sh` glob exclusions; `dot_config/cmux/settings.json` uses `.json` extension which is not excluded

### cmux Settings Architecture

cmux settings are stored in two locations (in precedence order):
1. `~/.config/cmux/settings.json` (primary, file-managed)
2. `~/Library/Application Support/com.cmuxterm.app/settings.json` (fallback, app-managed)

File-managed values override Settings window values. Removing a key reverts to the Settings window value. This means the file acts as an **overlay** — chezmoi can fully own it since it only contains intentional overrides.

The file accepts JSON with comments and trailing commas. Schema is available at:
`https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json`

## Key Technical Decisions

- **Regular file (not `.tmpl`)**: No template variables needed — cmux settings don't reference `homeDir`, `.profile`, or `.ghOrg`. A plain JSON file is simplest.
- **Full ownership (not `modify_`)**: Since the file is an overlay on app-managed defaults, chezmoi should fully own it. Users change settings via the file, not the Settings UI.
- **Minimal initial config**: Start with key settings (telemetry opt-out, Claude Code integration enabled, appearance) rather than dumping all defaults. Unspecified keys use app defaults.

## Open Questions

### Resolved During Planning

- **Which chezmoi pattern?** Regular file — cmux's file-managed settings are an overlay, not a runtime-mutable file. No `.tmpl` needed since no template variables are referenced.
- **Where in source tree?** `dot_config/cmux/settings.json` — follows the existing `dot_config/<app>/` convention.

### Deferred to Implementation

- **Exact settings values**: The user may want to customize specific settings after seeing the defaults. Start with a minimal overlay.

## Implementation Units

- [x] **Unit 1: Create cmux settings.json in chezmoi source**

  **Goal:** Add `dot_config/cmux/settings.json` to the chezmoi source tree with a baseline configuration.

  **Requirements:** R1, R2, R3

  **Dependencies:** None

  **Files:**
  - Create: `dot_config/cmux/settings.json`

  **Approach:**
  - Create `dot_config/cmux/` directory
  - Write a minimal `settings.json` with `$schema` reference for editor validation
  - Include key settings: telemetry opt-out, Claude Code integration, appearance
  - Use standard JSON (cmux supports comments but standard JSON is safer for linters)

  **Patterns to follow:**
  - `dot_config/ghostty/config` — static config file, no template
  - `dot_config/helix/config.toml` — same pattern

  **Test expectation:** none — pure config file creation, no behavioral logic

  **Verification:**
  - `chezmoi managed | grep cmux` shows the file
  - `chezmoi apply --dry-run` shows no errors
  - `chezmoi cat-config` or `chezmoi cat ~/.config/cmux/settings.json` produces valid JSON

## System-Wide Impact

- **Interaction graph:** None — standalone config file with no callbacks or dependencies
- **Error propagation:** Invalid JSON would cause cmux to ignore the file and fall back to app defaults (safe failure)
- **Unchanged invariants:** No existing files or configs are modified

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| oxfmt/oxlint may try to format/lint the JSON file | Verify these tools only target explicitly configured paths; cmux settings.json should be included naturally in `*.json` glob if oxfmt runs |

## Sources & References

- cmux configuration docs: https://cmux.com/docs/configuration
- Schema: https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json
