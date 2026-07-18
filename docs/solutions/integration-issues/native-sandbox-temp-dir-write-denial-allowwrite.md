---
title: "Native Bash sandbox silently denies /tmp and /var/folders writes; add them to allowWrite"
date: 2026-07-18
category: integration-issues
module: claude-code
problem_type: integration_issue
component: tooling
symptoms:
  - "tools that hardcode /tmp/... fail under the sandbox with 'Operation not permitted' and no approval prompt"
  - "a bare `mktemp -d` on macOS fails with 'mkdtemp failed on /var/folders/...: Operation not permitted' even when $TMPDIR is writable"
  - "filesystem write denials are silent — unlike a blocked network domain there is no prompt, just a failed write"
root_cause: missing_permission
resolution_type: config_change
severity: medium
tags: [harness-engineering, claude-code, sandbox, seatbelt, filesystem, allowwrite, tmpdir, macos, silent-failure]
---

# Native Bash sandbox silently denies /tmp and /var/folders writes; add them to allowWrite

## Problem

Under Claude Code's native Bash sandbox (macOS Seatbelt), the default filesystem write boundary is only the working directory plus the specific session `$TMPDIR` (Claude Code overrides `$TMPDIR` to something like `/tmp/claude-<uid>`). Writes to the general temp roots — `/tmp`, `/private/tmp`, and the macOS Darwin per-user temp `/var/folders/<xx>/<hash>/T/` — are denied, and the denial is **silent**: unlike a blocked network domain (which prompts), a filesystem write denial just fails with `Operation not permitted` and no approval prompt.

## Symptoms

- A tool that hardcodes `/tmp/foo` fails with `Operation not permitted` and no prompt.
- A bare `mktemp -d` on macOS fails with `mkdtemp failed on /var/folders/...: Operation not permitted`, even though `$TMPDIR` is exported to a sandbox-writable dir — because BSD `mktemp` resolves the bare form to the Darwin per-user temp (`_CS_DARWIN_USER_TEMP_DIR` under `/var/folders`), ignoring `$TMPDIR`.
- The failure is easy to misdiagnose because nothing prompts and the error surfaces downstream (an empty path, a later command failing on a missing file).

## What Didn't Work

- **Relying on the default `$TMPDIR` grant.** Claude Code makes the session temp dir writable and points `$TMPDIR` at it, so well-behaved tools that honor `$TMPDIR` work. But tools that hardcode `/tmp` or call a bare `mktemp -d` bypass `$TMPDIR`, so the default grant doesn't help them.
- **Fixing each tool at the call site.** The one previously observed occurrence (a Makefile `mktemp -d`, see the related doc below) was fixed with `"${TMPDIR:-/tmp}/name-XXXXXX"`. That works per-call-site but doesn't scale to third-party or agent-invoked tools the config can't reach.

## Solution

Add the low-risk OS temp roots to `sandbox.filesystem.allowWrite` in `dot_claude/settings.json.tmpl`:

```jsonc
"allowWrite": [
  "/private/tmp",
  "/tmp",
  "/var/folders",
  "~/.cache", "~/.cargo", "~/.npm", "~/.rustup", "~/Library/pnpm/store", "~/go"
]
```

- **`/tmp` + `/private/tmp`** — declare both. On macOS `/tmp` is a symlink to `/private/tmp`, and Claude Code registers the symlink and resolved paths as separate sandbox entries (its own session dir appears as both `/tmp/claude` and `/private/tmp/claude`), so relying on implicit symlink resolution risks one form staying denied.
- **`/var/folders`** — the narrowest expressible grant covering the Darwin per-user temp. The sandbox path system is prefix-match with no glob, and the middle path segments are a per-boot hash, so the temp subtree (`.../T/`) can't be addressed more precisely than the `/var/folders` prefix.
- Paths use the absolute `/`-prefix — **not** `~/`, and **not** chezmoi's `.chezmoi.homeDir` template variable (sandbox filesystem entries are literal OS paths).

Verify with a render-then-`jq` assertion, not just `make check-templates` (which only confirms the template renders — see the related doc):

```sh
tmpconfig=$(mktemp "${TMPDIR:-/tmp}/cc-test-XXXXXX.toml")
printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
chezmoi execute-template --config "$tmpconfig" --source "$(pwd)" < dot_claude/settings.json.tmpl \
  | jq -e '.sandbox.filesystem.allowWrite | index("/tmp") and index("/var/folders")' >/dev/null && echo PASS
rm -f "$tmpconfig"
```

## Why This Works

`allowWrite` extends the OS-enforced write boundary to the named prefixes, so any sandboxed process (and its children) can write there. Granting the temp roots is low-risk because they hold no `$PATH` executables, system config, or shell rc — the escalation surface the sandbox docs warn about — so a sandboxed write can't plant a binary or config that later runs in a different security context. This is the same reasoning that keeps `~/.local/share/mise` (which *does* hold `$PATH`-resident executables) deliberately OUT of `allowWrite`.

Security review of this change confirmed it introduces **no new escalation primitive**: the session `$TMPDIR` is already writable, so a write-then-execute-unsandboxed path via an `excludedCommands` tool (`open`/`osascript`, which run outside the sandbox) already existed before this change — widening to more temp roots adds writable space, not a new capability.

## Prevention

- **When a sandboxed tool fails with `Operation not permitted` on a path, check whether the path is inside the `allowWrite` boundary before debugging the tool.** Silent write denials look like tool bugs but are policy.
- **Grant only non-executable, non-config scratch dirs.** Before adding a path to `allowWrite`, confirm it holds no `$PATH` executables, system config, or shell rc. Temp/scratch and build-cache dirs qualify; dirs like `~/.local/share/mise` or anything on `$PATH` do not.
- **`/var/folders` is a proactive grant, not evidence-forced.** A ce-doc-review adversarial pass noted the only *observed* failure was already call-site-fixed, so this grant covers the failure *class* (macOS default temp for `$TMPDIR`-ignoring tools) rather than a live break. A narrower alternative — ship `/tmp` + `/private/tmp` only and defer `/var/folders` until a concrete non-Makefile failure appears — is defensible; it was kept because `/var/folders` is the macOS OS-default temp.
- **Filesystem writes fail silently; network reaches prompt.** Remember the asymmetry when reasoning about sandbox denials — a missing domain prompts, a missing write path does not.

## Related Issues

- `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md` — the prior observation of the `/var/folders` denial for bare `mktemp -d`, fixed there at the call site via `${TMPDIR:-/tmp}`. This change is the general sandbox-config resolution.
- `docs/solutions/integration-issues/check-templates-render-only-no-json-validation.md` — why `make check-templates` is not sufficient to verify a JSON-shaped `.tmpl` edit, and the `jq` verification pattern used above.
- `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md` — the native-sandbox `excludedCommands` / git-signing interaction referenced by the security analysis.
- PR #227 (`feat(claude): sandbox allowWrite に低リスク temp ディレクトリを追加`) — the change this documents.
