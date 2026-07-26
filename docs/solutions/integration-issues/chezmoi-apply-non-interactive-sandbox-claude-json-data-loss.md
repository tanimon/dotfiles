---
title: chezmoi apply --dry-run from an agent's non-interactive sandbox wiped ~/.claude.json
date: 2026-07-26
category: integration-issues
module: chezmoi modify_ scripts (~/.claude.json partial management)
problem_type: integration_issue
component: tooling
symptoms:
  - "chezmoi apply --dry-run --verbose showed ~/.claude.json as though it were a brand-new near-empty file (only a mcpServers key), instead of the real ~38KB file"
  - "chezmoi errored with \"could not open a new TTY: open /dev/tty: device not configured\" while trying to interactively confirm an unrelated drifted file (settings.json)"
  - "~/.claude.json was confirmed missing immediately afterward via four independent checks (jq, stat, test -e, python3 os.path.exists), later reconfirmed from a real non-sandboxed terminal"
  - "ls -la ~/ began returning Permission denied inside the agent's sandbox where it had previously worked"
  - "a subsequently started, unrelated Claude Code session regenerated a fresh near-empty ~/.claude.json (numStartups reset to 1, skillUsage emptied, only one projects entry, mcpServers empty), confirming genuine data loss rather than a transient visibility glitch"
root_cause: async_timing
resolution_type: workflow_improvement
severity: critical
related_components: [development_workflow]
tags: [chezmoi, modify-script, claude-json, data-loss, nono-sandbox, race-condition, chezmoi-apply, non-interactive-tty]
---

# chezmoi apply --dry-run from an agent's non-interactive sandbox wiped ~/.claude.json

## Problem

