---
title: GateGuard fact-forcing hook blocks every tool call when sandbox denies ~/.gateguard writes
date: 2026-04-19
category: integration-issues
module: claude-code-harness
problem_type: integration_issue
component: tooling
symptoms:
  - "[Fact-Forcing Gate] Quote the user's current instruction verbatim. displayed on every Bash call, not just the first"
  - "[Fact-Forcing Gate] Before editing <path>, present these facts: ... fires on every Edit/Write/MultiEdit, not just the first per file"
  - "Claude Code UI labels the gate response as 'PreToolUse:Bash hook blocking error', making the intentional deny appear as a crash"
  - "Repair deadlock: the allowlist files that would fix the sandbox are themselves blocked by the same gate"
root_cause: incomplete_setup
resolution_type: config_change
severity: high
related_components:
  - development_workflow
tags:
  - sandbox
  - seatbelt
  - agent-safehouse
  - cco
  - gateguard
  - everything-claude-code
  - hook-state-persistence
  - chezmoi
---

# GateGuard fact-forcing hook blocks every tool call when sandbox denies ~/.gateguard writes

## Problem

The `pre:bash:gateguard-fact-force` and `pre:edit-write:gateguard-fact-force` hooks from the `everything-claude-code` plugin are designed to fire once per session (Bash) or once per file (Edit/Write/MultiEdit). Under this repository's Seatbelt sandbox (`agent-safehouse` primary, `cco` fallback), the hooks fired on every single call — making Claude Code effectively unusable because any action triggered a "[Fact-Forcing Gate]" deny. The UI surfaces the deny as `"PreToolUse:Bash hook blocking error"`, masking the fact that it was a deliberate (but broken) gate rather than a crash.

## Symptoms

- Every Bash invocation returned the routine gate message (`"Quote the user's current instruction verbatim. Then retry the same operation."`) — even after quoting and retrying.
- Every Edit/Write/MultiEdit on a given file returned the fact-force gate, even the second and third attempts.
- No error was written to stderr from `saveState()`; failures were silent.
- State file at `~/.gateguard/state-<session-id>.json` was missing entirely.

## What Didn't Work

- **Hypothesis: session ID instability** — ruled out by reading `gateguard-fact-force.js:64` `resolveSessionKey()`, which has a stable `cwd` fallback.
- **Hypothesis: logic bug in `isChecked` / `markChecked`** — code reads correctly; marker lookup and insertion are straightforward.
- **Retrying the gated operation after quoting the instruction** — the retry re-enters the same silent-write loop, so the marker still isn't persisted.
- **Editing `safehouse/config.tmpl` and `cco/allow-paths.tmpl` from within the Claude session** — blocked by the very gate we were trying to fix (chicken-and-egg).

## Solution

Add `~/.gateguard` to both sandbox allowlists so the hook's state directory is writable:

**`dot_config/safehouse/config.tmpl`** (append to the "Working directories (read-write)" block):

```diff
 --add-dirs={{ .chezmoi.homeDir }}/.gstack
+--add-dirs={{ .chezmoi.homeDir }}/.gateguard
```

**`dot_config/cco/allow-paths.tmpl`** (append near the gstack entry, no leading whitespace — cco's parser is whitespace-sensitive):

```diff
 {{ .chezmoi.homeDir }}/.gstack
+# GateGuard fact-forcing hook session state (else hook blocks every Bash)
+{{ .chezmoi.homeDir }}/.gateguard
```

Because the in-session edits are themselves blocked, the user must apply this patch in a host shell (outside the sandbox):

```sh
chezmoi apply ~/.config/safehouse/config ~/.config/cco/allow-paths
mkdir -p ~/.gateguard
# then restart claude (exit + re-launch sandboxed claude)
```

Verification after restart:

```sh
ls ~/.gateguard/            # should contain state-<session-id>.json
cat ~/.gateguard/state-*.json  # should contain "checked": ["__bash_session__"]
```

The second Bash call in the new session should now pass the gate cleanly.

## Why This Works

`gateguard-fact-force.js:30` defaults the state directory to `$HOME/.gateguard` (overridable via `GATEGUARD_STATE_DIR`). `saveState()` at line 128-153 wraps every file I/O in `try { ... } catch (_) { /* swallow */ }`, so sandbox `EPERM` is invisible. Under a deny-all Seatbelt profile, every write to `~/.gateguard/` was being rejected silently, meaning `markChecked()` never actually persisted the `__bash_session__` marker (routine Bash) or per-file markers (Edit/Write). The next `isChecked()` call therefore returned `false`, and the gate denied again — in an infinite loop.

Allowing the directory in both sandbox backends makes `fs.mkdirSync`/`fs.writeFileSync` succeed, the marker persists, and the gate reverts to its intended once-per-session/once-per-file behavior.

## Prevention

- **Any plugin hook that persists state must have its state directory audited against the sandbox allowlist.** Other candidates worth checking: `~/.claude-*`, plugin-local `.state`, `~/.config/*` write paths.
- **Silent `catch (_)` around state writes is a harness smell.** Prefer logging to stderr (via a bounded rate limiter) so sandbox-induced state loss is observable. File as a potential upstream fix in `everything-claude-code`.
- **When adding a new sandboxed tool, grep its source for `process.env.HOME`/`os.homedir()` and explicitly enumerate the paths it writes** before updating `safehouse/config.tmpl` and `cco/allow-paths.tmpl`.
- **cco's `allow-paths` parser is whitespace-sensitive** — never indent entries even when visually grouping them under comments.
- **In-session self-repair is impossible when Bash/Edit hooks are broken.** The recovery path must go through the host shell (`!` prefix, a second terminal, or restarting claude with `\claude` to bypass the sandbox wrapper).

## Related Issues

- `docs/solutions/integration-issues/cco-sandbox-chezmoi-read-only-access.md` — adjacent pattern: missing rw access for chezmoi runtime state.
- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` — related class of failure: Claude Code's own sandbox colliding with outer sandboxing.
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — related harness-hook diagnostic guidance.
