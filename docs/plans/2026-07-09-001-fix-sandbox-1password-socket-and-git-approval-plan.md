---
title: "fix: Allow 1Password agent socket under native sandbox and require approval for git write commands"
date: 2026-07-09
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
plan_depth: standard
---

# fix: 1Password agent socket under native sandbox + git write-command approval

## Summary

Two independent hardening changes to the Claude Code global config in this chezmoi repo, both in `dot_claude/settings.json.tmpl`:

1. **1Password socket fix** — Under `command claude` (native Bash sandbox active, no safehouse), `git commit` fails signing with `Could not connect to socket` because macOS Seatbelt blocks the `op-ssh-sign` connection to the 1Password SSH agent Unix socket. Claude Code v2.1.205 has **no dedicated Unix-socket allow key**, so the fix runs `git commit`/`git push` outside the sandbox via `sandbox.excludedCommands` (narrow exclusion), and the plan explicitly documents the isolation trade-off this creates (KTD5).
2. **git write-command approval** — Six git write subcommands are currently in `permissions.allow` (`add`, `checkout`, `commit`, `fetch`, `pull`, `push`); the rest run under the `defaultMode: "auto"` safety-checker with no explicit gate. Add a `permissions.ask` list covering `commit`, `push`, and the history-altering family (`rebase`, `reset`, `revert`, `cherry-pick`, `merge`, `filter-branch`) so they always prompt. Routine writes (`add`, `checkout`, `switch`, `fetch`, `pull`, `submodule`, `worktree`) stay automatic to avoid deadlocking unattended runs; read-only git (`status`/`log`/`diff`/`show`) is built-in no-prompt.

The two changes are orthogonal: `excludedCommands` controls *where* a command runs (sandbox vs. host); `ask` controls *whether* it needs approval. They compose — an approved `git commit` runs on the host and signs correctly.

