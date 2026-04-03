---
title: "fix: codex MCP blocked in cco sandbox"
type: fix
status: completed
date: 2026-03-18
---

# fix: codex MCP blocked in cco sandbox

## Enhancement Summary

**Deepened on:** 2026-03-18
**Sections enhanced:** 3 (Root Cause, codex Runtime, Verification)
**Research agents used:** repo-research-analyst, learnings-researcher, Explore (codex source analysis)

### Key Improvements
1. Full inventory of codex's `$HOME` file access requirements from source analysis
2. Confirmed git config and Keychain paths already covered by existing allow-paths
3. Added `CODEX_HOME` env var alternative approach and why allow-paths is preferred

## Overview

codex MCP server fails to start inside cco `--safe` sandbox because `~/.codex/` is inaccessible. The Seatbelt policy denies `file-read*` under `$HOME`, and `~/.codex` is not listed in the allow-paths configuration.

## Problem Statement

When Claude Code runs inside cco `--safe` mode, the codex MCP server (spawned as a stdio child process) inherits the Seatbelt sandbox restrictions. codex unconditionally reads `~/.codex/config.toml` at startup, which triggers:

```
Error: error loading config: Failed to read config file $HOME/.codex/config.toml: Operation not permitted (os error 1)
```

Outside the sandbox, codex reads `~/.codex/config.toml` freely and connects successfully.

## Root Cause Analysis

### Seatbelt Policy Chain (cco --safe)

1. `(allow default)` — everything allowed
2. `(deny file-write* ...)` — deny writes to specific paths
3. `(deny file-read* (subpath "$HOME"))` — deny ALL reads under $HOME
4. `(allow file-read-metadata (subpath "$HOME"))` — re-allow lstat/stat (metadata patch)
5. `(allow file-read* (subpath "PATH"))` — re-allow reads for each allow-path entry

Step 3 blocks codex from `open()`-ing `~/.codex/config.toml`. The `file-read-metadata` patch (step 4) only allows `stat`/`lstat`, not `read`/`open` for file contents. No allow-path entry exists for `~/.codex`.

### Why Only codex Is Affected

Other MCP servers in the config use HTTP transport (newrelic, figma, deepwiki) or remote proxying (notion via `mcp-remote`), which don't read config files under `$HOME`. codex is the only stdio MCP server that reads a config directory under `$HOME`.

### codex Runtime Behavior (from source analysis)

Full inventory of `~/.codex/` (or `$CODEX_HOME`) access:

| Path | Access | Purpose |
|------|--------|---------|
| `config.toml` | rw | User configuration |
| `credentials.json` | rw | OAuth tokens (fallback when Keychain unavailable) |
| `skills/` | rw | Custom skills |
| `sessions/` | rw | Conversation/session history |
| `cache/` | rw | Model cache |
| `.codex-system-skills` | rw | System skills marker |

**Other `$HOME` paths codex reads** (already in allow-paths):
- `~/.gitconfig` — ✅ already allowed (`:ro`)
- `~/.config/git/` — ✅ already allowed (`:ro`)
- `~/Library/Keychains` — ✅ already allowed (`:ro`, macOS Keychain for credentials)

**Conclusion:** Adding `~/.codex` rw is the only missing piece.

## Proposed Solution

Add `~/.codex` to `dot_config/cco/allow-paths.tmpl` with read-write access.

### File to Edit

`dot_config/cco/allow-paths.tmpl` — add after the Claude Code entry (line 28):

```
# Codex CLI config, credentials, skills, sessions, cache (codex MCP server)
{{ .chezmoi.homeDir }}/.codex
```

No `:ro` suffix — codex needs write access for credentials, skills, sessions, and cache.

### Alternative Considered: `CODEX_HOME` env var

codex supports `CODEX_HOME` to override the default `~/.codex` location. We could set `CODEX_HOME` to a path already in the sandbox (e.g., under `~/.cache/codex`).

**Rejected because:**
- Separates codex config from its standard location, complicating manual troubleshooting
- Would need to be set both in MCP server config (`env` field in mcp-servers.json) and in any direct `codex` invocations
- The allow-paths pattern is the established approach for granting sandbox access (consistent with git, gh, SSH, etc.)

## Acceptance Criteria

- [x] `~/.codex` added to `dot_config/cco/allow-paths.tmpl` with rw access
- [x] `chezmoi apply` deploys the updated allow-paths
- [x] codex MCP server starts successfully inside cco sandbox (`claude mcp list` shows codex connected)
- [x] codex MCP tools are callable from within the sandbox

## Verification Steps

1. `chezmoi diff` — confirm allow-paths change
2. `chezmoi apply` — deploy
3. Open new terminal, start `claude` (which invokes cco --safe via shell function)
4. Run `claude mcp list` — codex should appear as connected
5. Use a codex tool to confirm end-to-end functionality

**Debug if still failing:**
- `CCO_DEBUG=1 claude` — inspect the actual `sandbox-exec` command and Seatbelt profile
- Check if codex needs additional paths not yet discovered (e.g., Node.js temp files)
- Verify `~/.codex/` directory exists: codex may need it created first

## Sources

- Existing pattern: `docs/solutions/runtime-errors/cco-sandbox-hook-and-git-eperm.md`
- Memory: `cco_sandbox_args_file_limitation.md`, `cco_seatbelt_file_read_metadata.md`
- Allow-paths config: `dot_config/cco/allow-paths.tmpl`
- MCP server definitions: `dot_claude/mcp-servers.json`
- codex source: `/opt/homebrew/lib/node_modules/@openai/codex/`
