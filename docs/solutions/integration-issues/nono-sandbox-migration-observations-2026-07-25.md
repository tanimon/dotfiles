# nono Sandbox Migration — Observation Phase

**Date:** 2026-07-25
**nono version:** 0.69.0
**Profile:** `dot_config/nono/profiles/claude-seal.json` (extends the `claude-code` pack profile from `nolabs-ai/claude`)
**Platform:** macOS (Seatbelt backend)

## Scope of this pass

The observation phase in the plan assumed an interactive Claude Code session driven by hand. This pass
automated only the rows that can be settled with one-shot `nono run` / `nono why` probes. Rows that
require in-session tool behaviour are reported UNVERIFIED with the reason, not guessed at.

`claude()` still routes through safehouse throughout. Every probe below is an explicit
`nono run --profile claude-seal -- <cmd>` invocation, so daily work was never at risk.

**Important methodology note:** these probes must run with the *outer* Claude Code Bash sandbox
disabled. Running `nono run` inside another Seatbelt sandbox makes nono fail to write its own session
and audit state (`Failed to create session directory ~/.local/state/nono/audit/...: Operation not
permitted`), which contaminates every result. The first attempt hit exactly that and was discarded.

## Verdict table

| # | Item | What was probed | Verdict |
|---|------|-----------------|---------|
| 1 | `git commit` with 1Password signing | Throwaway repos under `~/.cache`; commit object inspected for a `gpgsig` header | **PASS** (after adding `filesystem.unix_socket`) |
| 2 | `git push` / `git fetch` | `git ls-remote` over SSH and over HTTPS; `nono why --host github.com --port 22` | **FAIL** over SSH |
| 3 | `gh` (keychain auth) | `gh auth status`, `gh issue list` | **FAIL** — left blocked deliberately |
| 4 | `make lint` | Full `make lint` inside nono | **PASS** |
| 5 | `chezmoi diff`, `chezmoi apply --dry-run` | Full-tree and scoped runs with `--source` | **FAIL** — one remaining blocker, see below |
| 6 | MCP: codex | `codex --version`, `codex mcp-server </dev/null`, and a real `claude -p` session | **PASS** (after granting `CODEX_HOME`) |
| 7 | MCP: deepwiki | Real MCP connection inside a `claude -p` session | **PASS** |
| 8 | gstack `/browse` | not run | **UNVERIFIED** |
| 9 | WebFetch / WebSearch | not run | **UNVERIFIED** |
| 10 | Hooks and statusline | All four hook scripts, plus the `node --experimental-strip-types` statusline | **PASS** |
| 11 | Plugin loading | Plugin/skill loading inside a real `claude -p` session | **PASS** |
| 12 | `--settings` precedence | Contrast pair: `claude -p` with and without the settings override, each running a Bash tool call | **PASS** |

**Totals: 7 PASS, 3 FAIL, 2 UNVERIFIED.**

## The four load-bearing questions

### Row 1 — `git commit` with 1Password signing: PASS

Settled, and the mechanism was not the one the plan assumed.

`/Applications/1Password.app/Contents/MacOS/op-ssh-sign` **is** covered by `system_read_macos` — this
closes the plan's open question:

```
ALLOWED
  Reason: granted_path
  Granted by: /Applications
  Access: read
  Source: group:system_read_macos
```

`read_file` + `bypass_protection` on the agent socket were **not** sufficient. With the pre-existing
profile, signing failed:

```
error: 1Password: Could not connect to socket. Is the agent running?
fatal: failed to write commit object
```

The cause is documented in `nono profile guide`: on macOS, Seatbelt treats `connect(2)` on a UNIX
socket as a *network* operation, so a filesystem read grant does not authorize it. nono 0.69.0 has a
purpose-built key, `filesystem.unix_socket`, and with it the commit succeeds and is genuinely signed:

```
$ git cat-file commit HEAD | grep -c '^gpgsig'
1
```

Verifying the signature deserves a caveat. `git log --show-signature` prints `No signature`, but that
is a **local config gap, not a nono finding** — it is accompanied by
`error: gpg.ssh.allowedSignersFile needs to be configured and exist for ssh signature verification`.
The `gpgsig` header in the raw commit object is the authoritative check, and it is present. A commit
created *without* a signature was specifically watched for and did not occur: before the fix the
commit was not created at all (exit 128), so there was no silent-unsigned failure mode.

