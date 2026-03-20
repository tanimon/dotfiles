---
title: "Migrate Claude Code sandbox from cco to agent-safehouse"
category: integration-issues
date: 2026-03-20
severity: medium
tags: [cco, agent-safehouse, seatbelt, sandbox, macos, chezmoi]
related:
  - cco-sandbox-args-file-backend-passthrough-only.md
  - cco-sandbox-chezmoi-read-only-access.md
  - ../runtime-errors/cco-sandbox-hook-and-git-eperm.md
  - ../runtime-errors/cco-seatbelt-upstream-fix-wildcard-precedence.md
---

# Migrate Claude Code sandbox from cco to agent-safehouse

## Problem

cco (Claude Condom) requires manual Seatbelt patches for Node.js compatibility (`file-read-metadata` EPERM), has an allow-default security model (`(allow default)` base), and limited configuration (`CCO_SANDBOX_ARGS_FILE` is backend passthrough only). agent-safehouse provides deny-all default, composable profiles, and built-in Node.js compatibility.

## Root Cause

cco's `--safe` mode denies all `file-read*` under `$HOME` but Node.js `realpathSync` needs `file-read-metadata` on `$HOME` during module loading. This required a custom awk patch script. safehouse's base profile handles this natively.

## Solution

### 1. safehouse profiles auto-cover many cco allow-paths

Key mapping of what safehouse handles automatically (no config needed):

| safehouse profile | Auto-covers |
|---|---|
| `claude-code.sb` (60-agents/) | `~/.claude` (rw), `~/.claude.json` (rw), `~/.local/share/claude`, `~/.local/bin/claude` |
| `keychain.sb` (auto-required by claude-code) | `~/Library/Keychains` |
| `git.sb` (50-integrations-core/) | `~/.gitconfig`, `~/.gitignore`, `~/.config/git`, `~/.ssh/config`, `~/.ssh/known_hosts` |
| `scm-clis.sb` (50-integrations-core/) | `~/.config/gh` (rw) |
| `runtime-managers.sb` (30-toolchains/) | `~/.local/share/mise`, `~/.config/mise` (rw) |

Opt-in modules via `--enable=`:
- `ssh` — SSH agent socket (for git push/pull, 1Password signing)
- `1password` — 1Password agent socket and config
- `keychain` — auto-included by claude-code.sb (no explicit `--enable` needed)

### 2. Shell wrapper with fallback chain

```zsh
# dot_config/zsh/sandbox.zsh
claude() {
  if command -v safehouse &>/dev/null; then
    _claude_safehouse "$@"    # Primary: deny-all sandbox
  elif command -v cco &>/dev/null; then
    _claude_cco "$@"          # Fallback: allow-default sandbox
  else
    command claude "$@"        # No sandbox available
  fi
}
```

The wrapper reads config from `~/.config/safehouse/config` (one CLI flag per line) and passes all flags to safehouse.

### 3. Config file format

`dot_config/safehouse/config.tmpl` uses chezmoi templates and contains safehouse CLI flags:

```
--enable=ssh
--enable=1password
--add-dirs={{ .chezmoi.homeDir }}/ghq
--add-dirs={{ .chezmoi.homeDir }}/.cache
--add-dirs-ro={{ .chezmoi.homeDir }}/.local/bin
```

### 4. cco retained as fallback

cco remains in `.chezmoiexternal.toml` for Linux fallback (safehouse is macOS-only). The symlink and patch scripts are untouched.

### 5. `--dangerously-skip-permissions` behavior

Both cco and safehouse pass `--dangerously-skip-permissions` to Claude Code. cco injects it internally via `apply_claude_mode_arg_policies()`. For safehouse, the shell wrapper passes it explicitly since safehouse is a generic launcher (not Claude-specific).

## Prevention / Best Practices

- When adding new tools to the sandbox, check `safehouse --explain --stdout` to see the assembled policy before running
- Use `--add-dirs-ro` (not `--add-dirs`) for paths that don't need write access
- Check safehouse's built-in profiles before adding explicit paths — many common tools (git, gh, mise, Node.js, Python, Go, Rust) are already covered
- For machine-specific overrides, use `--append-profile` with a local `.sb` file

## Related

- (auto memory [claude]) cco Seatbelt file-read-metadata fix — the Node.js EPERM issue that safehouse handles natively
- (auto memory [claude]) Seatbelt wildcard precedence — `(allow file-read-metadata)` wins over `(deny file-read*)` regardless of rule order
- (auto memory [claude]) CCO_SANDBOX_ARGS_FILE limitation — safehouse's `--append-profile` properly solves this
