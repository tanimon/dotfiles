# Claude Code `Notification` / `StopFailure` Hook Contract

**Date:** 2026-07-25
**Claude Code version inspected:** 2.1.220
**Context:** Notification hook redesign (PR #234). The design phase could not determine
these contracts from documentation and deferred them to "verify during implementation";
they turned out to be resolvable statically from the installed binary.

## Why this document exists

Two facts about the `Notification` hook are not in the public docs, and both change how a
notification hook should be written:

1. The payload carries a **`notification_type` enum**, which is a far better classification
   key than pattern-matching the English prose in `message`.
2. A `Notification` hook entry's **`matcher` filters on `notification_type`**, so unwanted
   notification kinds can be excluded before the hook script is even invoked.

Without knowing (1), a hook classifies by regex over `message` and breaks whenever product
copy changes. Without knowing (2), a hook receives every notification kind and must filter
in-script.

## `Notification` payload

```js
{ session_id, transcript_path, cwd, prompt_id, permission_mode, agent_id, agent_type,
  effort, hook_event_name: "Notification", message, title, notification_type }
```

`cwd` and `session_id` are present, so attribution and per-session notification grouping
are both possible without reading the transcript.

### `notification_type` values

Observed (may not be exhaustive):

```
permission_prompt · worker_permission_prompt · idle_prompt · agent_needs_input
agent_completed · auth_success · elicitation_dialog · elicitation_complete
elicitation_response
```

`matcherMetadata.fieldToMatch` is `"notification_type"`, and `executeNotificationHooks`
passes `matchQuery: notification_type` — this is what makes `matcher` filter on it.

### Observed `message` wordings per type

| `notification_type` | `message` |
|---|---|
| `permission_prompt` | `Claude needs your permission` |
| `permission_prompt` (plan approval) | `Claude Code needs your approval for the plan` |
| `permission_prompt` (plan mode) | `Claude Code wants to enter plan mode` |
| `permission_prompt` (review artifact) | `Claude needs your approval for a review artifact` |
| `worker_permission_prompt` | `<worker> needs network access to <host>` |
| `idle_prompt` | `Claude is waiting for your input` |
| `agent_needs_input` | `<label> needs your input[: …]` |
| `agent_completed` | `<label> finished` / `<label> failed` |
| `auth_success` | `Claude Code login successful` |
| `elicitation_complete` / `elicitation_response` | `MCP server "…" …` / `Elicitation response for server "…": …` |

**Trap:** the product's literal is **`approval`**, not `approve`. A regex matching
`approve` silently misses plan approval, review-artifact approval, and plan-mode entry —
all of which are human-blocking dialogs. This repo's first implementation had exactly that
bug. `approv` matches both forms, but keying off `notification_type` avoids the class of
problem entirely.

**Trap:** `agent_completed` reaches the `Notification` hook. A hook that treats "any
`Notification` that isn't a permission prompt" as an idle wait will emit task-completion
notifications, which is usually the opposite of what a noise-reduction effort wants.

## `StopFailure` payload

`StopFailure` is a real event (`executeStopFailureHooks`, present in the `hookEventName`
union). Its own documentation:

> When the turn ends due to an API error. Fires instead of Stop when an API error
> (rate limit, auth failure, etc.) ended the turn. Fire-and-forget — hook output and exit
> codes are ignored.

```js
{ hook_event_name, error, error_details, last_assistant_message }
```

`error` is one of:

```
rate_limit · overloaded · authentication_failed · oauth_org_not_allowed · billing_error
invalid_request · model_not_found · max_output_tokens · server_error · unknown
```

Two consequences:

- `StopFailure` is **narrower than "abnormal turn termination"** — it is specifically
  API-error termination. It does not fire for tool failures or user interrupts.
- It carries **no `message` field**. A hook that logs only `message` records nothing
  useful for `StopFailure`; log `error` instead.

## `terminal-notifier` hangs under Seatbelt

Measured on macOS during this work: `terminal-notifier -help` produced no output for 120 s
when run inside a Seatbelt sandbox, and returned instantly outside it.

This matters because hook scripts inherit the sandboxing of the process tree that spawned
them. Under `command claude` (no outer wrapper) hooks are unsandboxed and unaffected. Under
a safehouse/cco-wrapped `claude`, the whole tree including hooks is sandboxed, and neither
`dot_config/safehouse/config.tmpl` nor `dot_config/cco/allow-paths.tmpl` grants
notification-center access.

A hang is worse than a failure: the wrapper never returns non-zero, so a fallback backend is
never tried, and the hook occupies its slot until the default 60 s timeout. Mitigation is an
explicit short `"timeout"` on the hook entry.

## Related

- `CLAUDE.md` → **Notification hook ownership** — the wiring this repo settled on
- `dot_claude/scripts/executable_notify.sh` — the implementation
- `docs/superpowers/specs/2026-07-25-notification-hook-redesign-design.md` — design
- `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