**Ask-set scoping decision (user-confirmed):** Gating *every* git write would deadlock unattended autonomous runs (ralph-loop, ce-work, LFG's own commit/push), because `ask` fires even under `bypassPermissions` — there is no human to answer the prompt, so the run hangs. The ask set is therefore deliberately scoped to `commit`/`push` plus history-altering commands (the destructive/irreversible surface), leaving routine automation-friendly writes automatic. See A3.

---

## Problem Frame

**Environment (verified this session):**
- `gpg.format=ssh`, `gpg.ssh.program=/Applications/1Password.app/Contents/MacOS/op-ssh-sign`, `commit.gpgsign=true`
- `SSH_AUTH_SOCK=~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` (socket exists)
- Claude Code v2.1.205, `sandbox.enabled: true`, `failIfUnavailable: false`, `defaultMode: "auto"`

**Why signing fails only under `command claude`:** Per the CLAUDE.md "Native Bash sandbox" section and `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md`, under the wrapped `claude` path the native sandbox degrades to unsandboxed (nested `sandbox_apply` EPERM) while safehouse — which has `--enable=1password` — provides socket access. Under `command claude` there is no safehouse; the native sandbox is genuinely active and its Seatbelt profile denies the `network-outbound` connection to the agent socket. `op-ssh-sign` then reports `Could not connect to socket`.

**Why the approval gap matters:** `permissions.allow` currently contains `Bash(git add:*)`, `Bash(git checkout:*)`, `Bash(git commit:*)`, `Bash(git fetch:*)`, `Bash(git pull:*)`, `Bash(git push:*)`. Under `defaultMode: "auto"` these run without any confirmation. The user wants every git operation that mutates local or remote state to require an explicit approval prompt.

**Scope:** Global Claude Code config only (`dot_claude/settings.json.tmpl`), plus documentation. No change to safehouse config, gitconfig, or the 1Password app.

---

## Key Technical Decisions

### KTD1 — Use `sandbox.excludedCommands` for the socket fix (no dedicated socket key exists)

Confirmed against Claude Code v2.1.205 docs (claude-code-guide research this session): the `sandbox` schema exposes only `enabled`, `failIfUnavailable`, `network.{allowLocalBinding,allowedDomains}`, `filesystem.{allowRead,allowWrite,denyRead}`, and `excludedCommands`. There is **no** `network.allowUnixSockets` or equivalent, and `filesystem.allow*` governs ordinary file access, not Seatbelt `network-outbound` to a socket. The supported lever is `excludedCommands`: listed commands run on the host, outside Seatbelt, where the 1Password agent socket is reachable.

**Rationale for excluding `git commit` and `git push` specifically** (rather than all `git *`, user-confirmed narrow exclusion): keeps read-only and non-signing git operations inside the sandbox, minimizing the unsandboxed git surface (see KTD5 — broadening to `git *` would run *all* git, including read-only forms that can execute external programs, outside the sandbox). `git commit` needs the agent for SSH signing. `git push` is included on the assumption it needs the agent for SSH-remote auth — this holds only for SSH remotes; see R4. Before committing to the two-word form, the implementer verifies at plan-execution time (via claude-code-guide / a runtime smoke) that `excludedCommands` matches two-word patterns; if it does not, fall back to `git *` (R1) while carrying KTD5's trade-off note.

### KTD2 — Use `permissions.ask` (not just removal from `allow`) to force approval

Confirmed against Claude Code docs: rules evaluate in order **deny → ask → allow**; a matching `ask` rule prompts even when a broader `allow` also matches, and `ask` prompts even under `bypassPermissions`. Merely deleting the git entries from `allow` is insufficient under `defaultMode: "auto"` (research-preview auto-approval via background safety checks may still let them through). Adding them to `ask` is the robust, mode-independent way to force a prompt.

Read-only git (`status`, `log`, `diff`, `show`) is a Claude Code built-in no-prompt set and needs no `allow` entry, so removing the write entries from `allow` does not affect read-only flows.

### KTD3 — Preserve the existing force-push deny rules; close the `--force` gap

`deny` already contains `Bash(git push --force-with-lease:*)` and `Bash(git push -f:*)`. Because deny is evaluated before ask, adding `Bash(git push:*)` to `ask` does not weaken these — those forms stay blocked outright. **Gap found in review:** the plain long form `git push --force` (no `-f`, no `--force-with-lease`) is not in the deny list; today it is auto-allowed, and after this change it would be ask-gated (an improvement, not a regression). Add `Bash(git push --force:*)` to `deny` so all three force forms are blocked consistently.

### KTD5 — Excluded git runs unsandboxed: document the trade-off, do not neutralize this repo's trusted hooks

Excluding `git commit`/`git push` from Seatbelt means they run on the host, where git executes repo-controlled hooks (`.git/hooks/pre-commit`, `commit-msg`, `pre-push`) and honors code-executing config/transports (`GIT_SSH_COMMAND`, `ext::`, `!`-aliases), and `git push` can reach any remote — bypassing `sandbox.network.allowedDomains`. This is a real isolation reduction that the plan must state, not hide behind "least-privilege" framing (security-lens finding).

**Why blanket hook-neutralization is rejected here:** the instinctive mitigation — `core.hooksPath=/dev/null` or `--no-verify` on the excluded invocations — would disable this repo's own `prek`/`secretlint` pre-commit hooks, which are a *relied-upon secret-detection control* (see `.pre-commit-config.yaml`, `make secretlint`). Neutralizing them to defend against untrusted-repo hooks would remove a trusted security gate on every commit — net-negative for this user's actual workflow. So the decision is: **document the trade-off in CLAUDE.md and accept the residual risk**, mitigated by (a) git writes being human-approved via `ask` (KTD2), (b) the agent operating in trusted repos under user direction, and (c) narrow exclusion (commit/push only, not `git *`) keeping the unsandboxed surface minimal. The untrusted-repo hook vector is recorded as an accepted residual risk (R5), not silently mitigated in a way that breaks secretlint.

### KTD4 — Style consistency: use the `:*` wildcard suffix

The existing file uses the `Bash(git commit:*)` form. Docs confirm `:*` and ` *` are equivalent word-boundary suffixes. Keep `:*` for the moved/added `ask` entries so the diff reads as a straight relocation plus additions.

---

## Scope Boundaries

**In scope:**
- Edit `dot_claude/settings.json.tmpl`: add git commit/push to `sandbox.excludedCommands`; introduce `permissions.ask` with git write subcommands; remove those subcommands from `permissions.allow`.
- Update the CLAUDE.md "Native Bash sandbox" section to record both changes.
- Add a `docs/solutions/integration-issues/` entry documenting the socket-under-native-sandbox learning and the `excludedCommands` workaround.

### Deferred to Follow-Up Work
- Revisiting `git fetch` gating (fetch only updates remote-tracking refs; included in the default ask set here but could be relaxed later if the prompts prove noisy — see Assumptions).
- Any change to safehouse config or the wrapped-`claude` path (already handles the socket via `--enable=1password`).
- Broader audit of which other commands should move from `allow` to `ask`.

**Out of scope:** gitconfig signing setup, 1Password app configuration, CI `claude-code-action` permission contexts (separate settings surface).

---

## Assumptions

- **A1 — Ask set membership (user-confirmed).** The gated git subcommands are `commit`, `push`, and the history-altering family: `rebase`, `reset`, `revert`, `cherry-pick`, `merge`, `filter-branch` (`git commit --amend` is covered by the `git commit` pattern). Routine writes — `add`, `checkout`, `switch`, `fetch`, `pull`, `submodule`, `worktree` — are deliberately **left automatic** so unattended runs don't deadlock (A3). This is narrower than "every write" by design; `submodule`/`worktree` mutate state but are common in automation and not history-destructive, so they stay auto (revisit in follow-up if needed).
- **A2 — Narrow sandbox exclusion (user-confirmed).** Only `git commit` and `git push` are excluded from the sandbox, not all `git *`. Two-word matching is verified at plan-execution time before committing to this form; fallback to `git *` if it doesn't match (R1), carrying the KTD5 trade-off note.
- **A3 — Unattended runs block by design (user-confirmed).** Because `ask` fires even under `bypassPermissions`, gating `commit`/`push`/history-altering commands means unattended autonomous runs that hit one of them **hang on the prompt** (not merely "prompt"). The user accepts this for the gated set and chose to keep routine writes automatic to limit the blast radius. This is intended governance, not a regression.

---

## Implementation Units

### U1. Exclude git signing/remote commands from the native sandbox

**Goal:** Make `git commit` (SSH signing) and `git push` (SSH-remote auth) run outside the native Seatbelt sandbox so `op-ssh-sign` can reach the 1Password agent socket under `command claude`.

**Requirements:** Fixes the `Could not connect to socket` signing failure (Problem Frame).

**Dependencies:** none.

**Files:**
- `dot_claude/settings.json.tmpl` (modify `sandbox.excludedCommands`)

**Approach:**
- **First, verify two-word matching** (R1): confirm via claude-code-guide docs or a runtime smoke that `excludedCommands` matches a two-word pattern like `git commit *`. Only then use the narrow form; otherwise fall back to `git *` (A2) and note KTD5's trade-off applies to the whole git surface.
- Append `"git commit *"` and `"git push *"` to the existing `sandbox.excludedCommands` array (currently `docker *`, `gcloud *`, `gh *`, `open *`, `osascript *`, `terraform *`), matching the existing ` *` word-boundary glob style.
- Do not touch `sandbox.network` or `sandbox.filesystem` — no socket key exists there (KTD1).
- Do **not** add `--no-verify` or `core.hooksPath` neutralization — that would disable this repo's trusted `prek`/`secretlint` pre-commit gate (KTD5). The unsandboxed-hook trade-off is documented in U3, not mitigated by disabling hooks.

**Execution note:** Config change; verify two-word matching first, then by rendering the template and a runtime smoke commit under `command claude`. Not unit-testable.

**Test scenarios:**
- Template renders to valid JSON: `chezmoi execute-template` on the file piped to `jq .` exits 0 and the rendered `sandbox.excludedCommands` contains the two new entries.
- `make check-templates` passes.
- Runtime smoke (manual, execution-time): under `command claude`, `git commit -m "test"` in a signed repo completes with a good signature (`git log --show-signature -1` shows `Good "git" signature`) and **no** `Could not connect to socket` error.

**Verification:** Rendered JSON is valid and the new entries are present; a signed commit under `command claude` succeeds.

---

### U2. Require approval for git write/update commands via `permissions.ask`

**Goal:** Every git command that mutates local or remote state prompts for approval; read-only git stays automatic.

**Requirements:** Governance requirement — gate git write operations behind explicit approval.

**Dependencies:** none (independent of U1).

**Files:**
- `dot_claude/settings.json.tmpl` (add `permissions.ask`; edit `permissions.allow`)

**Approach:**
- Add a new `"ask"` array under `permissions` containing (per A1): `Bash(git commit:*)`, `Bash(git push:*)`, `Bash(git rebase:*)`, `Bash(git reset:*)`, `Bash(git revert:*)`, `Bash(git cherry-pick:*)`, `Bash(git merge:*)`, `Bash(git filter-branch:*)`.
- Remove from `permissions.allow`: `Bash(git commit:*)`, `Bash(git push:*)`. **Keep** `Bash(git add:*)`, `Bash(git checkout:*)`, `Bash(git fetch:*)`, `Bash(git pull:*)` in allow (routine writes stay automatic per A3), and leave read-only allow entries and non-git entries untouched. Note `Bash(git submodule:*)` / `Bash(git worktree:*)` also stay in allow (A1).
- Add `Bash(git push --force:*)` to `permissions.deny` to close the plain-`--force` gap; keep the existing `--force-with-lease` / `-f` deny entries (KTD3).
- Keep `defaultMode: "auto"` unchanged (KTD2).

**Execution note:** Ordering matters only conceptually (deny→ask→allow is engine-enforced); verify precedence by runtime smoke.

**Test scenarios:**
- Template renders to valid JSON: `chezmoi execute-template` piped to `jq '.permissions.ask'` lists the eight gated entries; `jq '.permissions.allow'` no longer contains `git commit`/`git push` but still contains `git add`/`git checkout`/`git fetch`/`git pull` and the read-only ones; `jq '.permissions.deny'` contains all three force-push forms.
- `make check-templates` passes.
- Runtime smoke (manual, execution-time): `git commit`, `git push`, `git rebase` trigger an approval prompt; `git add` / `git fetch` / `git status` / `git log` run without a prompt; `git push --force ...` and `git push --force-with-lease ...` are denied outright (deny precedence).

**Verification:** Rendered JSON valid; ask list = the 8 gated entries; commit/push/history-altering prompt, routine writes and read-only git do not, all force-push forms blocked.

---

### U3. Document both changes (CLAUDE.md + solution record)

**Goal:** Capture the socket-under-native-sandbox learning and the git-approval policy so future edits don't regress them.

**Requirements:** Harness-engineering practice — record the "why" for non-obvious config.

**Dependencies:** U1, U2 (document the final shape).

**Files:**
- `CLAUDE.md` (update the "**Native Bash sandbox (migration target)**" paragraph)
- `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md` (new)

**Approach:**
- CLAUDE.md: extend the native-sandbox paragraph to note that (a) `git commit`/`git push` are in `excludedCommands` so 1Password SSH signing works under `command claude` (no Unix-socket allow key exists in v2.1.205), **including the KTD5 trade-off** — excluded git runs repo hooks/SSH-transports unsandboxed and push bypasses `allowedDomains`, accepted because git writes are ask-gated and this repo's own trusted `prek`/`secretlint` hooks must not be neutralized; and (b) commit/push/history-altering git are ask-gated in `permissions.ask` (routine writes stay auto to avoid deadlocking unattended runs), while read-only git is auto. Keep the prose economical and English (per documentation-language rule).
- New solution doc: follow the existing frontmatter/section style of neighboring files in `docs/solutions/integration-issues/` (title, category, tags, date, module, symptom, root_cause; then Problem / Root Cause / Solution / Prevention / Related). Cross-link `claude-code-internal-sandbox-nested-seatbelt-conflict.md` and `1password-ssh-agent-libgit2-ssh-auth-sock.md`.
- English only; no secrets or PII (the socket path and public signing-key fingerprint are already documented elsewhere in-repo, but keep the doc free of anything sensitive — `make scan-sensitive` gates this).

**Execution note:** Docs-only; no runtime behavior. Verify with the doc/lint gates.

**Test scenarios:**
- `Test expectation: none -- documentation only.`
- Gate checks: `make scan-sensitive` passes on the new/edited `.md` files; the new solution doc's frontmatter matches the sibling convention.

**Verification:** CLAUDE.md paragraph reflects the final config; new solution doc exists, is English, passes `make scan-sensitive`.

---

## Verification Contract

Run before considering the work complete:

1. `chezmoi execute-template` on `dot_claude/settings.json.tmpl` (with a test config supplying `.chezmoi.homeDir`, `.ghOrg`, `.profile`, per the CLAUDE.md "chezmoi execute-template in CI" pitfall) → pipe to `jq .` → exits 0 (valid JSON).
2. `make check-templates` → passes.
3. `make scan-sensitive` → passes (U3 docs).
4. `make lint` → passes (full suite; settings.json.tmpl is a `.tmpl` and is excluded from JSON linters, so this mainly guards the docs and templates).
5. Runtime smoke under `command claude` (manual, execution-time): signed `git commit` succeeds with no socket error (U1); `git push`/`git commit` prompt for approval, `git status` does not, force-push stays denied (U2).

## Definition of Done

- `dot_claude/settings.json.tmpl` renders to valid JSON with git commit/push in `sandbox.excludedCommands`; a `permissions.ask` list gating `commit`/`push`/history-altering commands; `commit`/`push` removed from `permissions.allow` (routine writes retained); and `git push --force` added to `permissions.deny`.
- CLAUDE.md native-sandbox paragraph documents both changes plus the KTD5 trade-off; a new `docs/solutions/integration-issues/` record exists.
- Verification Contract steps 1–4 pass. **Step 5 (runtime smoke) is a hard gate for the socket fix's efficacy** — the two-word `excludedCommands` matching (R1) must be confirmed (via claude-code-guide or a real signed commit under `command claude`) before the socket fix is considered done; it may only be deferred if the reviewer switches to the proven `git *` form. The approval-gating half (U2) is fully verified by steps 1–2.

---

## Risks & Dependencies

- **R1 — `excludedCommands` two-word matching (medium).** The existing `excludedCommands` entries are all single-token (`docker *`, `gh *`); it is unverified whether Claude Code v2.1.205 matches a two-word pattern like `git commit *`. **Verify this before choosing the narrow form** (U1 first step). If it doesn't match, fall back to `git *` — but note (per KTD5) that broadening to `git *` puts the *entire* git surface, including read-only forms that can execute external programs (pager, `GIT_EXTERNAL_DIFF`, `!`-aliases), outside the sandbox; carry the trade-off note accordingly. The socket fix is inert if this matching assumption is wrong, so it is a verification gate, not a soft risk.
- **R2 — Unattended runs hang on gated commands (medium, intended).** Ask-gating fires even under `bypassPermissions`; an unattended run reaching `commit`/`push`/a history-altering command **blocks on the prompt with no human to answer** (A3). Scoping the ask set to exclude routine writes (add/checkout/fetch/pull) limits which automation deadlocks. Documented in CLAUDE.md so it isn't mistaken for a hang bug.
- **R3 — `defaultMode: "auto"` is research preview.** Behavior of the auto safety-checker (and the `ask`-under-`bypassPermissions` precedence this plan relies on) could change across Claude Code versions. Mitigated by using `ask` (documented mode-independent precedence) rather than relying on auto's defaults; re-audit after Claude Code upgrades.
- **R4 — `git push` sandbox-exclusion premise unverified (low).** Only `git commit` signing failure was observed this session. `git push` is excluded on the assumption it needs the 1Password agent for SSH-remote auth — true for SSH remotes, moot for HTTPS remotes (where `gh`/credential-helper handles auth, and `gh` is already excluded). If the working remotes are HTTPS, excluding push is harmless-but-unnecessary. Confirm remote protocol during the U1 runtime smoke; drop push from the exclusion if it never touches the agent.
- **R5 — Untrusted-repo hooks run unsandboxed (accepted residual, security-lens).** Because `git commit`/`git push` run outside Seatbelt (KTD5), a malicious/cloned repo's hooks or code-executing git config would execute unsandboxed on an approved commit/push, and push can reach non-allowlisted remotes. Accepted rather than mitigated by hook-neutralization, because neutralizing hooks would break this repo's trusted `prek`/`secretlint` secret-detection gate. Residual mitigations: human approval on every gated write, agent operating in trusted repos, narrow exclusion. Revisit if the agent starts operating in untrusted repos routinely.

## Sources & Research

- `dot_claude/settings.json.tmpl` — current sandbox + permissions config (read this session).
- `dot_config/safehouse/config.tmpl` — safehouse `--enable=1password`, explains why the wrapped path already works.
- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` — nested-Seatbelt degradation; establishes that native sandbox is active only under `command claude`.
- `docs/solutions/integration-issues/1password-ssh-agent-libgit2-ssh-auth-sock.md` — prior 1Password agent socket learning.
- Claude Code v2.1.205 sandbox + permissions docs (claude-code-guide research this session): no Unix-socket sandbox key; deny→ask→allow precedence; `ask` overrides `allow` and fires under `bypassPermissions`; read-only git is built-in no-prompt.
