---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "chore: Remove figma, newrelic, and notion MCP servers"
type: chore
date: 2026-07-16
---

# chore: Remove figma, newrelic, and notion MCP servers

## Summary

The user wants the `figma`, `newrelic`, and `notion` entries removed from Claude Code's
managed MCP server configuration. The single source of truth is
`dot_claude/mcp-servers.json`, which `modify_dot_claude.json` uses to fully replace the
`mcpServers` key in `~/.claude.json` on every `chezmoi apply`. Removing the three entries
from the source file and re-applying is sufficient — no other file references these
servers.

**Product Contract preservation:** N/A — direct planning (`ce-plan-bootstrap`), no
upstream requirements doc.

---

## Problem Frame

`dot_claude/mcp-servers.json` currently declares five MCP servers: `notion`, `codex`,
`newrelic`, `figma`, `deepwiki`. The user wants `figma`, `newrelic`, and `notion` removed,
leaving `codex` and `deepwiki`. Because `modify_dot_claude.json` overwrites the entire
`mcpServers` key from this file on every apply (`.mcpServers = $servers[0]`), deleting the
three JSON entries here and running `chezmoi apply` propagates the removal to
`~/.claude.json` — no manual edit of the runtime file is needed or safe (it would be
reverted on next apply anyway).

---

## Requirements

- **R1** — `dot_claude/mcp-servers.json` no longer contains `figma`, `newrelic`, or
  `notion` keys.
- **R2** — `codex` and `deepwiki` entries are preserved unchanged.
- **R3** — The resulting file is valid JSON.
- **R4** — After `chezmoi apply`, `~/.claude.json`'s `mcpServers` key reflects only the
  remaining servers (verified via `chezmoi diff` showing no drift for the target).
- **R5** — `make lint` passes (oxfmt/oxlint cover JSON formatting for this file).

---

## Key Technical Decisions

- **KTD1 — Edit the source file only, never the deployed target.** Per repository
  convention (`~/.claude.json` is a `modify_`-managed runtime file), edits must land in
  `dot_claude/mcp-servers.json`. Editing `~/.claude.json` directly would be silently
  overwritten by `modify_dot_claude.json` on the next apply.
- **KTD2 — No script or template changes needed.** `modify_dot_claude.json`'s merge logic
  (`.mcpServers = $servers[0]`) already performs a full replace, not a diff/patch, so
  deleting keys from the source is enough to delete them from the target on next apply.

---

## Scope Boundaries

**In scope:** Removing the three named JSON entries from `dot_claude/mcp-servers.json`
and applying the change.

### Deferred to Follow-Up Work
- None.

### Non-goals
- Adding, modifying, or reordering any other MCP server entry (`codex`, `deepwiki`).
- Changing `modify_dot_claude.json`'s merge script.
- Unregistering any Claude Code plugin marketplace or plugin (unrelated system).

---

## Implementation Units

### U1. Remove `figma`, `newrelic`, `notion` from `dot_claude/mcp-servers.json`

- **Goal:** Delete the three MCP server entries from the source config (R1, R2, R3).
- **Dependencies:** none.
- **Files:** `dot_claude/mcp-servers.json`
- **Approach:** Remove the `"figma"`, `"newrelic"`, and `"notion"` top-level keys and
  their objects, keeping `"codex"` and `"deepwiki"` intact with valid JSON syntax
  (correct comma placement after removal).
- **Execution note:** No unit test; verify with `jq empty` for valid JSON syntax and a
  visual diff confirming only the three keys were removed.
- **Test scenarios:** `Test expectation: none -- static config data removal, verified by JSON validation and clean chezmoi diff after apply.`
- **Verification:** `jq empty dot_claude/mcp-servers.json` exits 0; `jq 'keys' dot_claude/mcp-servers.json` shows exactly `["codex", "deepwiki"]`.

### U2. Apply and verify propagation to the deployed target

- **Goal:** Propagate the source change to `~/.claude.json` and confirm no drift (R4).
- **Dependencies:** U1.
- **Files:** none (runtime verification only).
- **Approach:** Run `chezmoi apply`, then `chezmoi diff` to confirm no outstanding drift
  for `~/.claude.json`. Optionally inspect `jq '.mcpServers | keys' ~/.claude.json` to
  confirm only `codex` and `deepwiki` remain.
- **Execution note:** Runtime/smoke verification, not a code test.
- **Test scenarios:** `Test expectation: none -- verified via chezmoi apply + diff, not code test.`
- **Verification:** `chezmoi diff` shows no `~/.claude.json` drift; `jq '.mcpServers | keys' ~/.claude.json` returns `["codex", "deepwiki"]`.

---

## Verification

Global checks after all units (R4, R5):

1. `jq empty dot_claude/mcp-servers.json` — valid JSON.
2. `chezmoi apply` then `chezmoi diff` — no drift for `~/.claude.json`.
3. `make lint` (or targeted `make oxfmt`/`make oxlint`) passes.

## Definition of Done

- `dot_claude/mcp-servers.json` contains only `codex` and `deepwiki` (U1).
- `chezmoi apply` propagates the removal with no residual diff (U2).
- `make lint` green (R5).
