# Claude Code Notification Hook Redesign — Design

**Date:** 2026-07-25
**Status:** Approved (pending user review of this document)

## Context

Desktop notifications from Claude Code had become worthless: they fired so often, and at
such fine granularity, that the user stopped reading them. The stated goal is notifications
that arrive at necessary-and-sufficient moments and carry meaning.

Investigation of the current wiring found three independent causes.

**1. Frequency — the `Stop` hook.** `dot_claude/settings.json.tmpl` registers
`notify-wrapper.sh` on both `Notification` and `Stop`. `Stop` fires at the end of *every*
assistant turn, so an ordinary back-and-forth conversation produces one sound-bearing
notification per exchange. This is the dominant noise source.

**2. Content — the transcript-tail approach.** `executable_notify.mts` ignores the
`message` field that Claude Code supplies in the hook payload and instead tail-reads the
transcript JSONL to recover the last assistant text block, which it passes verbatim to
`display notification`. So the notification says whatever Claude happened to be narrating
mid-task, and discards the one field that actually states *why* the hook fired. There is no
filtering, classification, or attribution logic of any kind. The title is the constant
string `"Claude Code"`.

**3. Duplication — orca.** The user runs parallel sessions inside orca workspaces (an
Electron app with a bundled CLI, installed via Homebrew; bundle id `com.stablyai.orca`).
`~/.orca/agent-hooks/claude-hook.sh` is wired into ten hook events and forwards every
payload to orca's local runtime. orca also emits its own OS notifications. So the perceived
volume was partly double-counted: one notification from this repo's hook and one from orca,
for the same event.

## Decisions (settled during brainstorming)

1. **Trigger set:** notify only when (a) a human is blocking progress, and (b) a turn ended
   abnormally. Explicitly *not* on task completion and *not* on subagent completion.
2. **Idle notifications are kept.** Claude Code's `Notification` event covers both
   permission requests and the 60-second "waiting for your input" case. The latter is
   effectively a self-filtering completion notification: it only fires when the user did
   *not* come back, which is exactly when a notification has value.
3. **Attribution is mandatory.** The user always has multiple sessions running, so a
   notification that does not say *which* workspace is waiting cannot be acted on.
4. **Body content: attribution + kind only.** macOS truncates at ~2–3 lines. Spend them on
   "where" and "what kind of wait", not on a summary of Claude's last message. Details are
   read in the terminal.
