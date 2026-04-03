---
title: "feat: Configure cco sandbox for daily Claude Code usage"
type: feat
status: completed
date: 2026-03-17
---

# feat: Configure cco sandbox for daily Claude Code usage

## Enhancement Summary

**Deepened on:** 2026-03-17
**Sections enhanced:** All
**Research agents used:** cco source analysis, security sentinel, pattern recognition, simplicity review, learnings review

### Key Improvements from Research
1. **`--safe` mode is essential** — without it, the entire filesystem is readable (Seatbelt only denies writes by default)
2. **Removed sandbox-args file** — `CCO_SANDBOX_ARGS_FILE` passes args as backend passthrough, NOT cco-level flags; `--deny-path` in that file would silently fail
3. **Glob patterns don't work** — `--deny-path ~/.ssh/id_*` would look for literal file `id_*`; must deny whole directories
4. **dot_zshrc is NOT a .tmpl** — must use `$HOME` not `{{ .chezmoi.homeDir }}`

### Critical Bugs Found in Original Plan
- `--deny-path` in `CCO_SANDBOX_ARGS_FILE` would be passed to sandbox-exec as raw backend args, not processed by cco's argument parser — **silent misconfiguration**
- Glob `~/.ssh/id_*` would not expand — `resolve_path()` treats it as a literal filename
- Adding template syntax to non-template `dot_zshrc` would output literal `{{ }}` strings

## Overview

cco (Claude Container) is already installed at `~/bin/cco` via chezmoi's `.chezmoiexternal.toml` + symlink script. The tool is functional (`cco info` shows "Ready to use"). This plan covers the remaining configuration to make cco the default way to run Claude Code in a sandboxed environment on macOS.

## Current State

- **Installation**: cco repo pulled to `~/.local/share/cco/` via `.chezmoiexternal.toml` (SHA-pinned, Renovate auto-updates)
- **Symlink**: `~/bin/cco` → `~/.local/share/cco/cco` (managed by `run_onchange_after_link-cco.sh.tmpl`)
- **Backend**: macOS native sandbox (`sandbox-exec` / Seatbelt) available — lightweight, no Docker overhead
- **Docker**: Available but image not built (Docker is fallback, not needed on macOS)
- **Auth**: Keychain-based authentication working

### Default Seatbelt Security Posture (without --safe)

The native sandbox generates this policy by default:
```
(allow default)
(deny file-write*)
```

This means: **all reads are allowed**, only writes are restricted to PWD + temp dirs. Claude can read `~/.ssh`, `~/.aws`, `~/.zsh_history`, `~/.env`, browser profiles — anything your user can read. This is why `--safe` mode is critical.

### --safe Mode Security Posture

With `--safe`, the policy adds:
```
(deny file-read* (subpath "/Users/<user>"))
```

Then only the project directory (PWD) and explicitly allowed paths are re-enabled. This is an **allowlist** approach — fundamentally more secure than denylisting individual sensitive paths.

## What Needs Configuration

### Phase 1: Shell Alias with --safe (sole change)

Add a shell alias so `claude` invocations go through cco with `--safe` mode by default.

**File**: `dot_zshrc` (in the existing Aliases section, after line 55)

```zsh
alias claude='cco --safe'
```

**Rationale**:
- Drop-in replacement — `cco` passes all arguments through to `claude`
- `--safe` hides `$HOME` from reads, providing meaningful isolation
- Use `command claude` or `\claude` to bypass the alias when needed
- Alias is sufficient for interactive shells (primary use case)

### Research Insights

**Why alias over wrapper script:**
The security review suggested a wrapper script at `~/bin/claude` for non-interactive shell coverage. However:
- Claude Code is primarily used interactively in terminal sessions
- A wrapper script would shadow the real `claude` binary for ALL invocations, making raw claude harder to access
- The alias approach is consistent with existing patterns in `dot_zshrc` (`ls='eza'`, `diff='difft'`) — none of these use wrapper scripts
- If non-interactive sandboxing is needed later, a wrapper can be added

**Why NOT a sandbox-args file:**
- `CCO_SANDBOX_ARGS_FILE` loads into `sandbox_extra_args[]` which are passed as **backend passthrough args** (after `--`) to sandbox-exec/bwrap/docker
- cco-level flags like `--deny-path`, `--safe`, `--allow-readonly` are NOT processed from this file — they must be CLI arguments
- The file is designed for Docker `-p` port forwards and bwrap-specific flags, not cco configuration
- Adding `--deny-path` to this file would result in sandbox-exec receiving unknown arguments, causing silent misconfiguration or errors

**Why --safe over individual --deny-path:**
- Allowlist (--safe + selective --allow-readonly) is fundamentally more secure than denylist (individual --deny-path entries)
- You will inevitably miss sensitive paths in a denylist approach
- `--safe` hides the entire `$HOME` with one flag, then you selectively re-expose what's needed
- If Claude needs configs (e.g., `~/.gitconfig`), cco already handles common needs; specific allows can be added to the alias as discovered

**Edge cases with --safe mode:**
- Some dev tools may fail if they need config from `$HOME` (e.g., `.npmrc`, `.gitconfig`)
- cco automatically exposes `~/.claude/` for Claude's own config
- Git operations work via ssh-agent / 1Password agent socket (no direct key file access needed)
- If a specific path needs read access, add `--allow-readonly ~/.config/tool` to the alias

## Acceptance Criteria

- [x] `claude "hello"` runs through cco sandbox with --safe mode (alias active)
- [x] `cco info` continues to show "Ready to use"
- [x] `chezmoi apply --dry-run` shows no unexpected changes (only zshrc +1 line)
- [x] Raw `claude` accessible via `command claude` or `\claude`
- [ ] Git operations work within sandbox (ssh-agent/1Password forwarding) — verify post-apply
- [ ] MCP servers on localhost remain accessible — verify post-apply

## Technical Considerations

- **Performance**: Native sandbox (`sandbox-exec`) has negligible overhead vs raw `claude`
- **MCP Servers**: cco uses host networking — all MCP servers on localhost remain accessible
- **Credentials**: Keychain access works natively without `--allow-keychain` on macOS Seatbelt
- **Git worktrees**: cco auto-detects and mounts git worktree common dirs
- **Network**: Unrestricted by design — required for Claude API and MCP servers. Mitigated by --safe hiding credential files from reads
- **Non-interactive shells**: Alias only applies to interactive zsh sessions. Scripts calling `claude` directly will use the unsandboxed binary. This is an accepted trade-off for simplicity.

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `dot_zshrc` | Modify | Add `alias claude='cco --safe'` in Aliases section |

**No new files needed.** Total change: 1 line in an existing file.

## Dependencies & Risks

- **Low risk**: Single additive alias in existing file
- **Reversibility**: Remove the alias line to revert
- **Dependency**: `~/bin` must be in `$PATH` (already is, per existing symlink working)
- **--safe mode risk**: Some tools may fail if they need `$HOME` configs. Mitigation: add `--allow-readonly` paths to alias as discovered. Use `\claude` for unsandboxed fallback.

## Future Enhancements (not in scope)

These can be added when a concrete need arises:
- **Wrapper script** at `~/bin/claude` for non-interactive shell coverage
- **Additional --allow-readonly** paths if --safe breaks specific workflows
- **Docker image build** (`cco --rebuild`) for stronger isolation if native sandbox proves insufficient
