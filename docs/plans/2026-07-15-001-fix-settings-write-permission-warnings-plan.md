---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
type: fix
created: 2026-07-15
---

# fix: Remove redundant `Write()` permission rules from settings.json

## Summary

Claude Code emits ~24 startup warnings that `Write(path)` permission rules in `dot_claude/settings.json.tmpl` are "not matched by file permission checks — only `Edit(path)` rules are." Every warned `Write(...)` file-path rule already has an exact `Edit(...)` equivalent in the same `allow`/`deny` array, so the `Write(...)` rules are pure redundancy. The fix removes them, which silences the warnings with zero loss of permission coverage (`Edit` rules cover all file-editing tools, including `Write`).

## Problem Frame

Claude Code's permission engine applies file-path glob rules (`!.git/**`, `/etc/**`, `~/.ssh/*_rsa`, etc.) only through the `Edit(...)` matcher — `Edit` rules govern every file-editing tool (`Write`, `Edit`, `NotebookEdit`). A `Write(path)` rule is therefore ineffective and triggers a per-rule warning on every session start.

In `dot_claude/settings.json.tmpl`:
- `permissions.allow` contains `Edit(!<dir>/**)` (lines 68–72) **and** duplicate `Write(!<dir>/**)` (lines 78–82).
- `permissions.deny` contains `Edit(<path>)` (lines 110–128) **and** duplicate `Write(<path>)` (lines 129–146).

Because the `Edit(...)` twin of every `Write(...)` rule already exists, deleting the `Write(...)` rules is behavior-preserving.

**Verified 1:1 coverage** (source of truth for the delete list):

| Removed `Write(...)` | Existing `Edit(...)` twin |
|---|---|
| `Write(!.git/**)`, `!build`, `!dist`, `!node_modules`, `!vendor` (allow) | `Edit(!.git/**)` … `Edit(!vendor/**)` (lines 68–72) |
| `Write(/etc/**)` … `Write(/dev/**)` (deny) | `Edit(/etc/**)` … `Edit(/dev/**)` (lines 110–121) |
| `Write(~/.ssh/*_rsa)`, `*_ecdsa`, `*_ed25519` (deny) | `Edit(~/.ssh/*_rsa)` … (lines 123–125) |
| `Write(/etc/passwd)`, `/etc/shadow`, `/etc/sudoers` (deny) | `Edit(/etc/passwd)` … (lines 126–128) |

`Edit(~/.ssh/id_*)` (line 122) has no `Write(...)` twin and is untouched.

## Scope Boundaries

**In scope:** Delete the redundant `Write(...)` file-path rules from `allow` and `deny` in `dot_claude/settings.json.tmpl`; fix the resulting trailing-comma at the new end of each array.

**Out of scope:** `Bash(...)`, `Read(...)`, `WebFetch(...)`, `mcp__*` rules (unaffected by this warning class); the `ask` array; any change to actual permission semantics.

### Deferred to Follow-Up Work

None.

## Key Technical Decisions

- **Delete rather than convert to `Edit(...)`.** Converting each `Write(...)` to `Edit(...)` would create exact duplicates of rules already present. Deletion is the correct fix because the `Edit(...)` twins already provide the coverage. This is why the warning says "use `Edit` instead" yet the right action here is removal.
- **Preserve JSON array validity.** After removing the tail `Write(...)` entries, the new last element of each array (`"WebSearch"` in `allow`, `"Edit(/etc/sudoers)"` in deny) must not carry a trailing comma.

## Implementation Units

### U1. Remove redundant `Write()` rules and repair array tails

**Goal:** Silence all `Write(...)`-rule warnings by deleting the redundant entries and keeping the JSON well-formed.

**Requirements:** Eliminate every warning in the report; preserve permission behavior.

**Dependencies:** None.

**Files:**
- `dot_claude/settings.json.tmpl` (modify)

**Approach:**
1. In `permissions.allow`, delete the five `Write(!...)` lines (currently 78–82). Remove the trailing comma now dangling on `"WebSearch"` (line 77) so it becomes the array's last element.
2. In `permissions.deny`, delete the eighteen `Write(...)` lines (currently 129–146). Remove the trailing comma now dangling on `"Edit(/etc/sudoers)"` (line 128) so it becomes the array's last element.
3. Leave all `Edit(...)`, `Bash(...)`, `Read(...)`, and `mcp__*` rules unchanged.

**Execution note:** Mechanical edit to a `.tmpl` file; verify with the template + JSON checks below rather than unit tests.

**Test scenarios:**
- `Test expectation: none -- config-only change; verification is template rendering + JSON validity + warning absence (see Verification).`

**Verification:**
- `make check-templates` passes (the `.tmpl` renders).
- Rendered `settings.json` parses as valid JSON (e.g., render via `chezmoi execute-template` / `chezmoi apply --dry-run` and pipe through `jq .`).
- `grep -n '"Write(' dot_claude/settings.json.tmpl` returns no matches.
- After `chezmoi apply`, starting a new Claude Code session shows none of the `Write(...)` permission warnings.

## Verification Contract

- No `Write(...)` rules remain in `dot_claude/settings.json.tmpl`.
- Template renders and the resulting JSON is valid.
- `make lint` (or at minimum `make check-templates`) passes.
- New session start produces no `Write(...)` permission warnings.

## Definition of Done

- U1 complete: redundant `Write(...)` rules removed, array tails valid.
- Verification Contract satisfied.
- Change committed (chezmoi source file, not the deployed target).