5. **Delivery: `terminal-notifier`, with an `osascript` fallback.** Chosen for `-group`
   (replace a session's previous notification instead of stacking) and click-to-focus.
6. **Ownership split: orca owns notifications inside orca; this hook owns everything
   outside.** orca knows its own worktrees and terminal tabs natively, so its attribution
   and click-to-focus are more accurate than anything this hook could reconstruct.
7. **Implementation: bash, and the Node wrapper is deleted.** Dropping transcript parsing
   removes the only reason the script needed Node.

### Decisions revisited during brainstorming

Two premises shifted mid-discussion and are recorded here so the reasoning is not lost:

- `terminal-notifier` was first chosen because "notifications always arrive from several
  parallel sessions at once". Decision 6 then moved all parallel work to orca's side,
  leaving this hook responsible only for the handful of sessions run outside orca. The
  cost/benefit was re-put to the user with a recommendation to revert to plain `osascript`;
  the user chose to keep `terminal-notifier`. Accepted as the user's call.
- Rewriting in bash reverses PR #43 (`refactor: rewrite notify hook script in
  TypeScript`). That is deliberate: the premise for TypeScript was non-trivial JSONL
  parsing with an OOM guard, and decision 4 removes that parsing entirely.

## Non-goals

- **Focus detection** (suppressing when the terminal is frontmost). The idle notification
  already self-filters on "the user did not come back", so the extra machinery does not pay
  for itself.
- **Completion and subagent notifications.**
- **Rate limiting.** Three trigger kinds plus `-group` replacement is sufficient.
- **Notifications from this hook while inside orca.**
- **Automating orca's own notification settings.** They are GUI-only (`orca --help` exposes
  no settings command) and therefore outside this repo's version control.

## Architecture

### Hook wiring (`dot_claude/settings.json.tmpl`)

| Event | Current | After | Rationale |
|-------|---------|-------|-----------|
| `Notification` | notify | **keep** | Permission requests and idle waits — the only signal that a human is blocking |
| `Stop` | notify | **remove** | Fires every turn; the primary noise source |
| `StopFailure` | orca only | **add notify** | Abnormal turn termination |

The orca dispatcher entries already present on each event are left untouched, per the
contract in `docs/plans/2026-07-18-001-chore-orca-hooks-settings-template-plan.md`. The
existing `2>>"$HOME/.claude/logs/notify-errors.log"` redirection is preserved on each
notify entry.

### Script structure

One file: `dot_claude/scripts/executable_notify.sh` → `~/.claude/scripts/notify.sh`.
Three sequential responsibilities:

```
stdin JSON ──▶ 1. suppression gates ──▶ 2. classification ──▶ 3. send
                    │ exit 0                │ kind + label      │ isolated function
```

Deleted: `dot_claude/scripts/executable_notify.mts`,
`dot_claude/scripts/executable_notify-wrapper.sh`.

The wrapper exists only to work around Node calling `lstat($HOME)` during module load under
`--experimental-strip-types`, which Seatbelt denies; it caches the script to `/tmp` to dodge
the `$HOME` read. Removing Node removes that entire failure class, one `/tmp` cache file,
and one process launch per notification.

### 1. Suppression gates

Ordered cheapest-first; every gate exits 0 (a silent, intentional skip per
`.claude/rules/shell-scripts.md`).

1. **Inside orca** → skip. The condition mirrors orca's own forwarding gate in
   `claude-hook.sh` exactly: suppress only when `ORCA_PANE_KEY`, `ORCA_AGENT_HOOK_PORT`,
   and `ORCA_AGENT_HOOK_TOKEN` are *all* non-empty. This matters — if the port or token is
   missing, orca is not receiving the event and therefore cannot notify, so this hook
   should. Checking `ORCA_PANE_KEY` alone would create a silent gap.
2. **Empty or malformed stdin** → skip.
3. **Neither `terminal-notifier` nor `osascript` available** → skip (covers Linux).

### 2. Event classification

Derived from `hook_event_name` and `message`. **The transcript is never read.**

| Condition | Kind | Glyph | Sound |
|-----------|------|-------|-------|
| `Notification`, `message` matches the permission pattern | 許可待ち | ⏸ | Glass |
| `Notification`, anything else | 入力待ち | 💤 | *(none)* |
| `StopFailure` | エラー停止 | ⚠️ | Basso |

Sound is differentiated by kind so urgency is audible without looking: idle waits are not
urgent and stay silent.

Unmatched input falls back to 入力待ち, so a classification miss degrades to a
lower-priority notification rather than to silence.

### 3. Notification composition

| Field | Content | Example |
|-------|---------|---------|
| title | `<glyph> <attribution>` | `⏸ halibut (feat/login)` |
| subtitle | kind | `許可待ち` |
| message | `Notification` → the payload's `message` verbatim; `StopFailure` → fixed string | `Claude needs your permission to use Bash` |

Attribution is `basename` of the payload's `cwd` (falling back to `$PWD`), with the git
branch appended when `git -C <cwd> rev-parse --abbrev-ref HEAD` succeeds. Claude Code
already formats `message` as a single short line, so it is passed through unmodified — this
is what keeps the body from becoming the over-detailed blob the old script produced.

### Delivery

Isolated in a single `send_notification()` function with two backends.

**`terminal-notifier` (primary)**

- `-group "claude-<session_id>"` — a session's new notification replaces its previous one
  instead of stacking in Notification Center.
- Click brings the terminal forward. When `$TMUX` is set, jump to the specific pane via
  `$TMUX_PANE`; otherwise activate the terminal application.
- Added to `darwin/Brewfile` as `brew "terminal-notifier"`.

**`osascript` (fallback)**

Used when `terminal-notifier` is absent — first apply on a new machine, or before the
notification permission has been granted. Title, subtitle, and sound all survive; only
`-group` replacement and click-to-focus are lost.

### Error handling

- `set -euo pipefail`.
- Intentional skips: `exit 0`, no stderr.
- Notification command failure: message to stderr, then `exit 0`. Notifications are
  best-effort and must never block Claude Code.
- Never `exit 1` without a stderr message (Claude Code renders that as a confusing
  "No stderr output").

## Files changed

| Path | Change |
|------|--------|
| `dot_claude/scripts/executable_notify.sh` | **new** — the whole hook |
| `dot_claude/scripts/executable_notify.mts` | **deleted** |
| `dot_claude/scripts/executable_notify-wrapper.sh` | **deleted** |
| `dot_claude/settings.json.tmpl` | remove notify from `Stop`; add to `StopFailure`; repoint `Notification` at `notify.sh` |
| `darwin/Brewfile` | add `terminal-notifier` |
| `Makefile` | rewrite `test-scripts` (it currently tests the deleted wrapper) |
| `CLAUDE.md` | document the ownership split and the trigger set |

## Verification

As a non-`.tmpl` shell script, `notify.sh` is picked up automatically by `make shellcheck`
and `make shfmt` (indent 4). The `make test-scripts` target is rewritten — it currently
asserts on `executable_notify-wrapper.sh`, which this design deletes, so leaving it alone
would break `make lint`.

Tests follow the existing fixture style in `test-harness-scripts`: a `mktemp -d` sandbox,
numbered cases, and `cleanup` on failure. The send step is verified by putting a fake
`terminal-notifier` earlier on `$PATH` that records its argv.

| Case | Expectation |
|------|-------------|
| All three orca env vars set | exit 0, no notification command invoked |
| `ORCA_PANE_KEY` set but token/port empty | notification *is* sent (gap guard) |
| `Notification` + permission-style `message` | kind 許可待ち, sound present |
| `Notification` + other `message` | kind 入力待ち, silent |
| `StopFailure` | kind エラー停止 |
| Empty stdin / malformed JSON | exit 0 |
| `terminal-notifier` absent | falls back to `osascript` |
| argv inspection | `-group` carries `session_id`; title carries the cwd basename |

## Manual steps (outside version control)

1. Review and tune orca's notification granularity in its GUI settings. orca now owns all
   in-orca notifications, so if its granularity is poor the original complaint will persist
   regardless of this change.
2. Grant notification permission to `terminal-notifier` on each machine.

Step 2 is a known weakness worth stating plainly: `terminal-notifier` **fails silently**
until permission is granted, so a new machine can sit in a "no notifications at all" state
without any error surfacing. The `osascript` fallback does **not** insure against this.
Backend selection is `command -v terminal-notifier`, so the fallback covers exactly one
failure mode — the binary being absent (Linux, or a machine before `brew bundle` has run).
Once `darwin/Brewfile` installs it, `terminal-notifier` is always chosen, and neither
permission denial (it exits 0 and displays nothing) nor a hang inside a sandbox reaches
`osascript`. Verifying delivery per machine is therefore a manual step with no automated
substitute; `"timeout": 5` on both hook entries bounds the hang case rather than recovering
from it.

## To resolve during implementation

Both items are unverified because the current script never reads `message`:

1. The actual wording of `Notification`'s `message` field, needed to pin down the permission
   regex. Capture real payloads before finalizing the pattern.
2. The precise firing semantics of `StopFailure`. Its existence is certain (orca wires it),
   but "abnormal turn termination" is inferred, not confirmed.

If either turns out differently, the classification table is the only thing that changes —
the architecture is unaffected.
