---
title: "feat: Add low-risk temp directories to sandbox allowWrite"
date: 2026-07-18
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
depth: standard
---

# feat: Add low-risk temp directories to sandbox allowWrite

## Summary

Add the shared system temp directories (`/tmp`, `/private/tmp`, and macOS's per-user `/var/folders` scratch tree) to `sandbox.filesystem.allowWrite` in `dot_claude/settings.json.tmpl`. Claude Code's native Bash sandbox writes only to the working directory and the session `$TMPDIR` by default; any tool that hardcodes `/tmp` or calls a bare `mktemp -d` (which macOS resolves to `/var/folders/.../T/`, ignoring `$TMPDIR`) fails with a **silent** `Operation not permitted`. These are low-risk, OS-managed scratch locations — they hold no `$PATH` executables, system config, or shell rc files — so granting write access removes recurring agent friction without meaningfully weakening the sandbox.

**Product Contract preservation:** N/A — solo `ce-plan-bootstrap` run, no upstream requirements doc.

---

## Problem Frame

The native sandbox (`sandbox.enabled: true`) confines Bash writes to cwd + the session temp dir. Two well-documented failure modes remain:

1. **Hardcoded `/tmp`** — tools and scripts that write to `/tmp/foo` directly hit a denied path.
2. **Bare `mktemp -d` on macOS** — BSD `mktemp` resolves the bare/`-t` form to `_CS_DARWIN_USER_TEMP_DIR` (`/var/folders/.../T/`) even when `$TMPDIR` is exported to a sandbox-writable path. This is empirically confirmed in `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`: `mktemp -d` reported `mkdtemp failed on /var/folders/...: Operation not permitted` while `$TMPDIR=/tmp/claude-501`.

Because filesystem write denials are **silent** (no approval prompt, unlike network access), these failures surface as confusing downstream errors or — worse — silent no-ops (the Makefile mktemp case masked a `PASS`). The user wants low-risk temp directories pre-declared so agents stop hitting this wall.

The existing `allowWrite` list only covers tool build caches (`~/.cache`, `~/.cargo`, `~/.npm`, `~/.rustup`, `~/Library/pnpm/store`, `~/go`); it does not cover general-purpose temp scratch space.

---

## Requirements

- **R1.** `/tmp` is writable inside the sandbox for tools that hardcode it.
- **R2.** The macOS per-user Darwin temp directory (`/var/folders/.../T/`) is writable, so bare `mktemp -d` succeeds inside the sandbox.
- **R3.** The change grants only low-risk scratch locations — no directory containing `$PATH` executables, system configuration, or shell startup files.
- **R4.** The rendered `~/.claude/settings.json` remains valid JSON (confirmed by an explicit `jq` render assertion, since `make check-templates` only verifies the template renders without error, not JSON validity), and `make check-templates` passes.
- **R5.** The `CLAUDE.md` "Native Bash sandbox" documentation reflects the new temp-directory grants and their rationale.

Success criteria: after `chezmoi apply`, a sandboxed Bash command can write to `/tmp/<x>` and `mktemp -d` succeeds, with no other change to the sandbox policy diff.

---

## Key Technical Decisions

### KTD1. Add `/tmp` **and** `/private/tmp` as an explicit pair
On macOS `/tmp` is a symlink to `/private/tmp`. Seatbelt rules operate on canonicalized paths, and Claude Code's own session-dir handling already registers both forms (the resolved runtime allowlist lists `/tmp/claude` *and* `/private/tmp/claude` separately). To guarantee the grant holds regardless of whether a tool opens the symlink path or the resolved real path, declare both. Absolute-path prefix (`/tmp`, `/private/tmp`) is correct per the documented prefix rules — `/`-prefixed paths stay literal.
- **Chosen over** declaring only `/tmp` and trusting symlink resolution: the dual-registration in Claude Code's runtime output shows the tool treats these as distinct entries, so relying on implicit resolution risks a path that silently stays denied.

### KTD2. Add `/var/folders` to cover the macOS OS-default per-user temp
`/var/folders/<xx>/<hash>/T/` is the Darwin per-user temp directory (`_CS_DARWIN_USER_TEMP_DIR`) — the path libc temp APIs and a bare `mktemp -d` resolve to on macOS when a tool does not honor the sandbox-overridden `$TMPDIR`. Claude Code points `$TMPDIR` at the writable session dir, so well-behaved tools are unaffected; the residual failure class is tools and libc calls that read the Darwin temp dir directly. Granting it proactively is exactly the "low-risk temp dir agents can use without friction" the request targets. The middle segments are a per-user, per-boot hash (not hardcodable), and the sandbox path system supports only prefix (subpath-inclusive) matching with no glob, so the narrowest expressible grant covering `T/` is the `/var/folders` prefix. The tree is OS-managed per-user scratch/cache space (`T/` temp, `C/` caches) with no `$PATH` executables, system config, or shell rc — within the R3 low-risk bar and the sandbox docs' escalation warning.
- **Evidence and its limits:** the one empirically observed occurrence (`docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md`) was a bare `mktemp -d` failing on `/var/folders/...`, and it was fixed at the call site via `"${TMPDIR:-/tmp}/name-XXXXXX"`. So the Makefile is *precedent that the failure class is real*, not a still-live break this grant is required to fix; no specific third-party offender is currently named. The grant is proactive for the class, not reactive to a live failure.
- **Chosen over** deferring `/var/folders` and fixing each offending tool at the call site: call-site fixes are per-occurrence and cannot reach third-party or agent-invoked tools, whereas one prefix grant covers the class. This is a judgment call — see the Risks section for the narrower-scope alternative surfaced in review.
- **Trade-off (accepted):** `/var/folders` is broader than the temp subdir alone (it also exposes the per-user `C/` cache subtree to writes). Accepted because the tree is non-executable, non-config scratch space and the prefix system offers no narrower expression.
- **`excludedCommands` interaction (accepted, not a new primitive):** a file the sandboxed agent stages in the newly-writable temp dirs could be executed *unsandboxed* by an `excludedCommands` tool (`open`/`osascript`/`git`). This is not a new escalation primitive — the session `$TMPDIR` (`/tmp/claude-...`) is already writable, so the same staging is already possible today — and the dominant executor (`git commit`/`push`) is `ask`-gated per `permissions.ask`. Noted so the threat analysis is complete rather than resting only on the static `$PATH`/config/shell-rc surface.

### KTD3. Absolute paths, not `~/` or `.`-relative
These are system paths, so they use the absolute `/` prefix. A `.`/no-prefix path would resolve relative to `~/.claude` for user settings (not the intent), and `~/` is wrong for `/tmp`. This matches the documented example `"allowWrite": ["~/.kube", "/tmp/build"]`.

### KTD4. Document the grant inline and in `CLAUDE.md`
The `filesystem` block currently has no inline comments, but the file is documentation-dense elsewhere. Add a short `{{/* */}}` template comment above the new entries explaining why these temp dirs are safe, and extend the `CLAUDE.md` "Native Bash sandbox" paragraph, so the security rationale is not lost to a future reader auditing the allowlist.

---

## Implementation Units

### U1. Add temp directories to `sandbox.filesystem.allowWrite`
- **Goal:** Grant sandbox write access to `/tmp`, `/private/tmp`, and `/var/folders`.
- **Requirements:** R1, R2, R3, R4 (advances KTD1, KTD2, KTD3, KTD4).
- **Dependencies:** none.
- **Files:**
  - `dot_claude/settings.json.tmpl` (modify)
- **Approach:**
  - In the `sandbox.filesystem.allowWrite` array (currently lines ~435-442), add `/tmp`, `/private/tmp`, and `/var/folders`.
  - Keep the existing `~/`-prefixed cache entries; the new absolute temp entries can be grouped together (e.g., listed first or in their own visual group) with 2-space indentation matching the surrounding array.
  - Add a concise `{{/* */}}` template comment immediately above the temp entries stating they are low-risk OS-managed scratch dirs (no `$PATH` executables / system config / shell rc), that `/tmp`+`/private/tmp` are the macOS symlink pair, and that `/var/folders` covers the bare-`mktemp -d` Darwin temp path. Keep it short — one or two lines.
  - Preserve valid JSON: the `allowWrite` array is followed by `denyRead`/`allowRead`; ensure the trailing comma after the array's closing bracket and the rest of the `filesystem` object stay intact.
- **Patterns to follow:** existing `allowWrite` entries and the heavy `{{/* */}}` comment style already used throughout `settings.json.tmpl` (e.g., the `excludedCommands` and `permissions.ask` comment blocks).
- **Execution note:** This is a config/template change with no unit-testable logic; prefer render/dry-run smoke verification over unit coverage.
- **Test scenarios:**
  - Covers R4. `make check-templates` passes. Note this target only confirms the `.tmpl` *renders without error* (`chezmoi execute-template ... > /dev/null`, exit-code check); it does **not** parse the output as JSON or assert entry presence, so it is necessary but not sufficient.
  - Covers R4. Explicit verification (the real presence+validity guard): render `dot_claude/settings.json.tmpl` with a test config and pipe through `jq` to (a) confirm valid JSON and (b) assert `.sandbox.filesystem.allowWrite` contains `/tmp`, `/private/tmp`, and `/var/folders`. This matters because a malformed edit (dropped or doubled comma after the array) renders fine and passes `check-templates` silently — the exact silent-failure class this plan exists to prevent.
  - `chezmoi apply --dry-run` shows only the intended `allowWrite` additions in `~/.claude/settings.json` and no unrelated diff.
  - Test expectation: no unit tests added — pure declarative config, verified by template render + `jq` assertion + dry-run.
- **Verification:** `make check-templates` passes (render succeeds); the `jq` assertion above confirms valid JSON and the three new `allowWrite` entries; `chezmoi apply --dry-run` diff is limited to the three new `allowWrite` entries (plus the CLAUDE.md change from U2 if applied).

### U2. Update `CLAUDE.md` "Native Bash sandbox" documentation
- **Goal:** Record the new temp-directory grants and their low-risk rationale in the project docs.
- **Requirements:** R5 (advances KTD4).
- **Dependencies:** U1 (document what U1 implements).
- **Files:**
  - `CLAUDE.md` (modify)
- **Approach:**
  - In the "Native Bash sandbox (migration target)" paragraph, where `filesystem.allowWrite` is described (it currently enumerates the tool caches and explains the cwd+tmp default boundary), add a clause noting that `/tmp`, `/private/tmp`, and `/var/folders` are also granted so hardcoded-`/tmp` writes and bare `mktemp -d` (macOS Darwin temp) succeed inside the sandbox, and that these are low-risk OS scratch dirs deliberately excluded from the executable/config/shell-rc escalation surface.
  - Keep it concise and in English (per the `documentation-language` rule for agent-facing docs). Do not restructure the surrounding paragraph.
- **Patterns to follow:** the existing sandbox paragraph's density and English-only agent-doc convention.
- **Execution note:** Docs-only; no tests.
- **Test scenarios:** Test expectation: none — documentation prose change, no behavioral surface.
- **Verification:** `make scan-sensitive` passes (all `.md` scanned for PII); the paragraph reads coherently and accurately describes the U1 change.

---

## Scope Boundaries

**In scope:**
- Adding `/tmp`, `/private/tmp`, `/var/folders` to `sandbox.filesystem.allowWrite`.
- Documenting the change in `CLAUDE.md` and an inline template comment.

**Out of scope (non-goals):**
- Changes to `denyRead`/`allowRead`, `network`, `excludedCommands`, or `permissions`.
- Any change to the safehouse (`dot_config/safehouse/config.tmpl`) or cco (`dot_config/cco/allow-paths.tmpl`) configs — those are the *outer* wrapper; this plan touches only the native inner sandbox.
- Migrating off the safehouse wrapper (tracked separately by the native-sandbox migration).

### Deferred to Follow-Up Work
- Writing a `docs/solutions/` entry capturing this tuning — owned by `ce-compound` after the change lands, not part of this plan.
- Narrowing `/var/folders` to only the `T/` temp subtree if a future Claude Code release adds glob support to sandbox paths.

---

## Risks & Dependencies

- **`/var/folders` breadth (low).** Granting the whole `/var/folders` prefix also permits writes to the per-user cache subtree, not just temp. *Mitigation:* the tree is non-executable, non-config OS scratch space; the sandbox docs' escalation warning targets `$PATH`/system-config/shell-rc dirs, none of which live here. The prefix system offers no narrower expression. Documented as an accepted trade-off (KTD2).
- **`/var/folders` necessity is proactive, not evidence-forced (design call, surfaced in review).** The only *observed* `/var/folders` failure (the Makefile `mktemp -d` case) was already fixed at the call site, so this grant is justified by the failure **class** (macOS default temp for TMPDIR-ignoring tools) rather than a live break. *Narrower alternative:* ship `/tmp` + `/private/tmp` now and defer `/var/folders` until a concrete non-Makefile bare-`mktemp -d` failure is observed. *Kept in scope* because `/var/folders` is the macOS OS-default temp and the request explicitly asks to grant low-risk temp dirs proactively — surfaced here so the reviewer/user can elect the narrower scope at PR review.
- **Symlink resolution assumption (low).** If Claude Code canonicalizes `/tmp`→`/private/tmp` internally, declaring both is redundant but harmless; if it does not, declaring both is required. Declaring both is safe either way (KTD1).
- **No behavioral test harness (low).** The sandbox boundary itself cannot be exercised from within this session (nested-Seatbelt conflict degrades the inner sandbox under the wrapped `claude`; see `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md`). *Mitigation:* verify via template render + `chezmoi apply --dry-run`; the runtime grant is validated empirically against the documented default-boundary behavior.
- **Dependency:** none external. U2 depends on U1.

---

## Sources & Research

- Claude Code sandboxing docs (`https://code.claude.com/docs/en/sandboxing`) — default write boundary is cwd + session `$TMPDIR`; write denials are silent; path prefixes (`/` absolute, `~/` home, `.`/none → project-root or `~/.claude` for user settings); documented example `"allowWrite": ["~/.kube", "/tmp/build"]`; privilege-escalation warning naming `$PATH`/system-config/shell-rc dirs as the dangerous write-grant surface. **Load-bearing:** shaped KTD2 and KTD3.
- `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md` — empirical proof that bare `mktemp -d` on macOS resolves to `/var/folders/.../T/` and fails in the sandbox even with `$TMPDIR` writable. **Load-bearing:** motivates R2/KTD2.
- `dot_claude/settings.json.tmpl` (lines ~420-468) — current `sandbox` block and `allowWrite` list.
- `CLAUDE.md` "Native Bash sandbox (migration target)" — existing documentation of the `filesystem` policy and its rationale.
- `docs/plans/2026-06-22-001-feat-claude-native-sandbox-plan.md` (KTD5/KTD6) — prior design of the filesystem allowWrite/denyRead policy this plan extends.
