---
title: "cco --safe sandbox: codex MCP server fails with EPERM on config.toml"
date: 2026-03-18
category: runtime-errors
tags: [cco, sandbox, seatbelt, codex, mcp, eperm, allow-paths, openai]
module: cco sandbox configuration, codex MCP server
symptom: "Error: error loading config: Failed to read config file ~/.codex/config.toml: Operation not permitted (os error 1)"
root_cause: "cco --safe Seatbelt policy denies file-read* under $HOME; ~/.codex not in allow-paths"
---

# cco --safe sandbox: codex MCP server fails with EPERM on config.toml

## Problem

The codex MCP server (OpenAI Codex CLI in `mcp-server` mode) fails to start inside the cco `--safe` sandbox. The error:

```
Error: error loading config: Failed to read config file /Users/<user>/.codex/config.toml: Operation not permitted (os error 1)
```

codex works normally outside the sandbox.

## Root Cause

The cco `--safe` Seatbelt policy denies `file-read*` under `$HOME`. The codex CLI unconditionally reads `~/.codex/config.toml` at startup. Since `~/.codex` was not listed in `dot_config/cco/allow-paths.tmpl`, the `open()` syscall for `config.toml` was denied by the sandbox.

The `file-read-metadata` patch (allowing `stat`/`lstat` on `$HOME`) does not help here — codex needs actual `file-read-data` (i.e., `open()` + `read()`) access, not just metadata.

### Why only codex was affected

Other MCP servers use HTTP transport (newrelic, figma, deepwiki) or remote proxying (notion via mcp-remote). codex is the only stdio MCP server that reads a config directory under `$HOME`.

### Full list of ~/.codex access needs

| Path | Access | Purpose |
|------|--------|---------|
| `config.toml` | rw | User configuration |
| `credentials.json` | rw | OAuth tokens (fallback when Keychain unavailable) |
| `skills/` | rw | Custom skills |
| `sessions/` | rw | Session history |
| `cache/` | rw | Model cache |

## Solution

Add `~/.codex` with read-write access to `dot_config/cco/allow-paths.tmpl`:

```
# Codex CLI config, credentials, skills, sessions, cache (codex MCP server)
{{ .chezmoi.homeDir }}/.codex
```

Then `chezmoi apply` to deploy the updated allow-paths.

## Prevention

When adding a new stdio-type MCP server that spawns a local CLI tool, check whether the tool reads config files under `$HOME`. If so, add its config directory to `dot_config/cco/allow-paths.tmpl` before testing inside the sandbox.

**Diagnostic pattern:** If an MCP server works outside cco but fails inside, the first thing to check is allow-paths coverage for the tool's config directory.

## Related

- [cco --safe sandbox: hooks and git operations fail with EPERM](cco-sandbox-hook-and-git-eperm.md) — same root cause class (missing allow-paths entries)
- [CCO_SANDBOX_ARGS_FILE backend passthrough only](../integration-issues/cco-sandbox-args-file-backend-passthrough-only.md)