The grant was also minimized: `filesystem.unix_socket` **alone** is sufficient. The socket's
`read_file` entry and the whole `bypass_protection` array were verified redundant and removed, which
narrows the boundary — the profile no longer overrides a deny rule on a keychain-adjacent path.

### Row 2 — SSH transport: FAIL, and it cannot be fixed in the profile

```
ssh: connect to host github.com port 22: Operation not permitted
fatal: Could not read from remote repository.
```

The repository's remote is SSH. Egress is restricted to the local filtering proxy, so raw TCP to
port 22 is refused at the Seatbelt layer.

**There is no profile key that fixes this on macOS.** `network.open_port` is localhost-only
("Localhost TCP IPC (connect+bind)"), `allow_port` / `port_allow` are documented as legacy aliases for
it, and the CLI's `--allow-connect-port` is marked "Linux Landlock V4+ only". So the plan's fallback
(b) — `network.open_port` — does not apply.

**A trap worth recording:** `nono why` reports this connection as ALLOWED.

```
$ nono why --host github.com --port 22 --profile claude-seal
ALLOWED
  Reason: proxy_allowed
  Source: domain allowlist
```

`nono why --host` models only the HTTP(S) proxy allowlist. It does **not** model the raw-TCP
restriction, so it produces a false positive for non-HTTP ports. Trust it for HTTP(S) reachability
only.

**Fallback (a), an HTTPS remote, works for reads.** `git ls-remote https://github.com/...` returned
`refs/heads/main` cleanly through the proxy. **Authenticated push over HTTPS is UNVERIFIED**: the
configured credential helper is `osxkeychain`, and it returns no stored credential for
`github.com` — including outside nono. So no HTTPS credential has ever been established here, and
nothing was pushed to test it (out of scope by instruction).

**Recommendation:** fallback (a), an HTTPS remote, but note it is not a drop-in — it needs a working
credential source first, and `gh auth setup-git` would make `gh` the helper, which runs into row 3.
The repository's remote was deliberately left untouched.

### Row 6 — codex MCP under nested Seatbelt: PASS

**Nested Seatbelt does not break the codex MCP stdio server.** That concern does not materialize.
`codex --version` runs fine inside nono, `codex mcp-server </dev/null` exits 0 with zero output (the
correct EOF behaviour), and inside a real session:

```
MCP server "codex": Successfully connected (transport: stdio) in 89ms
```

The only blocker was filesystem, not sandbox nesting. `CODEX_HOME` is set by the surrounding tooling
to a path under `~/Library/Application Support/orca/codex-accounts/<uuid>/home`, which the profile did
not grant:

```
Error: error loading config: failed to read CODEX_HOME ".../codex-accounts/<uuid>/home":
Operation not permitted (os error 1)
```

**Answering the plan's conditional branch: `codex mcp-server` does NOT accept `--sandbox`.** Its
entire flag set is `-c/--config`, `--strict-config`, `--enable`, `--disable`, `-h`. The nearest
equivalent would be `-c sandbox_mode=...` or `-c 'sandbox_permissions=[...]'`. None of this is needed,
since the server works once the filesystem grant is in place.

### Row 12 — `--settings` precedence: PASS, and the contrast run is decisive

**`--settings '{"sandbox":{"enabled":false}}'` does override the base settings file's
`sandbox.enabled: true`.** The two runs are *not* identical, which is what makes this conclusive.

Both runs were made to execute a real Bash tool call. This matters: the native sandbox engages
per-Bash-command, not at startup, so an earlier probe with a tool-free prompt proved nothing and was
discarded.

- **With `--settings`:** the Bash call succeeded first try. No `sandbox_apply`, no Seatbelt line, no
  sandbox-related error anywhere in the debug log.
- **Without `--settings`:** the Bash call **failed**:

  ```
  "hook_event_name":"PostToolUseFailure","tool_name":"Bash",
  "error":"Exit code 71\nsandbox-exec: sandbox_apply: Operation not permitted"
  ```

So the flag is load-bearing, not cosmetic — without it, Bash tool calls inside nono break.