During a `/doctor` session-health cleanup pass in this chezmoi dotfiles repo (`~/.local/share/chezmoi`), an orchestrating agent ran `chezmoi apply --dry-run --verbose` from its own sandboxed Bash tool to preview a plugin-toggle deployment (disabling the `pr-review-toolkit` and `gopls-lsp` plugins via an edit to `dot_claude/settings.json.tmpl`, the correct chezmoi-source-owned file — not the deployed target, per this repo's own "never edit deployed targets directly" convention).

That single dry-run command corrupted `~/.claude.json`, a ~38KB runtime file holding `skillUsage`/`pluginUsage` history, `numStartups`, `installMethod`/`autoUpdates`, and per-project state (trust flags, per-project `disabledMcpServers`/`mcpServers` overrides) for every project the user has ever opened in Claude Code. Immediately before the command, the file's content had been confirmed intact and correct via a direct `jq -r` read (part of an earlier, successful edit disabling the `codex` and `deepwiki` MCP servers through the same file). Immediately after the command, the file was gone by every check performed.

The command that triggered the loss modifies a file (`~/.claude.json`) governed by this repo's `modify_dot_claude.json` script, which partially manages the file — it owns only the `mcpServers` key and is designed to pass every other key through unchanged. The dry-run's own output surfaced a second problem at the same moment: chezmoi needed to interactively confirm overwriting `~/.claude/settings.json` (which had runtime drift — a `model` and a `theme` key not present in the template), and the agent's Bash tool has no `/dev/tty`, so that confirmation step failed hard instead of degrading gracefully:

```
diff --git a/.claude.json b/.claude.json
old mode 100600
new mode 100644
.claude/settings.json has changed since chezmoi last wrote it?
chezmoi: .claude/settings.json: could not open a new TTY: open /dev/tty: device not configured
```

## Symptoms

- `~/.claude.json` (previously ~38KB, containing `skillUsage`, `pluginUsage`, `numStartups: 95`, and per-project state) was reported missing by four independent checks run immediately after the incident: `jq` (`No such file or directory`), `stat` (`No such file or directory`), `test -e` (false), and `python3 os.path.exists()` (`False`).
- `ls -la ~/` itself began returning `Permission denied: <home directory> - code: 13` in the same session, where the identical command had succeeded earlier — a second, distinct anomaly (directory-listing denial, not just a missing-file result for one path). This was never explained and may or may not be related to the file loss.
- `chezmoi apply --dry-run --verbose` aborted mid-run with a TTY error (`could not open a new TTY: open /dev/tty: device not configured`) while trying to interactively confirm overwriting `.claude/settings.json`'s untracked runtime drift (`model`, `theme` keys).
- A `chezmoi diff` run moments later, while the file was still in its broken state, showed the diff for `.claude.json` as a "new file" containing only a `mcpServers` key — the exact shape `modify_dot_claude.json` produces when it receives **empty stdin** instead of the real file content, not a diff against the actual ~38KB file.

## What Didn't Work

- **Guessing at a fix or writing a replacement file blind.** Given the scope of what the file holds — trust flags and MCP overrides for every project the user has ever opened, not just this one — the agent deliberately did not attempt to reconstruct or regenerate the file from memory or assumption.
- **Trusting the agent's own sandboxed view of the filesystem as ground truth for a "file is gone" claim.** The agent's own Bash tool runs inside a sandbox (`nono`, Seatbelt/Landlock-based) with no TTY, and a second, separate permission anomaly (`ls -la` on the home directory suddenly denied) appeared in the same window — enough uncertainty that the agent treated its own checks as suggestive, not conclusive, and did not act on them alone.
- **Immediately re-running `chezmoi apply` to "fix" the state.** This was the exact command implicated in the incident; re-running it without first confirming the tool's behavior was safe again risked repeating whatever went wrong, or applying on top of an already-inconsistent state.

## Solution

**Step 1 — Independent verification outside the agent's own sandbox.** Rather than accept its own sandboxed checks as final, the agent asked the user to verify from their own real shell, using the harness's documented `!` prefix escape hatch. The user ran `! ls -la ~/.claude.json` and got `No such file or directory (os error 2)` — confirming the loss was real and not a sandbox-visibility artifact.

**Step 2 — Transparent status report before any further action.** The agent reported to the user (in the session's language) exactly what happened, what was lost, what fragments of the lost data the agent still had on hand from earlier diagnostic reads in the same conversation, and explicit options (check Time Machine, reconstruct from fragments, let Claude Code regenerate a bare-bones file on next launch). No further writes were made to the file until the user weighed in.

**Step 3 — Let Claude Code regenerate a baseline file, then inspect it.** The user opened an unrelated Claude Code session in a different project directory, which caused Claude Code to write a fresh `~/.claude.json` from scratch (its normal startup behavior when the file is absent). Inspecting that fresh file showed: `numStartups: 1` (down from 95), `skillUsage: {}` (down from ~47 entries), `pluginUsage` present with 10 entries and small non-zero counts and `lastUsedNumStartups: 1` (evidence of genuinely new activity from the one new session, not a static reseed), `mcpServers: {}` (expected — that key is chezmoi-managed and only restored by a successful `apply`), and only one `projects` entry, for the new session's own cwd.

**Step 4 — Confirm the fix mechanism was safe before trusting it again.** Instead of re-running `chezmoi apply` from the agent's own environment, the agent had the *user* run `chezmoi diff` themselves in their own real terminal and paste the output back. The diff was clean and fully explicable: for `.claude.json`, a pure additive diff restoring only the `mcpServers` key (`codex`, `deepwiki`) with nothing else touched; for `.claude/settings.json`, exactly the intended plugin-disable changes plus the expected reversion of the untracked `model`/`theme` keys. This confirmed both the tool and the agent's own source edits were correct, and that the destructive event was specific to running `apply` non-interactively through the agent's own sandbox — not a defect in the edits themselves.

**Step 5 — Preserve the runtime drift the user wanted to keep.** The user chose to keep `model: "sonnet"` and `theme: "dark"` rather than let them revert. The agent added both keys directly to `dot_claude/settings.json.tmpl` at the exact insertion points the diff had shown them being removed from, validated the template still rendered as valid JSON via `chezmoi execute-template --config <test-toml-with-data> --source "$(pwd)"`, then re-ran `chezmoi diff` and confirmed those two keys no longer appeared as pending changes.

**Step 6 — Fragment-based recovery of `~/.claude.json`, via additive merge, never in place.** The agent had incidentally captured, from earlier diagnostic `jq` reads made during the original `/doctor` pass (before the file was damaged): the full `skillUsage` object (47 entries), the full `pluginUsage` object (12 entries, including two plugins — `gopls-lsp` and `debby@inline` — absent from the freshly-regenerated file's 10 entries), `numStartups: 95`, `installMethod`/`autoUpdates`, and this project's 9-entry `disabledMcpServers` array. It had no fragment of any *other* project's state (trust flags, other projects' MCP overrides) — that data is permanently unrecoverable.

  Recovery was executed as four verified steps, never writing to the live file directly:
  1. Each captured fragment was written to its own file in a scratch directory and validated with `jq empty`.
  2. A jq merge program was written to a **file** (not inlined into a shell one-liner) that:
     - set `numStartups` to `(current + 95)` — i.e. `1 + 95 = 96` — additive, not overwritten, so the total reflects "historical total plus the one new session that already happened";
     - set `skillUsage` to the captured object outright (the current value was empty, so this was a pure restore, not a merge);
     - merged `pluginUsage` per-key: `usageCount` = `(current usageCount, default 0) + (captured usageCount, default 0)` — additive, because the fresh file's non-zero counts reflected genuinely new activity from the one new session that must not be discarded, not stale reseed noise; `lastUsedAt` took the more recent of the two timestamps; any other fields present only on the current entry (e.g. `lastUsedNumStartups`) were preserved from current rather than fabricated from the old snapshot, and this was flagged to the user as a known, accepted minor inconsistency rather than silently guessed at;
     - merged this project's `disabledMcpServers` as a de-duplicated union of the current array and the captured 9-entry array (the fresh file's `projects` entry was for the regenerating session's own, different, cwd, so this project had no pre-existing entry yet — the union was effectively a pure restore here, but written as a union rather than an overwrite so it stays correct if the fresh file ever does carry its own entries for this project).
  3. The merge was run into a **temp file** first, the temp file's JSON was validated with `jq empty`, and the merged result was inspected field-by-field (`numStartups`, `skillUsage` count, the full `pluginUsage` merge, `disabledMcpServers`, and a sample of unrelated keys such as `hasSeenAutoModeEntryWarning`/`tipLifetimeShownCounts` to confirm they were untouched) before committing.
  4. Only after that inspection: `chmod 600` on the temp file (matching the original file's permission mode) and `mv` over the real `~/.claude.json`, followed by a fresh `jq` read to verify the final state.

  Final restored state: `numStartups: 96`, `skillUsage`: 47 entries, `pluginUsage`: 12 entries with historically-accurate cumulative counts, `disabledMcpServers` for this project: 9 entries including `codex`/`deepwiki`. Explicitly and permanently **not** recovered: any state for other projects (trust flags, other projects' `mcpServers`/`disabledMcpServers` overrides) — no fragment of that data had ever entered the conversation, so there was nothing to reconstruct it from.

  The `enabledPlugins`/`model`/`theme` template fix and the pending `mcpServers` restoration via a real `chezmoi apply` were left for the user to apply later, at their own discretion, in their own interactive shell — not run by the agent.

## Why This Works

The recovery strategy treats "the agent's own environment" and "the user's real environment" as two different trust domains, and moves every load-bearing check into the domain the incident didn't touch:

- **Verification moved outside the suspect environment.** The agent's own Bash tool is TTY-less and sandboxed, and had itself just produced a second, unrelated permission anomaly in the same window. Confirming the loss (and later, confirming the fix) through the user's own interactive shell removes the agent's own possibly-compromised vantage point from the chain of evidence.
- **Additive merges assume the "current" snapshot may already be real, new data — not just stale placeholder state.** The freshly-regenerated file's non-zero `pluginUsage` counts, tied to `lastUsedNumStartups: 1`, were treated as evidence of genuine new activity, not noise to overwrite. Summing counters, taking the newer timestamp, and unioning arrays preserves both the old history and the new activity; a blind overwrite in either direction would have silently discarded one or the other.
- **Every write went through a temp file with field-by-field inspection before the final `mv`.** This makes the actual replacement of the live file the very last, cheapest, and most reversible step, after all the risk (bad jq syntax, wrong merge logic, corrupted fragment) had already been caught against a disposable copy.
- **Trusting the tool again only after independently reproducing a clean, explicable diff.** Re-running `chezmoi apply` immediately after the incident would have repeated the exact command implicated in the loss. Having the user reproduce `chezmoi diff` — a read-only, non-mutating operation — and inspect it before any further `apply` established that the tool and the source edits were sound, isolating the failure to the specific act of running `apply` non-interactively from the agent's sandbox.

## Root Cause (Leading Hypothesis — Not Confirmed)

The mechanism below is the best available explanation given the evidence collected, **not a confirmed root cause** — it was not reproduced in isolation, and the incident is not proven to be deterministic or fully understood.

`modify_dot_claude.json` is chezmoi's partial-ownership script for this file. It reads the current file content from stdin, then falls back to an empty object only when that stdin is empty:

```bash
# modify_dot_claude.json:8
CURRENT="$(cat)"
...
# modify_dot_claude.json:26
printf '%s' "${CURRENT:-"{}"}" | jq --slurpfile servers "${MCP_SOURCE}" '.mcpServers = $servers[0]'
```

`CURRENT="$(cat)"` is the stdin read, and `${CURRENT:-"{}"}` is the fallback, which triggers via bash's `:-` operator whenever `CURRENT` is unset **or empty** — not only when the variable is literally unset.

The `chezmoi diff` output captured *after* the incident — a "new file" diff for `.claude.json` containing only a `mcpServers` key — is exactly the shape this fallback produces when `CURRENT` is empty. Since the real file had substantial, correct content confirmed by a direct `jq -r` read moments earlier in the same session, the leading hypothesis is that chezmoi's own apply pipeline, for some reason, fed the modify script empty stdin for `~/.claude.json` at the moment it ran — rather than the real file content — and that this coincided with (and may be causally linked to, but is not proven to be linked to) the concurrent TTY-confirmation failure on the unrelated `.claude/settings.json` overwrite aborting the run partway through. Plausible contributing factors, none confirmed: a race between chezmoi reading the current file and the TTY-prompt failure aborting the process; the abort leaving the pipe in a state where the modify script's stdin read returned nothing; or an interaction specific to running non-interactively inside the `nono` sandbox. The second anomaly observed in the same window — `ls -la ~/` returning a permission-denied error where it had succeeded earlier — was never explained and may or may not be related.

**This is a distinct mechanism from this repo's already-documented "`~/.claude.json` does not persist inside nono" limitation** (see `CLAUDE.md`'s nono sandbox section, and `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md`'s persistence-gap section). That existing limitation is about Claude Code's *own* write path failing *silently*: Claude Code writes an atomic temp sibling `~/.claude.json.tmp.<pid>.<hex>` at `$HOME` root and renames it, nono can't grant that unpredictable temp path (no glob support), the write EPERMs, and Claude Code degrades to "continuing without persisting" — a silent no-op that leaves the *existing* file untouched. This incident is different: the existing file's *content was actively destroyed*, triggered by `chezmoi apply`'s own pipeline (not necessarily inside nono specifically — the agent's Bash tool sandbox in this environment need not be nono itself). Session-history review of this repo's earlier nono-migration work confirms no prior session connected `modify_dot_claude.json` to the persistence-failure investigation — the known limitation and this incident were discovered independently and are complementary evidence of the same file's overall fragility, not the same bug.

## Prevention

- **Never run `chezmoi apply` (dry-run or real) from a non-interactive agent Bash-tool sandbox when a `modify_`-managed target is in scope.** `~/.claude.json` (via `modify_dot_claude.json`) is exactly this kind of target. The lack of a TTY turns any interactive-confirmation need (e.g., overwriting a target with untracked runtime drift) into a hard abort rather than a graceful skip, and this incident's evidence points at that abort path as implicated in the data loss.
- **Always hand `chezmoi apply` to the user to run interactively**, e.g. via the `!` prefix escape hatch, so TTY-requiring drift prompts can actually be answered instead of failing.
- **`chezmoi diff` is always safe to run non-interactively** — it never writes to the destination and never prompts, unlike `apply` (even in `--dry-run --verbose` form, which can still hit the same interactive-confirmation code path for TTY prompts). Prefer `diff` for any agent-initiated preview, and reserve `apply` for the user's own interactive shell.
- **Before writing any reconstruction or recovery data into a config file, validate the merge in a temp file first.** Run `jq empty` on the temp file, inspect the result field-by-field (both the fields you changed and a sample of the fields you didn't), and only then `mv` over the real target — never edit or overwrite the live file directly during recovery.
- **Prefer additive merges over blind overwrites when reconciling a fresh-vs-historical snapshot of the same file.** Sum counters, take the more recent timestamp, union arrays, rather than assuming either snapshot is authoritative. A "fresh" file produced after an incident may already contain genuinely new, real activity (as this file's `pluginUsage` counts did) that a naive restore-from-backup would silently discard.
- **Treat the agent's own sandboxed filesystem checks as suggestive, not conclusive, when something looks catastrophically wrong** — especially if a second, unrelated anomaly (like the permission-denied directory listing here) appears in the same window. Get independent confirmation from the user's own real shell before acting on a "file is gone" conclusion.

## Related Issues

- [Verification that resolves the wrong path passes vacuously](../workflow-issues/verification-through-the-wrong-resolution-path.md) — already documents the same TTY-death mechanism (`chezmoi apply` aborting with `could not open a new TTY` when it needs to confirm overwriting a drifted target) in a different triggering context (running `chezmoi` from the wrong git worktree). That doc's fix is `--force` plus scoping the apply to specific paths; this doc's prevention is instead "never let an agent run `apply` non-interactively at all" — the two teach different actions and are not duplicates.
- [chezmoi apply overwrites runtime plugin changes](chezmoi-apply-overwrites-runtime-plugin-changes.md) — already generalizes "empty stdout from a `modify_` script zeroes the target" as a Gotchas-table entry, and directly references `modify_dot_claude.json` as the same pattern. This incident is evidence that table is incomplete rather than wrong: it doesn't yet cover an *external* process (chezmoi's own apply pipeline, possibly racing something else) feeding the script empty stdin, as opposed to a script bug. Worth a follow-up `ce-compound-refresh` pass on that doc's Gotchas table.
- [Claude Code MCP server config location](claude-code-mcp-server-config-location.md) — the origin doc that introduced `modify_dot_claude.json` and the rule "never template `~/.claude.json` entirely (destroys runtime state)."
- `CLAUDE.md` (nono sandbox section) and the [nono sandbox migration observations](nono-sandbox-migration-observations-2026-07-25.md) — document the related-but-distinct "`~/.claude.json` does not persist inside nono" limitation (Claude Code's own write silently failing), discussed in the Root Cause section above.
- **Stale claim flagged elsewhere**: [cco sandbox chezmoi read-only access](cco-sandbox-chezmoi-read-only-access.md) asserts that read-only-looking commands including `chezmoi apply --dry-run` are safe to allow inside an agent sandbox. This incident is a direct counterexample for that specific command, though it concerns a different (since-retired) sandbox tool than the one in use when this incident occurred. Flagged for a `ce-compound-refresh` pass rather than fixed here, since it targets a different doc's scope decision.
- No existing GitHub issue was found covering this incident or its class of failure (`gh issue list --search` for both `"chezmoi claude.json"` and `"chezmoi apply dry-run"` returned zero results).
