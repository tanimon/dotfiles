---
title: "safehouse `--add-dirs` rule silently degrades when the path does not exist at sandbox launch"
date: 2026-04-30
category: integration-issues
module: claude-code-harness
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "Every Bash/Edit/Write tool call hits the gateguard Fact-Forcing Gate first-call deny path indefinitely, even after presenting facts"
  - "`~/.gateguard/state-<sessionid>.json` is never created on disk, despite `--add-dirs=$HOME/.gateguard` being present in `dot_config/safehouse/config`"
  - "`sandboxd` log shows `deny(1) file-read-data /Users/.../.gateguard` AND `file-read-metadata` even AFTER the directory has been created from a non-sandboxed shell"
  - "Manually `mkdir -p ~/.gateguard` mid-session does NOT recover the running claude session — only an exit + relaunch resolves it"
  - "Same pattern would silently break any other tool whose runtime state dir is in `--add-dirs` but missing on disk at safehouse launch"
root_cause: incomplete_setup
resolution_type: environment_setup
related_components:
  - development_workflow
tags:
  - sandbox
  - seatbelt
  - agent-safehouse
  - chezmoi
  - gateguard
  - everything-claude-code
  - silent-failure
  - runtime-state-dir
---

# safehouse `--add-dirs` rule silently degrades when the path does not exist at sandbox launch

## Problem

The `everything-claude-code:gateguard` PreToolUse hook (`zunoworks/gateguard`, bundled in ECC plugin v2.0.0-rc.1) entered a permanent-deny loop in this chezmoi-managed Claude Code setup: every `Bash`, `Edit`, and `Write` tool call was blocked with the "Fact-Forcing Gate" prompt indefinitely, even after the agent presented the requested facts. The gate could never transition from deny to allow because its state directory `~/.gateguard/` was unreachable from inside the agent-safehouse Seatbelt sandbox at runtime — and the predecessor fix of just adding the path to `--add-dirs` was insufficient because **the rule itself silently degrades when the path does not exist at safehouse launch time**.

## Symptoms

- Every Bash invocation returned the gate's first-call deny output asking the agent to "present these facts: 1. The current user request… 2. What this command verifies…", and presenting the facts had no effect — subsequent calls hit the same first-call branch.
- Every Edit/Write/MultiEdit on a given file path returned the per-file fact-force gate, even on the second and third attempts.
- `~/.gateguard/state-<sessionid>.json` was never created on disk (verified from a non-sandboxed terminal). `gateguard-fact-force.js` `saveState()` failed silently inside the catch block.
- From a non-sandboxed terminal, `sudo log show --last 5m --predicate 'process == "sandboxd"'` showed (paths redacted):
  ```text
  20:32:58 deny(1) file-read-data <HOME>/.gateguard
  20:32:58 deny(1) file-read-metadata <HOME>/.gateguard
  ```
  These denials happened **after** the user had created the dir from outside the sandbox — proving the running profile was stale.
- The session was effectively frozen: no tool that triggers `pre:bash`, `pre:edit`, or `pre:write` hooks could execute.

## What Didn't Work

- **Hypothesis: per-call `session_id` drift.** Initial guess that `session_id` changed between calls and produced different state files. Disproved by reading `gateguard-fact-force.js:64` `resolveSessionKey()` — `data.session_id` is read directly from stdin and is deterministic across the session.
- **Placeholder file with a literal leading dot.** First chezmoi fix attempt added `dot_gateguard/.keep` (literal `.keep`) to source. chezmoi treats source-side filenames starting with a literal `.` as unmanaged metadata, so the file never deployed:
  ```sh
  $ chezmoi managed | grep gateguard
  .gateguard
  $ chezmoi source-path ~/.gateguard/.keep
  chezmoi: <HOME>/.gateguard/.keep: not managed
  ```
  The placeholder must use the `dot_` prefix (`dot_keep`) to materialise as `.keep` in the target.