**This corrects a claim in `CLAUDE.md`.** The current text says `failIfUnavailable: false` "degrades it
to unsandboxed Bash" gracefully. Observed behaviour is a hard tool failure with exit 71.
`failIfUnavailable: false` evidently covers *sandbox unavailability*, not a runtime `sandbox_apply`
EPERM. The session did eventually recover, but only because the nono pack injects guidance on denial
and the agent retried with `dangerouslyDisableSandbox: true` per-command — that is recovery by retry,
not graceful degradation.

## Profile changes, each tied to an observed denial

| Change | Motivating denial |
|--------|-------------------|
| `filesystem.unix_socket += 1Password agent socket` | `error: 1Password: Could not connect to socket. Is the agent running?` / `fatal: failed to write commit object` (row 1) |
| Removed the socket's `read_file` entry and the whole `bypass_protection` array | Not a denial — verified redundant once `unix_socket` was present. Narrowing, not widening |
| `filesystem.allow += $HOME/Library/Application Support/orca/codex-accounts` | `failed to read CODEX_HOME ".../codex-accounts/<uuid>/home": Operation not permitted` (row 6) |
| `filesystem.read += $XDG_CONFIG_HOME/cco` | `chezmoi: .config/cco: lstat ...: operation not permitted` (row 5) |
| `filesystem.read += $XDG_CONFIG_HOME/cmux` | `chezmoi: .config/cmux: lstat ...: operation not permitted` (row 5) |
| `filesystem.read += $XDG_CONFIG_HOME/safehouse` | `chezmoi: .config/safehouse: lstat ...: operation not permitted` (row 5, observed via a scoped diff) |
| `filesystem.read_file += $HOME/.gitignore` | `chezmoi: .gitignore: lstat ...: operation not permitted` (row 5, scoped diff) |
| `filesystem.read_file += $HOME/.zshrc`, `$HOME/.zprofile` and `filesystem.bypass_protection` for all four chezmoi-managed shell configs | `chezmoi: .bash_profile: open ...: operation not permitted`, and the same for `.bashrc`, `.zshrc`, `.zprofile` (row 5) |

**No host was added to `network.allow_domain`.** Across every probe log — `make lint`, two full
`claude -p` sessions, chezmoi, git, codex, gh — **not one `DENY CONNECT` line was emitted**. The
existing allowlist plus the `developer` preset covered everything the probed work needed.

### Why the shell-config `bypass_protection` grant is defensible

`~/.bashrc`, `~/.bash_profile`, `~/.zshrc` and `~/.zprofile` are blocked by the required
`deny_shell_configs` group ("shell configuration files that may embed secrets"), and a `read_file`
grant does **not** override a deny group — `bypass_protection` is required. Granting read on exactly
these four is low-risk because all four are chezmoi-managed: their content lives in this
version-controlled repository and is scanned by `make lint`'s secretlint pass, so the "may embed
secrets" premise does not hold for them. The grant is per-file; the group still blocks
`~/.profile`, `~/.zshenv`, `~/.zlogin`, `~/.zlogout`, `~/.bash_login`, `~/.bash_logout`,
`~/.config/fish`, `~/.env`, `~/.envrc`. Read only — a real `chezmoi apply` writing these four files
would additionally need write, which was not granted.

## Left blocked, with consequences

### `~/.config/gh` — the one grant deferred to a human decision

This single path is the sole remaining blocker for **both** row 3 and row 5, and it is a security
decision that should not be made unilaterally.

- Row 3: `gh` cannot start at all. `failed to read configuration: open ~/.config/gh/config.yml:
  operation not permitted`. Granting only `config.yml` moves the failure to `hosts.yml` — gh needs
  both, and `hosts.yml` is the token store. So no narrow grant exists.
- Row 5: chezmoi manages `.config/gh/config.yml` **and** `.config/gh/hosts.yml`, so a full-tree
  `chezmoi diff` must stat that directory.

**It was proven to be the last blocker.** With an ad-hoc `--read ~/.config/gh` (not committed to the
profile), both `chezmoi diff` and `chezmoi apply --dry-run` exit 0 with no denials. Without it, both
fail on that path alone.

Granting it would contradict a deliberate existing decision: `~/.config/gh` sits in
`sandbox.filesystem.denyRead` in `dot_claude/settings.json.tmpl`, specifically to keep the GitHub
token unreadable by the agent. Under the native sandbox that costs nothing because `gh *` is in
`excludedCommands`; nono has no equivalent per-command escape, so the same posture costs a working
`gh` and a working full-tree `chezmoi diff`.

