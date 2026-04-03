---
title: "fix: statusline not displaying inside cco sandbox"
type: fix
status: completed
date: 2026-03-17
deepened: 2026-03-17
---

# fix: statusline not displaying inside cco sandbox

## Enhancement Summary

**Deepened on:** 2026-03-17
**Research agents used:** security-engineer, architecture-strategist, code-simplicity-reviewer, spec-flow-analyzer, best-practices-researcher, learnings-researcher

### Key Improvements from Deepening
1. **Critical blocker found**: Process substitution `<(cat file.ts)` creates `/dev/fd/N` paths — Node.js doesn't strip TypeScript from extensionless paths. Pivoted to `/tmp` cache approach.
2. **Security hardening**: `~/.claude:ro` is too broad — exposes `.credentials.json` (OAuth tokens) and `history.jsonl`. Use granular allow-paths.
3. **Simplified**: Wrapper script is cleaner than inline `bash -c` given the `/tmp` cache logic.

## Overview

The Claude Code statusline (3-line display with model, context, git diff, API usage) does not appear when running inside the cco `--safe` sandbox. The statusline works normally outside the sandbox.

## Root Cause

Two independent issues prevent the statusline from working:

### Issue 1: Settings unreadable

`~/.claude/` is not in cco's allow-paths. The Seatbelt policy `(deny file-read* (subpath "$HOME"))` blocks Claude Code from reading `~/.claude/settings.json`, so the statusline command is never configured.

### Issue 2: Node.js realpathSync EPERM

Even if settings were readable, the statusline command:

```
node --experimental-strip-types $HOME/.claude/statusline-command.ts
```

fails because Node.js's module loader calls `realpathSync()` which does `lstat()` on every path component — including `$HOME` itself. Seatbelt's `subpath` rule includes the path itself and children but NOT parents, so `lstat($HOME)` is denied even when `$HOME/.claude` is allowed.

