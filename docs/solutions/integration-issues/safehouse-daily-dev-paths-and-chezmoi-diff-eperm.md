---
title: "Safehouse sandbox config missing paths for daily development tools"
category: integration-issues
date: 2026-03-20
severity: medium
tags:
  - safehouse
  - sandbox
  - chezmoi
  - cco
  - seatbelt
  - macos
  - shell-init
  - docker
affected_components:
  - dot_config/safehouse/config.tmpl
  - .chezmoiexternal.toml
  - dot_config/zsh/sandbox.zsh
related:
  - docs/solutions/integration-issues/migrate-cco-to-agent-safehouse.md
  - docs/solutions/integration-issues/safehouse-cli-flag-internals-and-config-patterns.md
  - docs/solutions/integration-issues/cco-sandbox-chezmoi-read-only-access.md
  - docs/solutions/runtime-errors/cco-sandbox-hook-and-git-eperm.md
---

# Safehouse sandbox config missing paths for daily development tools

## Problem

After migrating the Claude Code sandbox from cco to agent-safehouse (commit `48c4ebf`), `chezmoi diff` failed inside the sandbox:

```
chezmoi: lstat $HOME/.local/share/cco: operation not permitted
```

`~/.local/share/cco` is a git repo pulled by `.chezmoiexternal.toml` (Linux fallback). chezmoi needs to `lstat` it during diff operations, but the path was absent from the safehouse allowlist.

Additionally, several other daily development paths were missing: Bun, pnpm state, agent skills, and editor configs (`helix`, `karabiner`, `opencode`, `zed`). No enable modules were configured for Docker, shell startup files, clipboard, or process control.

## Root Cause

The safehouse config (`dot_config/safehouse/config.tmpl`) contained only minimal path allowlists from the initial migration. Two categories of gaps:

1. **chezmoi diff requires bidirectional read access.** The source directory (`~/.local/share/chezmoi`) was allowed, but chezmoi also reads all *target* (destination) files to compute diffs. Every managed target path must be readable inside the sandbox.

2. **Daily development tool paths were not ported.** After migrating from cco, the config file was created with a minimal set. Tool directories like `~/.bun`, `~/.pnpm-state`, `~/.agents`, and various `~/.config/*` subdirectories were missing.

## Solution

Four categories of changes to `dot_config/safehouse/config.tmpl`:

### 1. Enable built-in safehouse modules

```
--enable=docker
--enable=shell-init
--enable=clipboard
--enable=process-control
```

- `docker` covers Docker/Colima operations, including rw access to `~/.colima` (making any manual entry redundant)
- `shell-init` grants read access to `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zcompdump`, replacing manual entries
- `clipboard` enables system pasteboard access
- `process-control` enables process enumeration/signalling for debugging

### 2. Add read-only paths

```
--add-dirs-ro={{ .chezmoi.homeDir }}/.local/share/cco
--add-dirs-ro={{ .chezmoi.homeDir }}/.bun
--add-dirs-ro={{ .chezmoi.homeDir }}/.pnpm-state
--add-dirs-ro={{ .chezmoi.homeDir }}/.agents
--add-dirs-ro={{ .chezmoi.homeDir }}/.config/helix
--add-dirs-ro={{ .chezmoi.homeDir }}/.config/karabiner
--add-dirs-ro={{ .chezmoi.homeDir }}/.config/opencode
--add-dirs-ro={{ .chezmoi.homeDir }}/.config/zed
```

### 3. Cleanup

- **Removed** manual `~/.colima` entry (redundant with `--enable=docker`)
- **Removed** manual `~/.zshrc` and `~/.zprofile` entries (covered by `--enable=shell-init`)
- **Moved** `~/.local/share/cco` from "chezmoi" section to "Binaries and tools" for correct grouping

## Key Insights

### chezmoi diff needs both source and target access

This is the most important takeaway. `chezmoi diff` compares the *rendered source* against the *deployed target*. Read access to `~/.local/share/chezmoi` alone is insufficient -- every managed target path (`~/.config/*`, `~/.*`) must also be readable.

When adding a new chezmoi external repo (`.chezmoiexternal.toml`), check whether the target path is already covered by a built-in profile or needs an explicit `--add-dirs-ro` entry.

### shell-init does NOT cover bash home dotfiles

The `--enable=shell-init` module covers:
- `~/.zshenv`, `~/.zprofile`, `~/.zshrc`, `~/.zcompdump` (zsh)
- `/private/etc/bashrc`, `/private/etc/profile`, `/private/etc/paths` (system-level)
- Fish config files

It does **not** cover `~/.bashrc` or `~/.bash_profile`. Manual `--add-dirs-ro` entries must be retained for those.

### Built-in modules can subsume manual entries

`--enable=docker` provides rw access to `~/.colima` and Docker-related paths. When enabling a module, audit existing manual entries for redundancies. Use `safehouse --explain --stdout` to inspect the assembled policy.

## Prevention

### When adding a new tool

1. Identify all paths the tool touches under `$HOME`
2. Check if a safehouse built-in module or profile covers them (`safehouse --explain --stdout`)
3. Prefer `--enable=<module>` when it covers 3+ paths; prefer `--add-dirs-ro` for individual paths
4. Place the entry in the correct section of the config file
5. Test inside the sandbox: run `claude` and exercise the tool

### When adding a chezmoi external repo

1. The source directory (`~/.local/share/chezmoi`) is already allowed
2. Add `--add-dirs-ro` for the target path if not covered by a built-in profile
3. Test with `chezmoi diff` inside the sandbox

### Periodic audit

Cross-reference `chezmoi managed` output with sandbox config. Every managed target path must be reachable:

```sh
chezmoi managed | sed 's|/.*||' | sort -u
```

### Diagnosing EPERM failures

```sh
# Show assembled Seatbelt policy
safehouse --explain --stdout 2>&1 | grep <path>

# Check macOS Console.app for Seatbelt violation logs
# Filter by process name: node, claude

# Quick path test inside sandbox
cat ~/.config/newTool/config.toml  # EPERMs if missing
```