**Recommended path (for the cutover task, not done here):** nono's credential injection rather than a
filesystem grant. `network.credentials` with a `keyring://` credential key lets the supervisor read
the token and inject it at the proxy, handing the sandboxed child only a phantom `nono_<64hex>` token.
That preserves the `denyRead` intent *and* makes `gh` work, but it is a design change well beyond
growing an allowlist.

Aside: the brief's expectation that `chezmoi apply --dry-run` hits a TTY prompt on
`.claude/settings.json` did **not** reproduce. With `~/.config/gh` granted it exits 0 silently.

### Sentry telemetry — the plan's premise here is wrong

The plan states nono has no allow-side host wildcard and that only `deny_domain` accepts `*.host`.
**That is not true of 0.69.0.** `*.ingest.sentry.io` in `allow_domain` both validates and matches at
runtime:

```
$ nono why --host o12345.ingest.sentry.io --profile <candidate-with-wildcard>
ALLOWED
  Reason: proxy_allowed
  Source: domain allowlist
```

The matcher is real and correctly scoped, not a blanket pass. Under the same wildcard-bearing profile,
`pastebin.com` stays DENIED, the apex `ingest.sentry.io` stays DENIED, and an unrelated
`foo.sentry.io` stays DENIED. So enumerating the real org hostname is **not** required — one wildcard
entry would suffice.

**No such entry was added,** because no denial motivated it. The Sentry plugin's MCP server never
attempted a connection during any probe: it is unauthenticated, and a non-interactive session cannot
run the auth flow (`plugin:sentry:sentry` MCP server reported unauthenticated). Its skills load fine.
Consequence: if and when it is authenticated interactively, telemetry to `<org>.ingest.sentry.io`
will be blocked until someone chooses to add `*.ingest.sentry.io`. That is now a one-line choice
rather than a blocked design.

### `statsig.anthropic.com` — blocked, no observed consequence

DENIED by the allowlist. It produced no error and no `DENY CONNECT` in any log, and `claude -p` runs
completed normally. Left blocked.

### `~/.claude.json` config persistence — a real gap with no narrow fix

Repeatedly, in every session:

```
[ERROR] Failed to write file atomically: Error: EPERM: operation not permitted,
        open '$HOME/.claude.json.tmp.<pid>.<hex>'
[ERROR] Config fallback write also failed; continuing without persisting
```

`~/.claude.json` (a symlink to `~/.claude/claude.json`) is itself granted readwrite, as are
`.claude.json.lock` and `.claude.lock`. The failure is the *atomic write*: Claude Code writes a
sibling `~/.claude.json.tmp.<pid>.<hex>` in `$HOME` and renames it, and that randomized sibling is not
covered by any grant.

**No narrow fix exists.** nono has no filesystem glob matching — `$HOME/.claude.json.tmp.*` in
`allow_file` validates but does not match, and `nono why` for a concrete path under it returns
`DENIED ... Suggested fix: --allow $HOME`, i.e. write access to the entire home directory.
That is not acceptable.

Consequence: config state (MCP auth, project trust, history) is not persisted from inside nono.
Claude Code degrades rather than crashing. An untested hypothesis for the cutover task: relocating the
config via `CLAUDE_CONFIG_DIR` into `~/.claude`, which is already granted readwrite recursively. This
was **not** tested here — it mutates config state, and verifying it belongs with the cutover.

### `ps` process enumeration — cosmetic

`[ERROR] execFileNoThrow spawn failed: EPERM ... posix_spawn 'ps'`. Blocked by nono's process-info
policy. No functional impact observed.

## Other findings the cutover depends on

**`--allow-cwd` is required.** With the profile alone, the working directory is denied even though
`workdir.access` is `readwrite`:

```
Sandbox denial: 2 paths blocked.
  $HOME/orca/workspaces/chezmoi/seal (read)
```

`workdir.access` sets the *level* granted, but the grant itself needs `--allow-cwd` (or an interactive
prompt, which a non-interactive run cannot answer). With `--allow-cwd` the directory becomes `r+w`.
Any wrapper must pass it, or be restricted to directories already granted in the profile such as
`~/ghq`.

**`nono profile validate` rejects unknown keys** — confirmed, a hard parse error rather than a warning,
both nested and at the top level:

