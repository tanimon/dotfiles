---
title: "cco --safe mode: claude not found in PATH"
category: runtime-errors
date: 2026-03-17
tags: [cco, sandbox, seatbelt, safe-mode, path]
---

## Problem

Running `claude` (via cco shell function) with `--safe` mode produces:

```
▶ Starting cco with native sandbox...
▶ Adding additional directory: /Users/.../ghq
Error: claude not found in PATH
```

## Root Cause

cco's `--safe` mode generates a Seatbelt policy that denies **all** `file-read*` under `$HOME`, then selectively re-allows specific paths. The `claude` binary at `~/.local/bin/claude` (symlink → `~/.local/share/claude/versions/<ver>`) falls under the blanket deny, so the sandbox cannot read or execute it.

## Solution

Add the claude binary paths as **read-only** entries in `~/.config/cco/allow-paths` (chezmoi source: `dot_config/cco/allow-paths.tmpl`):

```
{{ .chezmoi.homeDir }}/.local/bin:ro
{{ .chezmoi.homeDir }}/.local/share/claude:ro
```

The `:ro` suffix causes cco to pass these as `--read-only` to the sandbox script, which generates `(allow file-read* (subpath ...))` Seatbelt rules — sufficient for binary execution without granting write access.

## Prevention

When adding new tools to cco's `--safe` sandbox, verify the tool's binary location is readable. Check with:

```bash
readlink -f $(which <tool>)  # resolve full symlink chain
```

If any path in the chain is under `$HOME`, add it as `:ro` in `allow-paths`.
