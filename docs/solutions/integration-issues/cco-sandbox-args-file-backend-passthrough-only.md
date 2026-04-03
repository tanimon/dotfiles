---
title: "cco CCO_SANDBOX_ARGS_FILE only supports backend passthrough, not cco-level flags"
category: integration-issues
tags: [cco, sandbox, chezmoi, shell-function, sandbox-exec]
date: 2026-03-17
module: cco sandbox configuration
symptom: "--add-dir and --deny-path in CCO_SANDBOX_ARGS_FILE silently fail"
root_cause: "File loads into sandbox_extra_args which are passed as backend passthrough (between -- markers) to sandbox-exec/bwrap, not parsed by cco's argument parser"
---

# cco CCO_SANDBOX_ARGS_FILE only supports backend passthrough, not cco-level flags

## Problem

When configuring cco (Claude Code sandbox wrapper) for daily use, the natural approach is to use `CCO_SANDBOX_ARGS_FILE` for persistent configuration. However, putting cco-level flags like `--add-dir`, `--deny-path`, or `--safe` in this file causes them to be silently mishandled — they are passed raw to the low-level sandbox backend instead of being processed by cco.

## Investigation

### What CCO_SANDBOX_ARGS_FILE actually does

Source: `~/.local/share/cco/cco` lines 1644-1656

```bash
# File reading (cco:1647-1651)
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    sandbox_extra_args+=("$line")
done <"$CCO_SANDBOX_ARGS_FILE"
```

### How sandbox_extra_args is consumed

**Native sandbox (macOS Seatbelt)** — cco:907-908:
```bash
cmd+=("--" "${sandbox_extra_args[@]}" "--")
```
Args go between `--` markers → sandbox script's `backend_extra_args` → passed directly to `sandbox-exec`.

**Docker backend** — cco:1427-1429:
```bash
docker_args+=("${sandbox_extra_args[@]}")
```
Args become Docker CLI flags (e.g., `-p 3000:3000`, `-v /path:/path`).

### The key distinction

| Flag type | Parsed by | Works in CCO_SANDBOX_ARGS_FILE? |
|-----------|-----------|-------------------------------|
| `--add-dir PATH` | cco main arg parser | No — silently fails |
| `--deny-path PATH` | cco main arg parser | No — silently fails |
| `--safe` | cco main arg parser | No — silently fails |
| `--allow-readonly PATH` | cco main arg parser | No — silently fails |
| `-p 3000:3000` (Docker) | Docker CLI | Yes |
| `-v /host:/container` (Docker) | Docker CLI | Yes |

### Additional discovery: glob patterns don't work in --deny-path

cco's `resolve_path()` function (cco:184-201) resolves paths without glob expansion. `--deny-path ~/.ssh/id_*` treats `id_*` as a literal filename, not a pattern.

### Additional discovery: native sandbox defaults

Without `--safe`, the Seatbelt policy is:
```
(allow default)
(deny file-write*)
```
Only writes are denied. All reads are unrestricted. `--safe` adds `(deny file-read* (subpath "$HOME"))`.

## Solution

Use a **shell function + custom config file** instead of `CCO_SANDBOX_ARGS_FILE`:

**~/.config/zsh/cco.zsh** — shell function that reads a custom config:
```zsh
claude() {
  local -a cco_args=(--safe)
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/cco/allow-paths"
  if [[ -f "$config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      cco_args+=(--add-dir "$line")
    done < "$config"
  fi
  command cco "${cco_args[@]}" "$@"
}
```

**~/.config/cco/allow-paths** — simple line-per-path config (chezmoi template):
```
# Paths to allow read-write access in cco sandbox (one per line)
# Append :ro for read-only access (default is :rw)
$HOME/ghq
```

This approach:
- Processes `--add-dir` as cco CLI args (correctly parsed)
- Keeps `--safe` always active (hides $HOME)
- Externalizes path config to a chezmoi-managed file
- Uses `command cco` to prevent infinite recursion
- Gracefully handles missing config file (most restrictive default)

## Prevention

- **Always check the source** when a tool's config file "should work" but doesn't. The variable name `sandbox_extra_args` hints at backend passthrough, not main arg parsing.
- **Use `CCO_DEBUG=1 cco ...`** to see the actual sandbox command being constructed — this reveals where args end up.
- **For deny rules**: deny entire directories (e.g., `~/.ssh`) rather than individual files with globs.