This is the same root cause as the hooks EPERM (PR #21), but the hooks fix (`|| true`) only silences the failure — it doesn't produce output. The statusline needs actual stdout output.

### Why bash doesn't have this problem

bash opens scripts via `open()` syscall directly. The kernel resolves the path internally, and Seatbelt checks only the final resolved path against rules. Node.js explicitly calls `lstat()` on each component in userspace via `realpathSync`, which triggers per-component Seatbelt checks.

## Proposed Solution

### 1. Add `~/.claude` paths to cco allow-paths

In `dot_config/cco/allow-paths.tmpl`:

```
# Claude Code config directory
# rw needed: sessions, projects, statsig are written at runtime
# Note: includes .credentials.json (OAuth tokens) but Claude Code already
# holds these tokens in memory — the sandbox protects against reading
# OTHER tools' secrets, not Claude Code's own runtime data.
{{ .chezmoi.homeDir }}/.claude
```

#### Research Insights: Security Trade-off

**Security review finding**: `~/.claude/` contains `.credentials.json` (OAuth access+refresh tokens) and `history.jsonl` (prompt history). A granular allowlist (`settings.json:ro`, `scripts:ro`, etc.) would be more secure.

**However**, the cco sandbox wraps the **entire Claude Code process**, not just the statusline. Claude Code itself needs read/write access to most `~/.claude/` subdirectories (`sessions/`, `projects/`, `statsig/`, `cache/`, `logs/`). Being overly granular will cause hard-to-debug failures in Claude Code's core functionality.

**Decision**: Use single `~/.claude` (rw) entry because:
- Claude Code already holds OAuth tokens in memory (exposing `.credentials.json` adds no new capability)
- The sandbox's threat model is preventing access to **other tools' secrets** (SSH keys, AWS creds, shell history), not Claude Code's own runtime directory
- cco's `--add-dir` operates at directory level — file-level exclusions aren't supported
- Multiple granular entries (settings.json, scripts/, rules/, skills/, agents/, commands/, cache/, logs/, sessions/, projects/, statsig/) would be fragile and need updating as Claude Code adds new directories

### 2. Create bash wrapper script for statusline

New file: `dot_claude/scripts/executable_statusline-wrapper.sh`

```bash
#!/bin/bash
# Wrapper for statusline-command.ts that works inside cco Seatbelt sandbox.
#
# Problem: Node.js realpathSync calls lstat($HOME) during module loading,
# which fails under Seatbelt's (deny file-read* (subpath "$HOME")) rule.
#
# Solution: Cache a copy of the .ts file in /tmp (outside $HOME).
# - /tmp is not under $HOME, so Node's realpathSync won't lstat $HOME.
# - The .ts extension is preserved, so --experimental-strip-types works.
# - cat uses kernel open() (not realpathSync), so it reads the file via
#   Seatbelt's allow rule for ~/.claude.
# - stdin (JSON from Claude Code) flows through to node unchanged.
#
# Why not process substitution <(cat ...)?
#   /dev/fd/N has no .ts extension — Node doesn't strip TypeScript types,
#   causing SyntaxError. See: https://github.com/nodejs/node/issues/18255

src="$HOME/.claude/statusline-command.ts"
cached="/tmp/claude-statusline-${UID}.ts"

# Refresh cached copy only when source is newer or missing
if [[ ! -f "$cached" ]] || [[ "$src" -nt "$cached" ]]; then
  cat "$src" > "$cached" 2>/dev/null || { echo "🤖 Claude"; exit 0; }
fi

exec node --experimental-strip-types "$cached"
```

Key design decisions:
- **`/tmp/` cache**: Outside `$HOME`, preserves `.ts` extension — solves both realpathSync and type-stripping
- **`cat`** reads source file via `open()` (kernel path resolution) — works with Seatbelt allow rules
- **`-nt` freshness check**: Only copies when source changes (~0.1ms overhead per call)
- **`exec`** replaces bash with node — no extra process, stdin inherited
- **Fallback**: If `cat` fails (file missing, permissions), outputs "Claude" and exits 0
- **`#!/bin/bash`** required — `[[ ]]` is a bashism; POSIX sh doesn't support it
- **`$UID`** in filename: User-specific, avoids conflicts in multi-user systems

#### Research Insight: Why not process substitution?

Empirically verified: `node --experimental-strip-types <(cat file.ts)` fails because `/dev/fd/N` has no `.ts` extension. Node.js uses the file extension to determine whether to apply type stripping (confirmed with Node v24.13.0). The temp-file approach is the simplest reliable workaround.

#### Research Insight: `/dev/fd` and Node.js module resolution

Node.js has a [known limitation](https://github.com/nodejs/node/issues/18255) where the module loader doesn't properly support `/dev/fd/` paths from process substitution. While `fs.readFileSync('/dev/stdin')` works, loading a script from `/dev/fd/N` is unreliable.

### 3. Update settings.json to use wrapper

In `dot_claude/settings.json.tmpl`:

```json
"statusLine": {
    "type": "command",
    "command": "bash $HOME/.claude/scripts/statusline-wrapper.sh"
}
```

## Files to Change

| File | Action | Purpose |
|------|--------|---------|
| `dot_config/cco/allow-paths.tmpl` | Edit | Add `~/.claude` (rw) |
| `dot_claude/scripts/executable_statusline-wrapper.sh` | Create | Bash wrapper with /tmp cache |
| `dot_claude/settings.json.tmpl` | Edit | Point statusline command to wrapper |

## Edge Cases and Failure Modes

| Scenario | Behavior | Mitigation |
|----------|----------|------------|
| First run (no cached file) | `cat` creates `/tmp/claude-statusline-$UID.ts` | Automatic — wrapper handles |
| Source .ts file missing | `cat` fails, wrapper outputs "Claude", exits 0 | Graceful fallback |
| `/tmp` full / unwritable | `cat >` fails, cached file may be stale | Falls back to stale cache or fails gracefully |
| Node.js not in PATH | `exec node` fails, bash returns non-zero | Claude Code shows no statusline (existing behavior) |
| Concurrent statusline calls | Potential race writing to same cached file | Benign — both write identical content |
| Source .ts updated mid-session | `-nt` check picks up change on next call | Automatic refresh |
| Outside sandbox (regression) | Wrapper still works — just adds /tmp copy overhead | ~5ms overhead, acceptable |

## Acceptance Criteria

- [ ] Statusline displays all 3 lines (model/context/git, 5h usage, 7d usage) inside cco sandbox
- [x] Statusline continues to work outside cco sandbox (no regression) — verified via standalone test
- [ ] Cache files (`~/.claude/cache/usage.json`, `git-diff.json`) are created/updated inside sandbox
- [ ] Hook error logs still write to `~/.claude/logs/` inside sandbox
- [ ] `chezmoi apply --dry-run` shows expected changes
- [ ] `chezmoi diff` is clean after apply
- [x] Wrapper script is executable (`chezmoi managed | grep statusline-wrapper`)

## Testing

```bash
# 0. Verify wrapper works standalone (outside sandbox)
echo '{"model":{"display_name":"Test"},"workspace":{"current_dir":"'"$PWD"'"}}' | \
  bash ~/.claude/scripts/statusline-wrapper.sh
# Expected: 3-line output with model, usage bars

# 1. Apply changes
chezmoi apply

# 2. Test outside sandbox (regression check)
\claude  # bypass shell function, run unsandboxed
# Verify statusline displays normally

# 3. Test inside sandbox
claude   # uses shell function → cco --safe
# Verify statusline displays all 3 lines

# 4. Verify cache works inside sandbox
ls -la ~/.claude/cache/usage.json ~/.claude/cache/git-diff.json

# 5. Verify /tmp cached file exists
ls -la /tmp/claude-statusline-$(id -u).ts

# 6. Debug sandbox policy if needed
CCO_DEBUG=1 claude --version 2>&1 | head -20
```

## Solution Doc Reference

Related solutions that informed this fix:
- `docs/solutions/runtime-errors/cco-sandbox-hook-and-git-eperm.md` — Same `realpathSync`/`lstat($HOME)` root cause
- `docs/solutions/runtime-errors/cco-safe-mode-claude-not-found-in-path.md` — Same pattern of adding allow-paths
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — Exit code contract for statusline commands