- **`mkdir -p ~/.gateguard` from inside the broken claude session via `!` prefix.** Returned `Operation not permitted` — `!`-prefixed commands run **inside** the agent-safehouse sandbox in this setup (auto memory [claude]: `bang_prefix_runs_inside_sandbox.md`), and the sandbox profile loaded at launch had no write rule for `~/.gateguard/`.
- **`mkdir -p ~/.gateguard` from an external terminal, mid-session.** Created the directory on disk but did **not** rescue the running session: the Seatbelt profile is fixed at sandbox launch and is not re-evaluated when the underlying filesystem changes. Subsequent gate calls in the same session continued to hit `deny(1) file-read-*`.
- **Workarounds considered and rejected:**
  - `ECC_DISABLED_HOOKS=pre:bash:gateguard-fact-force` — disables a useful gate; doesn't fix the underlying class of bug for any other tool needing a runtime directory.
  - `GATEGUARD_STATE_DIR=/tmp/.gateguard` — `/tmp` is also subject to safehouse rules and hits the same path-existence trap; volatile across reboots.
  - `.chezmoiscripts/run_onchange_*` script that `mkdir`s the dir — overkill for a one-line guarantee; `dot_<name>/dot_keep` is the standard chezmoi idiom for "ensure empty dir exists".

## Solution

Add a single zero-byte placeholder file to the chezmoi source so `chezmoi apply` materialises `~/.gateguard/` **before** `claude` (and therefore `agent-safehouse`) launches.

