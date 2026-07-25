# Claude Code Hook Scripts

Guidance for `dot_claude/scripts/`. Moved out of the project root `CLAUDE.md` (2026-07-26) —
narrowly scoped to this directory's notification hook, so it only needs to load when working
here. See `.claude/rules/shell-scripts.md` for general hook-script conventions.

**Notification hook ownership** — `dot_claude/scripts/executable_notify.sh` is wired to
`Notification` (permission requests, idle waits) and `StopFailure` (the turn ended because
of an API error) only. It is deliberately **not** wired to `Stop`: `Stop` fires at the end of
every assistant turn, which made notifications worthless noise. The `Notification` entry's
`matcher` filters on the payload's `notification_type`, so only
`permission_prompt|idle_prompt|agent_needs_input` reach the script and the non-blocking types
(`agent_completed`, `auth_success`, `elicitation_*`) never invoke it — the `permission_prompt`
pattern also matches `worker_permission_prompt`, which is wanted: that one is a network-access
approval dialog. The script classifies on `notification_type` as well, not on the English
prose in `message`; the message regex survives only as a fallback for a Claude Code that omits
the field, and matches `approv` (not `approve`) because the product's literal is "needs your
approval for …". Both notify entries set `"timeout": 5` so a hanging delivery backend
(`terminal-notifier` produces no output for 120s under a Seatbelt sandbox, which the
safehouse-wrapped `claude` imposes on hooks) degrades fast instead of holding the hook slot
for the 60s default. The script exits silently
when `ORCA_PANE_KEY`, `ORCA_AGENT_HOOK_PORT`, and `ORCA_AGENT_HOOK_TOKEN` are all set —
that is the exact condition under which `~/.orca/agent-hooks/claude-hook.sh` forwards the
event to orca, so orca will notify instead, with better worktree/tab attribution. Checking
`ORCA_PANE_KEY` alone would create a silent gap when orca's port or token is missing.
Notifications carry attribution (cwd basename plus git branch) and a wait kind, never a
summary of Claude's last message — the transcript is never read; a `StopFailure` body names
the API failure (`rate_limit`, `authentication_failed`, …) from the payload's `error` field.
Delivery is `terminal-notifier` (for `-group` replacement and click-to-focus) falling back to
`osascript`; **`terminal-notifier` fails silently until macOS notification permission is
granted**, and the fallback does not cover that — backend selection is
`command -v terminal-notifier`, so `osascript` runs only when the binary is absent. On a new
machine verify notifications actually arrive rather than assuming.
orca's own notification granularity is GUI-only and not version-controlled. Every
invocation that clears the suppression gates appends one line to `~/.claude/logs/notify.log`
(bounded to 500 lines) recording event, kind, `notification_type`, `error`, and message —
that log is how a misclassification gets diagnosed, and `error` is recorded separately
because `message` is always empty for `StopFailure`. Suppressed invocations log nothing, so
an empty log inside an orca workspace is the expected result rather than evidence the hook is
broken.
Design: `docs/superpowers/specs/2026-07-25-notification-hook-redesign-design.md`.