```
[err]  JSON syntax error: Profile parse error: unknown field `nonexistent_key`,
       expected one of `allow`, `read`, `write`, `allow_file`, `read_file`, `write_file`,
       `unix_socket`, `unix_socket_bind`, ... on line 27 column 17
  Result: invalid (1 error)
```

**`nono profile schema` output is incomplete.** Its `FilesystemConfig` omits all six `unix_socket*`
keys that the parser's own error message enumerates and accepts. Trust the parser error over the
emitted JSON Schema.

**`XDG_CONFIG_HOME` is unset in this environment**, yet the profile's `$XDG_CONFIG_HOME/...` entries
resolve correctly to `~/.config/...` — nono supplies the default. The literal-`$HOME`/
`$XDG_CONFIG_HOME` convention holds.

**The `claude-code` pack grants more than this profile does.** The resolved capability set includes
`~/Library/Keychains` (readwrite, via `bypass_protection` in the pack) and `login.keychain-db`
(readwrite). Worth an explicit look during the cutover, since it is broader than anything this profile
adds.

## Network baseline (`network_profile: "developer"`)

`nono why --host <h> --profile claude-seal` is the cheapest way to answer "is this destination
allowed" without making a request. Re-verified against the grown profile:

**ALLOWED:** `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`,
`api.anthropic.com`, `registry.npmjs.org`, `pypi.org`, `proxy.golang.org`, `mcp.deepwiki.com`,
`chatgpt.com`

**DENIED:** `statsig.anthropic.com`, `pastebin.com`, `webhook.site`, `requestbin.net`, `transfer.sh`,
`0x0.st`, `169.254.169.254`

The preset is genuinely default-deny and narrow: the common exfiltration destinations and the cloud
metadata endpoint are all blocked.

## Detail on the rows that passed quietly

**Row 4 — `make lint`: exit 0, zero network denials, zero path denials.** The richest single probe.
All targets ran: secretlint (silent on success), shellcheck, shfmt, oxlint, oxfmt, actionlint, zizmor,
the `modify_` smoke tests, the script and harness-script tests, `check-templates`, `scan-sensitive`,
and `test-nono-profile`. pnpm dependency resolution worked. Note `zizmor` self-reports running in
offline mode and skipping its token-requiring audits — that is its default, not a nono denial.

**Row 10 — hooks and statusline: PASS.** `harness-briefing.sh`, `harness-doctor.sh`,
`harness-reflect-trigger.sh` and `notify-wrapper.sh` each exited 0 with no denials. The statusline
runs under `node --experimental-strip-types` (v24.13.1) and its output inside nono is byte-identical
to its output outside nono, including the git branch and diff stats. The `N/A` usage bars appear in
both, so they are a pre-existing baseline rather than a sandbox effect.

**Row 11 — plugin loading: PASS.** Seven plugins loaded with no failures — `ecc` (278 skills),
`compound-engineering` (32), `superpowers` (14), `sentry` (10), and one each from
`claude-md-management`, `skill-creator`, and the pack's own `nono` plugin.

## Not verified in this pass

| # | Item | Why | What would close it |
|---|------|-----|---------------------|
| 8 | gstack `/browse` (Chromium launch) | In-session tool behaviour. Needs a live interactive Claude Code session; cannot be driven from one-shot commands | Run `/browse` inside `nono run --profile claude-seal -- claude --settings '{"sandbox":{"enabled":false}}'`, confirm Chromium launches, and record which sites 403 |
| 9 | WebFetch / WebSearch | Same — these are in-session tools, not CLI entry points | Exercise both in an interactive session; WebSearch is expected to work via `api.anthropic.com`, WebFetch will be bounded by `allow_domain` |
| 2 | Authenticated `git push` over HTTPS | Pushing was out of scope, and no HTTPS credential exists even outside nono | Establish an HTTPS credential source, then test `git push` from a throwaway clone |
| — | `CLAUDE_CONFIG_DIR` as a fix for the `.claude.json.tmp` gap | Untested hypothesis; testing it mutates config state | Set it in `environment.set_vars` and confirm the atomic-write EPERM disappears |
| — | Whether `~/.config/gh` should be granted | A security decision, not a technical one | Human decides: grant `read`, or implement nono credential injection |

Rows 3 and 5 are FAIL rather than UNVERIFIED — the cause is known and reproducible, and the fix is a
pending decision rather than missing evidence.