**Diff (PR #187)**

New file:

```text
dot_gateguard/dot_keep   (0 bytes)
```

That's the entire fix. After `chezmoi apply`:

```sh
$ chezmoi managed | grep gateguard
.gateguard
.gateguard/.keep

$ chezmoi source-path ~/.gateguard/.keep
<CHEZMOI_SOURCE_DIR>/dot_gateguard/dot_keep

$ ls -la ~/.gateguard/
total 0
drwxr-xr-x   3 <user>  staff    96 .
drwxr-x---+ 80 <user>  staff  2560 ..
-rw-r--r--   1 <user>  staff     0 .keep
```

No change is needed in `dot_config/safehouse/config.tmpl` — its existing `--add-dirs={{ "{{ .chezmoi.homeDir }}" }}/.gateguard` line is already correct. The fix removes the path-existence precondition that was breaking it.

**Verification**

- Restarted `claude` with `~/.gateguard/` pre-created on disk.
- First Bash call: gate denied once with the fact-forcing prompt (expected).
- Second Bash call after presenting facts: **allowed**.
- `~/.gateguard/state-58e64a88-03f7-4494-8cbf-f5b261028032.json` was generated on the first call, confirming `saveState` succeeded.
- `make lint` passed (`secretlint`, `shellcheck`, `shfmt`, `oxlint`, `oxfmt`, `actionlint`, `zizmor`, modify-script smoke tests, template render check, `scan-sensitive`).

## Why This Works

Three independent facts compose into the bug:

1. **agent-safehouse `--add-dirs` is path-existence-sensitive at launch.** safehouse auto-detects "literal file rule" vs "subpath rule" by stat-ing each `--add-dirs` entry when it generates the Seatbelt profile (see `safehouse-cli-flag-internals-and-config-patterns.md`). If the path doesn't exist at launch, no effective subpath rule is emitted (auto memory [claude]: `safehouse_add_dirs_startup_path_existence.md`). The same Seatbelt-rule-shape sensitivity has bitten this setup before with `file-read-metadata` literal-vs-subpath (auto memory [claude]: `cco_seatbelt_file_read_metadata.md`).
2. **gateguard silently swallows persistence errors.** `scripts/hooks/gateguard-fact-force.js` lines 128-183 wrap `mkdirSync` + `writeFileSync` + `renameSync` in `try { ... } catch (_) { /* ignore */ }`. EACCES from the sandbox is caught and discarded, so `saveState` becomes a no-op without surfacing any signal.
3. **No persisted state ⇒ permanent first-call.** `isChecked('__bash_session__')` and per-file checks always read `false` from a never-written file, so every call lands on the deny branch.

Pre-creating `~/.gateguard/` via a tracked chezmoi placeholder breaks fact #1: at the moment `claude` (and thus `agent-safehouse`) starts, the path exists and `--add-dirs` emits a real subpath rule. `mkdirSync`/`writeFileSync` inside the sandbox now succeed, `saveState` actually persists, and the deny→allow transition works as designed. Facts #2 and #3 still exist as latent risks but no longer trigger because the precondition is satisfied.

The predecessor doc `gateguard-fact-force-sandbox-state-dir-2026-04-19.md` solved a different upstream cause (the `--add-dirs` line was missing from `safehouse/config.tmpl` entirely). Its "Solution" section recommends a manual `mkdir -p ~/.gateguard` before relaunching `claude`. That manual step happens to side-step this trap, but the doc doesn't explain *why* the `mkdir` is load-bearing — and a fresh-machine setup that runs `chezmoi apply` then `claude` without the manual step would still hit this bug. The new fix in this doc removes the manual step by making the directory tracked.

## Prevention

- **Use the `dot_<dir>/dot_keep` chezmoi idiom for any runtime directory that another tool's startup-time path-detection depends on.** Concretely:
  ```text
  dot_gateguard/dot_keep        # → ~/.gateguard/.keep   (creates ~/.gateguard/)
  ```
  Do **not** use a literal-dotted source filename like `dot_gateguard/.keep` — chezmoi treats literal-dot source filenames as unmanaged metadata (see `.claude/rules/chezmoi-patterns.md`, "File Type Selection"). Verify with `chezmoi managed | grep <dir>` after the change.
- **When a tool's runtime directory must exist before sandbox launch, encode that as a tracked file, not a hook script.** A `dot_keep` placeholder is reviewable, deterministic, and incurs zero ordering risk. A `run_onchange_` `mkdir` script is heavier and won't help cases where the tool runs before the script (e.g., before first apply on a new machine).
- **Audit `dot_config/safehouse/config.tmpl` `--add-dirs` entries against the source tree.** Every `--add-dirs={{ "{{ .chezmoi.homeDir }}" }}/<X>` line should have a corresponding `dot_<X>/dot_keep` (or other tracked content under `dot_<X>/`) that guarantees `~/.<X>/` exists on `chezmoi apply`. A future `make` target could grep both files and warn on mismatches.
- **Upstream fail-loud suggestion (deferred, not in this PR).** Open a PR to zunoworks/gateguard or ECC plugin to log persistence failures instead of swallowing them silently. The minimal change in `scripts/hooks/gateguard-fact-force.js` ~line 174-181:
  ```js
  // before
  try { /* mkdir + write + rename */ } catch (_) { /* ignore */ }

  // after
  try { /* mkdir + write + rename */ } catch (err) {
    console.error(`[gateguard] saveState failed: ${err.message}`); // visible in PreToolUse stderr
  }
  ```
  This would have surfaced the EACCES on the very first call and reduced diagnosis from hours to seconds.
- **Heuristic for future debugging.** When a sandboxed tool exhibits "first-call always" behaviour with state-dir semantics, check `sudo log show --last 5m --predicate 'process == "sandboxd"'` from a non-sandboxed terminal **before** suspecting the tool's logic. Seatbelt deny lines are usually the fastest path to root cause and have caught both this issue and prior `file-read-metadata` regressions in this repo.
- **In-session self-repair is impossible when Bash/Edit hooks are broken.** The recovery path must go through the host shell (a separate non-sandboxed terminal — `!` prefix runs INSIDE the sandbox in this setup, auto memory [claude]: `bang_prefix_runs_inside_sandbox.md`).

## Related

- `docs/solutions/integration-issues/gateguard-fact-force-sandbox-state-dir-2026-04-19.md` — predecessor on the same hook + same state dir. Solved the missing-allowlist upstream cause; this doc covers the path-existence-trap upstream cause that survives even after the allowlist is in place. The predecessor's "manual `mkdir -p ~/.gateguard`" step is now stale guidance — superseded by the chezmoi-managed approach here.
- `docs/solutions/integration-issues/safehouse-cli-flag-internals-and-config-patterns.md` — explains the `policy_render_emit_path_ancestor_literals` / stat-based `-d` check that is the exact mechanism behind why a non-existent `--add-dirs` target silently degrades. Worth reading for background.
- `docs/solutions/integration-issues/safehouse-daily-dev-paths-and-chezmoi-diff-eperm.md` — adjacent: same config file, same class of fix (allowlist rw path).
- `docs/solutions/integration-issues/cco-sandbox-chezmoi-read-only-access.md` — adjacent runtime-state allowlist pattern.
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md` — silent-failure / hook-diagnostic guidance.
- `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md` — broader hook authoring context.
