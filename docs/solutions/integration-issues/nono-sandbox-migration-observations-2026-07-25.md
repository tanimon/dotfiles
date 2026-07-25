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

| # | Item | What was probed | Verdict | Confirmed at |
|---|------|-----------------|---------|--------------|
| 1 | `git commit` with 1Password signing | A signed empty commit **in this worktree**, plus throwaway repos under `~/.cache`; commit object inspected for a `gpgsig` header | **PASS** | final profile |
| 2 | `git push` / `git fetch` | `git ls-remote` and `git fetch --dry-run` over SSH and over the HTTPS rewrite | **PASS** for fetch/ls-remote; `push` never attempted by instruction | final profile |
| 3 | `gh` (keychain auth) | `gh auth status`, `gh issue list` | **PASS** | final profile |
| 4 | `make lint` | Full `make lint` inside nono | **PASS** | final profile |
| 5 | `chezmoi diff`, `chezmoi apply --dry-run` | Full-tree runs with `--source` | **PASS** | final profile |
| 6 | MCP: codex | `codex --version`, `codex mcp-server </dev/null`, and a real `claude -p` session | **PASS** | final profile |
| 7 | MCP: deepwiki | Real MCP connection inside a `claude -p` session | **PASS** | earlier round |
| 8 | gstack `/browse` | not run | **UNVERIFIED** | n/a |
| 9 | WebFetch / WebSearch | not run | **UNVERIFIED** | n/a |
| 10 | Hooks and statusline | All four hook scripts, plus the `node --experimental-strip-types` statusline | **PASS** | earlier round |
| 11 | Plugin loading | Plugin/skill loading inside a real `claude -p` session | **PASS** | earlier round |
| 12 | `--settings` precedence | Contrast pair: `claude -p` with and without the settings override, each running a Bash tool call | **PASS** | earlier round |

**Totals: 10 PASS, 2 UNVERIFIED.**

**"Confirmed at" matters.** The profile was grown across three rounds, so not every row was re-probed
against the final state. Rows 1–6 were re-run against the shipped profile. Rows 7, 10, 11 and 12 passed
in an earlier round and were **not** re-probed — their evidence predates the `gh`, `GIT_CONFIG_*` and
git-write additions. Those additions are all read/write grants and environment variables that no
observed failure ties to those rows, so regression is unlikely but **not verified**. Anyone relying on
rows 7/10/11/12 for the cutover should re-run them.

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
`read_file` entry and its `bypass_protection` entry (the array's only entry at the time) were verified
redundant and removed, which narrows the boundary — the profile no longer overrides a deny rule on a keychain-adjacent path.

Re-verified after `environment.set_vars` gained the `GIT_CONFIG_*` entries (below), since the signing
path depends on nono's env handling: commit exit 0, `gpgsig` still present in the raw object, and
`SSH_AUTH_SOCK` still resolves to the 1Password agent socket inside the sandbox. `set_vars` *adds* to
the environment; it does not replace it wholesale.

**Scope correction — this row now covers this worktree, not only throwaway repos.** The first passes
used repos under `~/.cache`, where the object store sits inside an already-granted path. That was
misleading: committing in *this* repository additionally needs writes to a shared object store outside
it (see row 2), and until those grants were added it would have failed. Verified directly with a signed
empty commit in this worktree, inside nono, with profile grants only:

```
$ nono run --profile claude-seal --allow-cwd -- git commit --allow-empty -m "<probe>"
[tanimon/migrate-sandbox-nono b5bf0a0] ...
$ git cat-file commit HEAD | grep -c '^gpgsig'
1
```

The probe commit was then removed and the pre-probe state confirmed restored (`HEAD` back to
`693c05f`, nothing staged). `git reset --soft` was used rather than `--hard`: the two are equivalent
for an empty commit, and `--soft` cannot destroy uncommitted work in the tree.

A useful side observation: the repository's `prek` pre-commit hook chain (secretlint, oxfmt,
`scan-sensitive`, …) ran inside nono during that commit and completed normally, including its
stash/restore of unstaged changes.

### Row 2 — SSH is impossible; the nono-internal HTTPS rewrite works: PASS

**SSH cannot be made to work under nono on macOS.** Confirmed four ways:

```
$ nono run --profile claude-seal -- env GIT_SSH_COMMAND="ssh -v -o BatchMode=yes" git ls-remote <ssh-url>
ssh: connect to host github.com port 22: Operation not permitted
fatal: Could not read from remote repository.
```

- `--allow-connect-port 22` errors with `not supported on macOS: Seatbelt cannot filter by TCP port`.
- SSH over 443 is also blocked (raw `network-outbound (remote:*:443)`), and `~/.ssh/config` is
  permanently deny-listed on top.
- `network.open_port` is localhost-only ("Localhost TCP IPC (connect+bind)"); `allow_port` and
  `port_allow` are documented as legacy aliases for it.
- Only `--allow-net` would work, which destroys the egress control that is the whole point.

**Chosen fix: rewrite SSH remotes to HTTPS inside nono only,** via `environment.set_vars`:

```json
"GIT_CONFIG_COUNT": "5",
"GIT_CONFIG_KEY_0": "url.https://github.com/.insteadOf",
"GIT_CONFIG_VALUE_0": "git@github.com:",
"GIT_CONFIG_KEY_1": "credential.helper",
"GIT_CONFIG_VALUE_1": "!gh auth git-credential",
"GIT_CONFIG_KEY_2": "credential.interactive",
"GIT_CONFIG_VALUE_2": "false",
"GIT_CONFIG_KEY_3": "credential.guiPrompt",
"GIT_CONFIG_VALUE_3": "false",
"GIT_CONFIG_KEY_4": "core.fsmonitor",
"GIT_CONFIG_VALUE_4": "false"
```

**The rewrite only covers scp-form remotes.** `url.https://github.com/.insteadOf = git@github.com:`
matches `git@github.com:owner/repo.git` — this repository's form, which is why it works. A remote
written as `ssh://git@github.com/owner/repo.git` would **not** be rewritten and would hit the raw-TCP
port-22 denial instead, surfacing as an unexplained `Operation not permitted` rather than an obvious
configuration gap. If such a remote is ever added, extend `insteadOf` to cover `ssh://git@github.com/`
as well.

Indices 2 and 3 exist only to **re-declare settings that would otherwise be lost** — see the collision
note below. Index 4 silences the `network-outbound (…/fsmonitor--daemon.ipc)` denial that git's
fsmonitor daemon triggers on index-heavy commands; it is non-fatal noise, but noise in a security
tool's output trains people to ignore real denials, and disabling a performance optimisation inside a
sandbox costs nothing. Measured effect: `fsmonitor` mentions in probe logs went from 2 to 0, with no
functional regression in any row.

**Why `set_vars` rather than gitconfig:** git reads `GIT_CONFIG_*` from the environment, so the
rewrite exists only for processes nono launches. The user's global gitconfig and the repository's SSH
remotes stay untouched — `git remote get-url origin` still returns the `git@github.com:` URL after all
probes. Egress control is preserved because the rewritten HTTPS traffic still goes through nono's
proxy subject to `allow_domain`. A gitconfig-based rewrite would leak into every unsandboxed git
invocation as well.

Verified with the profile carrying everything and **no ad-hoc flags**. The launching shell was checked
first to confirm it was not supplying the values (see the collision note below):

```
$ nono run --profile claude-seal --allow-cwd -- git ls-remote origin
...
4ae1a018034c11678dc5169df2890a330a7a593e	refs/pull/98/head
exit=0
```

And end-to-end in the actual cutover configuration — a Bash tool call inside a Claude Code session
inside nono:

```
$ ... -- claude --settings '{"sandbox":{"enabled":false}}' -p '... git ls-remote origin HEAD'
74fe2080c9a8dbd985f42d3a58d2606a75a421c2	HEAD
```

**The `GIT_CONFIG_*` collision, and why indices 2–3 are re-declared.** The namespace is numerically
indexed, and **Claude Code sets its own entries at indices 0 and 1** —
`credential.interactive=false`, `credential.guiPrompt=false`, plus `GIT_CONFIG_PARAMETERS`. nono's
`set_vars` **wins** over the launching shell, so with `GIT_CONFIG_COUNT=2` the profile silently shadowed
both of Claude Code's settings and `credential.interactive` resolved to *empty* inside the sandbox.
Losing it matters: it can turn a clean auth failure into an interactive credential prompt, which inside
a sandbox means a wedged session. There is no way to merge with a parent list of unknown length, so the
two settings are re-declared explicitly at indices 2 and 3. Verified fixed — this is the exact thing
that was broken, so it was proved rather than assumed:

```
$ nono run --profile claude-seal --allow-cwd -- git config --get credential.interactive
false
```

All five pairs resolve inside the sandbox (`insteadOf`, `credential.helper`,
`credential.interactive=false`, `credential.guiPrompt=false`, `core.fsmonitor=false`).

The rewrite also survives one layer deeper — inside a Claude Code Bash tool call inside nono, which is
the layer where Claude Code's own `GIT_CONFIG_*` could have clobbered the profile's. Verified against
the shipped five-pair profile (11 variables = `GIT_CONFIG_COUNT` + five key/value pairs):

```
$ ... -- claude --settings '{"sandbox":{"enabled":false}}' -p '... env | grep -c "^GIT_CONFIG"; \
      git config --get url.https://github.com/.insteadOf; git config --get credential.interactive'
11
git@github.com:
false
```

**Any future addition must keep the indices contiguous and `GIT_CONFIG_COUNT` in sync, or git silently
ignores the tail.**

`git fetch` additionally needed filesystem grants, for a reason unrelated to the network. This
repository is a **git worktree** whose object store lives outside it:

```
git-dir:        ~/.local/share/chezmoi/.git/worktrees/seal
git-common-dir: ~/.local/share/chezmoi/.git
```

`--allow-cwd` grants the worktree directory readwrite, but the shared object store is elsewhere and was
read-only, so fetch failed *after* the transport and credential handshake, during object unpacking:

```
error: unable to create temporary file: Operation not permitted
fatal: failed to write object
fatal: unpack-objects failed
```

Isolated to an object write, with no commit and no ref change:

```
$ ... -- sh -c 'echo probe | git hash-object -w --stdin'
error: unable to create temporary file: Operation not permitted
fatal: Unable to add (null) to database
```

This affected **every** write-side git operation in this repository — commit, fetch, pull, rebase,
stash. Resolved with the narrow grants described in the next section. Final state, profile only, no
ad-hoc flags:

```
$ nono run --profile claude-seal --allow-cwd -- git ls-remote origin
...226 refs...
exit=0

$ nono run --profile claude-seal --allow-cwd -- git fetch --dry-run origin
From https://github.com/<owner>/<repo>
 + 900c6b6...f5cdde5 renovate/... -> origin/renovate/...  (forced update)
exit=0
```

The `From https://...` line confirms the `insteadOf` rewrite is live and the fetch went through the
proxy over HTTPS. **Nothing was pushed at any point**, and `push` therefore remains untested.

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

**Why that grant is `allow` (read+write) and not `read`.** The first observed denial was a *read*, so
`read` was the narrower candidate and was tested rather than assumed. It is **not** sufficient — codex
opens a SQLite state database under `CODEX_HOME` for writing:

```
failed to initialize state runtime at .../codex-accounts/<uuid>/home:
failed to open state DB at .../home/state_5.sqlite:
error returned from database: (code: 8) attempt to write a readonly database
Error: Operation not permitted (os error 1)
```

With `read` the MCP server exits 1; with `allow` restored it exits 0 with no output, as before. So the
width is justified by an observed write denial, not by inference.

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

**This corrects a claim in `CLAUDE.md`, and Task 7 should fix the text.** The current wording says
`failIfUnavailable: false` "degrades it to unsandboxed Bash" gracefully. Observed behaviour is a **hard
tool failure with exit 71**. `failIfUnavailable: false` evidently covers *sandbox unavailability*, not
a runtime `sandbox_apply` EPERM. The session did eventually recover, but only because the nono pack
injects `[NONO SANDBOX - PERMISSION DENIED]` guidance on denial and the agent retried with
`dangerouslyDisableSandbox: true` per command — recovery by retry, not graceful degradation.

## Profile changes, each tied to an observed denial

| Change | Motivating denial |
|--------|-------------------|
| `filesystem.unix_socket += 1Password agent socket` | `error: 1Password: Could not connect to socket` / `fatal: failed to write commit object` (row 1) |
| Removed the socket's `read_file` entry and its `bypass_protection` entry (the array's only entry at the time; the array was later repopulated with the four shell configs below) | Not a denial — verified redundant once `unix_socket` was present. Narrowing, not widening |
| `filesystem.allow` (read+write) `+= $HOME/Library/Application Support/orca/codex-accounts` | First observed as a read denial — `failed to read CODEX_HOME ".../codex-accounts/<uuid>/home": Operation not permitted` (row 6). `read` alone was then tested and is **not** sufficient; see the write denial quoted below |
| `filesystem.read += $XDG_CONFIG_HOME/cco` | `chezmoi: .config/cco: lstat ...: operation not permitted` (row 5) |
| `filesystem.read += $XDG_CONFIG_HOME/cmux` | `chezmoi: .config/cmux: lstat ...: operation not permitted` (row 5) |
| `filesystem.read += $XDG_CONFIG_HOME/gh` | `failed to read configuration: open ~/.config/gh/config.yml: operation not permitted` (row 3), and `chezmoi: .config/gh: lstat ...: operation not permitted` (row 5) |
| `filesystem.read += $XDG_CONFIG_HOME/safehouse` | `chezmoi: .config/safehouse: lstat ...: operation not permitted` (row 5, scoped diff) |
| `filesystem.read_file += $HOME/.gitignore` | `chezmoi: .gitignore: lstat ...: operation not permitted` (row 5, scoped diff) |
| `filesystem.read_file += $HOME/.local/state/gh/device-id` | A residual non-fatal `gh` read denial. Named by review rather than independently observed in a `gh` run here, but confirmed load-bearing: without the entry, `nono why --path ~/.local/state/gh/device-id --op read` returns `DENIED / Reason: path_not_granted` |
| `filesystem.read_file += $HOME/.zshrc`, `$HOME/.zprofile` and `filesystem.bypass_protection` for all four chezmoi-managed shell configs | `chezmoi: .bash_profile: open ...: operation not permitted`, and the same for `.bashrc`, `.zshrc`, `.zprofile` (row 5) |
| `environment.set_vars += GIT_CONFIG_* (5 pairs)` | `ssh: connect to host github.com port 22: Operation not permitted` (row 2); indices 2–3 restore Claude Code settings the profile would otherwise shadow; index 4 silences fsmonitor denial noise |
| `filesystem.write += .git/{objects,refs,logs,worktrees}` under `$HOME/.local/share/chezmoi` | `error: unable to create temporary file: Operation not permitted` / `fatal: failed to write object` (row 2 fetch, and every write-side git op in this worktree) |
| `filesystem.write_file += .git/packed-refs`, `.git/packed-refs.lock` | Ref-packing writes during fetch. Named by review rather than surfaced by its own error line here, but both confirmed load-bearing: with `packed-refs.lock` removed, `nono why --path .../packed-refs.lock --op write` returns `DENIED / Reason: insufficient_access`, confirming a `write_file` grant on `packed-refs` does **not** cover the `.lock` sibling |

**No host was added to `network.allow_domain`.** Across every probe log — `make lint`, several full
`claude -p` sessions, chezmoi, git, codex, gh — **not one `DENY CONNECT` line was emitted**. The
existing allowlist plus the `developer` preset covered everything the probed work needed.

### Grant provenance: `open_port: [0]` has no motivating denial, and differs in kind from `allow_domain`

Every entry in the change table above is tied to an observed denial (the two exceptions — the `gh`
`device-id` file and `packed-refs.lock` — were named by review and then each confirmed load-bearing with
a `nono why` DENIED result). `network.open_port: [0]` has neither: it was carried over from the design
seed purely for **parity with the native sandbox's `network.allowLocalBinding: true`**, and no probe in
this pass demonstrated that anything needed it — the row where it would show up, row 8, was never run.
It also differs in kind from the rest of `network`: each `allow_domain` entry names one destination with
a recorded purpose and can be reviewed on its own, while this grants a whole class of local
connectivity. That matters because of what it actually permits — on macOS, port `0` means `localhost:*`:

```
| `open_port` | array of integer | `[]` | Localhost TCP IPC (connect + bind). Aliases: `port_allow`,
  `allow_port`. Port **0**: macOS only (`localhost:*` outbound); Linux: explicit ports. |
        — `nono profile guide`, network field table
```

nono's startup banner reflects it as `ipc  localhost:0`. **Consequence for the egress guarantee:** a
process inside the sandbox can connect to any listener running *outside* it, and such a listener relays
around `allow_domain` completely. Demonstrated during final review — a listener started outside nono
received the bytes `EXFIL-PROBE` from a process inside nono over `127.0.0.1`. So the accurate statement
of the guarantee is "HTTP(S) egress to non-allowlisted hosts is blocked at the kernel level", **not**
"no data can leave by any route".

**Tested during a later touch-up pass, not merely left unprobed.** The hypothesis that `open_port: [0]`
is itself what grants nono's HTTP(S) proxy hop — plausible, since the proxy is itself a localhost
listener — was checked directly. A copy of the profile (`noport`) was deployed with `network.open_port`
deleted entirely:

```
$ nono run --profile noport --allow-cwd -- git ls-remote origin HEAD
f03f808cd97823f14bb550a6f07c8b62e6d9c62a	HEAD
```

Egress succeeded, so the hypothesis is false: nono grants its own proxy hop independently of
`open_port`. This is one command — `git ls-remote`, which exercises the proxy hop — and does not cover
every workflow this pass verified.

**Consequence: removal, not merely narrowing via `open_port_range`, is the candidate once row 8 is
settled.** For the proxy hop specifically, `open_port: [0]` is now established by removal (this probe),
not merely by absence of a denial across the earlier rows. Removing it entirely would close the
localhost relay channel described above. Row 8 (gstack `/browse`) remains **UNVERIFIED** and is the one
plausible localhost consumer — a Chromium CDP endpoint is itself a localhost port — so guessing at
removal now, before row 8 is checked, could break browsing.

**Decision: not narrowed in V1.** Recorded here because the profile itself cannot express the
rationale.

### Why granting `~/.config/gh` read is not a contradiction

`~/.config/gh` also appears in `sandbox.filesystem.denyRead` in `dot_claude/settings.json.tmpl`. That
is **not** in conflict with granting it here, because the two settings govern two different boundaries:

- Under the **native** Bash sandbox, `gh *` is in `excludedCommands` and runs *outside* the sandbox
  entirely. Blocking the config there costs nothing, so denying it is free defence in depth.
- Under **nono**, `gh` runs *inside* the boundary — there is no per-command exclusion — so it needs its
  config to function at all.

Two coherent policies for two different boundaries. The exposure is also smaller than it first looks:
the GitHub token lives in the **macOS keyring**, not in `~/.config/gh/hosts.yml`, which contains zero
token lines. Granting read exposes the account name and protocol preference only. Verified: with the
grant, both `gh auth status` and `gh issue list` exit 0, and `gh auth status` self-reports its
credential source as `(keyring)` — so keyring access is not blocked by nono either.

### Why the git-dir grant is per-subdirectory, and not `write` on `.git`

A blanket `write` on `~/.local/share/chezmoi/.git` also works, and was rejected. It would grant write
to `.git/config` and `.git/hooks`, which is a **sandbox escape path**: a sandboxed agent could plant a
script in `.git/hooks/pre-commit`, or set `core.hooksPath` / `core.sshCommand` in `.git/config`, and it
would then execute **unsandboxed** the next time a human runs git in that repository.

Granting only the four subdirectories that git actually writes — `objects`, `refs`, `logs`,
`worktrees` — plus the two `packed-refs` files is sufficient and keeps `config` and `hooks` unwritable.
Both halves of that claim were verified.

**Scope of that claim, stated precisely:** `config` and `hooks` are unwritable, but that does **not**
mean the escalation path is closed — `write` on `.git/worktrees` reaches an equivalent outcome via
`commondir` redirection. See "Residual 2" below, which is an explicit, argued acceptance.

Sufficient:

```
$ ... -- sh -c 'echo probe | git hash-object -w --stdin'      -> da0c4eb…
$ ... -- git update-ref refs/probe/nono HEAD                  -> ok (refs + reflog writes)
$ ... -- git update-ref -d refs/probe/nono                    -> ok
$ ... -- git fetch --dry-run origin                           -> exit 0
$ ... -- git commit --allow-empty -m '<probe>'                -> exit 0, signed
```

Genuinely narrow — the two negative controls:

```
$ ... -- sh -c 'echo "#!/bin/sh" > ~/.local/share/chezmoi/.git/hooks/probe'
/bin/sh: …/.git/hooks/probe: Operation not permitted
(file was not created)

$ ... -- sh -c 'git config --local probe.x 1; echo "get=[$(git config --get probe.x)]"'
error: could not lock config file …/.git/config: Operation not permitted
get=[]
```

```
$ nono why --path ~/.local/share/chezmoi/.git/hooks --op write --profile claude-seal
DENIED
  Reason: insufficient_access
```

**Pre-existing, accepted residual — this narrow grant does not imply the general case is locked
down.** The profile already grants `allow` (read+write) on `$HOME/ghq`, so for every repository under
there `.git/hooks` and `.git/config` *are* writable:

```
$ nono why --path ~/ghq/<org>/<repo>/.git/hooks  --op write --profile claude-seal   -> ALLOWED (read+write)
$ nono why --path ~/ghq/<org>/<repo>/.git/config --op write --profile claude-seal   -> ALLOWED (read+write)
```

So the hook-planting path is open for `~/ghq` repositories regardless of the chezmoi grant. This is
out of scope here and arguably inherent — an agent that can write a repository's source can already
influence what runs, via `package.json` scripts, Makefiles and so on. It is recorded so that nobody
reads the narrow chezmoi grant as a claim about the general case.

**Residual 2: `commondir` redirection reaches the same escalation by another door — accepted, not
closed.** Keeping `config` and `hooks` unwritable does **not** close the escalation path. `write` on
`.git/worktrees` also grants write to the worktree's own metadata, and these all report ALLOWED for
write under the shipped profile:

```
~/.local/share/chezmoi/.git/worktrees/seal/commondir         ALLOWED
~/.local/share/chezmoi/.git/worktrees/seal/gitdir            ALLOWED
~/.local/share/chezmoi/.git/worktrees/seal/config.worktree   ALLOWED
~/.local/share/chezmoi/.git/objects/info/alternates          ALLOWED
```

Mechanism: rewrite `commondir` so git resolves its common directory to some other agent-writable
location; the agent controls `config` and `hooks` *there*; `core.hooksPath` / `core.sshCommand` from
that config then execute on the next git invocation in this worktree.

**The mechanism is persistence, not immediate sandbox escape.** On the nono path git runs *inside* the
boundary — there is no `excludedCommands` concept — so the planted config executes sandboxed when the
agent itself runs git. What makes it a real risk is that it **survives the session**: it fires
unsandboxed when a human later runs git in this worktree, or when the `command claude` path does, where
`git commit` / `git push` are in the native sandbox's `excludedCommands` and run outside it entirely.
Same outcome as hook-planting, a different door and a delayed fuse.

**The obvious `filesystem` carve-out does not work; a `command_policies` one exists and was deferred.**
`filesystem.deny` does **not** override `filesystem.write` — tested by adding `commondir` to
`filesystem.deny`: the profile validates, and the path still reports
`ALLOWED / Granted by: .../.git/worktrees`. The per-file alternative (narrowing to `write` on
`worktrees/seal/{logs,refs}` plus `write_file` on `index`/`HEAD`/`ORIG_HEAD`/`COMMIT_EDITMSG` and each
`.lock` sibling) is brittle, and a missed `.lock` breaks git in ways that are hard to diagnose later.
But a purpose-built mechanism **does** exist in 0.69: `command_policies.commands.git` is a per-tool
child sandbox whose `fs_read` / `fs_write` lists accept dynamic provider tokens, including
`@git:common-dir` (the git common directory — the absolute path to the main repo's `.git` in a
worktree) and `@git:config-files`. Per `nono profile guide`, these tokens "are opt-in per profile and
ignore repo-local/worktree Git config so a checkout cannot grant itself extra host filesystem access" —
built for exactly this class of problem. V1 is a straight translation and defers all of
`command_policies` (issue #235 — tool-sandboxing `git` / `gh` via `command_policies`), so
this is a **deferral, not an impossibility**. Earlier revisions of this document and of `CLAUDE.md`
claimed no narrow carve-out existed; that was wrong.

**Why accepting it is the right call rather than an oversight.** It is strictly dominated by exposure
that already exists and is inherent to this setup:

- `$HOME/ghq` is granted `allow`, so for every repository under it an agent can write
  `.git/hooks/pre-commit` **directly** — simpler, identical outcome (residual 1 above).
- In this repository the cwd is granted readwrite, so an agent can already edit
  `.pre-commit-config.yaml`, the `Makefile`, `dot_config/zsh/*.zsh` — **and
  `dot_config/nono/profiles/claude-seal.json` itself.** The files that *define* this sandbox live
  inside the writable working tree. That is unavoidable when an agent edits its own dotfiles repo.

Spending brittleness to close `commondir` while those stand would be theatre. The narrow grant is still
worth having — it removes the cheapest path and costs nothing — but it must not be read as a claim that
escalation is prevented.

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

## Corrections to the design doc

### nono DOES support allow-side host wildcards

The plan states nono has no allow-side host wildcard and that only `deny_domain` accepts `*.host`.
**That is not true of 0.69.0.** With `*.ingest.sentry.io` in `allow_domain`, verified against the
deployed profile:

| Host | Result | Meaning |
|------|--------|---------|
| `abc123.ingest.sentry.io` | ALLOWED | the wildcard matches subdomains |
| `ingest.sentry.io` (bare apex) | DENIED | correct strict-subdomain semantics |
| `ingest.sentry.io.attacker.com` | DENIED | no suffix confusion |

Independently reproduced with `o12345.ingest.sentry.io` ALLOWED while `pastebin.com` and
`foo.sentry.io` stayed DENIED under the same profile — so the matcher is real and scoped, not a
blanket pass.

**Consequence:** enumerating a real org hostname is **not** required, and this moots the Sentry half of
the planned follow-up issue. **No entry was added to the profile,** because nothing was denied: the
Sentry plugin's MCP server never attempted a connection during any probe — it is unauthenticated, and a
non-interactive session cannot run the auth flow. Its skills load fine. If it is authenticated
interactively later, telemetry to `<org>.ingest.sentry.io` will be blocked until someone chooses to add
`*.ingest.sentry.io` — now a one-line choice rather than a blocked design.

### `nono why --host` is valid for HTTP(S) only

`nono why --host` models the HTTP(S) proxy allowlist and **nothing else**. It does not model the
raw-TCP restriction, so it reports a false positive for non-HTTP ports:

```
$ nono why --host github.com --port 22 --profile claude-seal
ALLOWED
  Reason: proxy_allowed
  Source: domain allowlist
```

The actual connection is refused (`Operation not permitted`, row 2). **Every `nono why` host
enumeration in this document — including the baseline table below — is therefore valid for HTTP(S)
traffic only.** For anything else, probe the real connection.

## Left blocked or unresolved

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
`DENIED ... Suggested fix: --allow $HOME`, i.e. write access to the entire home directory. That is not
acceptable.

**Consequence for Task 6:** config state (MCP auth, project trust, history) is **not persisted** from
inside nono, and Claude Code degrades silently rather than crashing — easy to miss after cutover. An
untested hypothesis: relocate the config via `CLAUDE_CONFIG_DIR` into `~/.claude`, which is already
granted readwrite recursively. This was **not** tested here — it mutates config state.

### `statsig.anthropic.com` — blocked, no observed consequence

DENIED by the allowlist. It produced no error and no `DENY CONNECT` in any log, and `claude -p` runs
completed normally. Left blocked.

### `ps` process enumeration — cosmetic

`[ERROR] execFileNoThrow spawn failed: EPERM ... posix_spawn 'ps'`. Blocked by nono's process-info
policy. No functional impact observed.

## Other findings the cutover depends on

**`--allow-cwd` is required — Task 6 must pass it.** With the profile alone, the working directory is
denied even though `workdir.access` is `readwrite`:

```
Sandbox denial: 2 paths blocked.
  $HOME/orca/workspaces/chezmoi/seal (read)
  /home (read)
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
(readwrite). Broader than anything this profile adds.

**That look happened during final review. Closed as a documented, accepted residual — the profile was
not changed.** The pack profile
(`~/.config/nono/packages/nolabs-ai/claude/profiles/claude.json`) lists `$HOME/Library/Keychains`
in **both** `filesystem.allow` (read+write) and `filesystem.bypass_protection`, which is why the
required `deny_keychains_macos` group does not stop it. Re-confirmed under the shipped profile:

```
$ nono why --path ~/Library/Keychains --op read  --profile claude-seal   -> ALLOWED (read+write, Source: profile)
$ nono why --path ~/Library/Keychains --op write --profile claude-seal   -> ALLOWED (read+write, Source: profile)
$ nono why --path ~/Library/Keychains/login.keychain-db --op read  ...   -> ALLOWED (read+write, Source: group:claude_code_macos)
$ nono why --path ~/Library/Keychains/login.keychain-db --op write ...   -> ALLOWED (read+write, Source: group:claude_code_macos)
```

Three reasons it is accepted rather than fixed:

- **Not removable.** nono appends array values across `extends`, and `nono profile guide` states
  plainly that "there is no mechanism to remove inherited filesystem paths" — `groups.exclude` handles
  groups only. Short of abandoning `extends` on the pack profile, the grant stays.
- **Not a regression introduced by this migration.** The native-sandbox path's
  `sandbox.filesystem.denyRead` in `dot_claude/settings.json.tmpl` lists `~/.ssh`,
  `~/.aws/credentials`, `~/.config/gh`, `~/.git-credentials`, `~/.netrc` — and **not**
  `~/Library/Keychains` — so that path never blocked it either. (Review also reported that
  safehouse's built-in keychain profile granted the same. That half could **not** be re-verified here:
  safehouse is uninstalled and its tap is no longer trusted by Homebrew, so treat the safehouse
  comparison as unconfirmed.)
- **The real defence is not the file boundary.** Keychain items are encrypted and access goes through
  `securityd`'s per-item ACL, so file-level *read* does not by itself yield entries. Write access is a
  destructive capability regardless, so this is a genuine residual, not a non-issue.

**It narrows a claim made elsewhere in this document.** "Why granting `~/.config/gh` read is not a
contradiction" argues the exposure is small because the token lives in the macOS keyring rather than in
`hosts.yml`. That remains true of `hosts.yml`, but it must not be read as "the keyring is out of
reach" — the keyring *files* are read+write under this profile.

## Network baseline (`network_profile: "developer"`)

Re-verified against the grown profile. **HTTP(S) only** — see the `nono why` caveat above.

**ALLOWED:** `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`,
`api.anthropic.com`, `registry.npmjs.org`, `pypi.org`, `proxy.golang.org`, `mcp.deepwiki.com`,
`chatgpt.com`

**DENIED:** `statsig.anthropic.com`, `pastebin.com`, `webhook.site`, `requestbin.net`, `transfer.sh`,
`0x0.st`, `169.254.169.254`

The preset is genuinely default-deny and narrow: the common exfiltration destinations and the cloud
metadata endpoint are all blocked.

## Detail on the rows that passed quietly

**Row 3 — `gh`: PASS.** With `$XDG_CONFIG_HOME/gh` and the `device-id` file in the profile and **no
ad-hoc flags**, `gh auth status` exits 0 and reports the keyring as its credential source, and
`gh issue list --limit 3` exits 0 returning real issues. Before the grant, gh could not start at all
(`failed to create root command: failed to read configuration`), and granting only `config.yml` merely
moved the failure to `hosts.yml`.

**Row 4 — `make lint`: exit 0, zero network denials, zero path denials.** The richest single probe.
All targets ran: secretlint (silent on success), shellcheck, shfmt, oxlint, oxfmt, actionlint, zizmor,
the `modify_` smoke tests, the script and harness-script tests, `check-templates`, `scan-sensitive`,
and `test-nono-profile`. pnpm dependency resolution worked. Note `zizmor` self-reports running in
offline mode and skipping its token-requiring audits — that is its default, not a nono denial.

**Row 5 — chezmoi: PASS.** With everything carried by the profile and no ad-hoc flags,
`chezmoi diff --source "$(pwd)"` exits 0 (1989 lines of diff, no denials) and
`chezmoi apply --dry-run --source "$(pwd)"` exits 0 with no output. Denials were originally enumerated
iteratively — `~/.bash_profile` (deny group), then `.config/cco`, `.config/cmux`, `.config/gh` — with
`.config/safehouse` and `.gitignore` observed separately via scoped diffs rather than inferred.
`.local` and `.chezmoiscripts` produced no denial and were **not** granted. The TTY prompt on
`.claude/settings.json` that the plan expected did **not** reproduce.

**Row 7 — deepwiki: PASS.** A real end-to-end MCP connection, better evidence than a synthetic HTTP
client would be: `MCP server "deepwiki": Successfully connected (transport: http) in 878ms`.

**Row 10 — hooks and statusline: PASS.** `harness-briefing.sh` (exit 0, 95 bytes),
`harness-doctor.sh` (exit 0, 475 bytes), `harness-reflect-trigger.sh` (exit 0), `notify-wrapper.sh`
(exit 0). The statusline runs under `node --experimental-strip-types` (v24.13.1) and its output inside
nono is byte-identical to its output outside nono, including the git branch and diff stats. The `N/A`
usage bars appear in both, so they are a pre-existing baseline rather than a sandbox effect.

**Row 11 — plugin loading: PASS.** Seven plugins loaded with no failures — `ecc` (278 skills),
`compound-engineering` (32), `superpowers` (14), `sentry` (10), and one each from
`claude-md-management`, `skill-creator`, and the pack's own `nono` plugin.

## Not verified in this pass

| # | Item | Why | What would close it |
|---|------|-----|---------------------|
| 8 | gstack `/browse` (Chromium launch) — **the priority gap; it bounds the egress guarantee, not just a feature** | In-session tool behaviour. Needs a live interactive Claude Code session; cannot be driven from one-shot commands | Run `/browse` inside `nono run --profile claude-seal -- claude --settings '{"sandbox":{"enabled":false}}'`, confirm Chromium launches, and record which sites 403. **Also record whether Chromium runs *inside* nono (traffic proxied, bounded by `allow_domain`) or attaches to a browser daemon *outside* it over a localhost CDP port — the latter is a relay that bypasses the allowlist entirely, per the `open_port: [0]` provenance note above.** `CLAUDE.md` mandates `/browse` for *all* web browsing and `$HOME/.gstack` is granted read+write, so this decides whether web fetches are allowlist-bounded at all |
| 9 | WebFetch / WebSearch | Same — these are in-session tools, not CLI entry points | Exercise both in an interactive session; WebSearch is expected to work via `api.anthropic.com`, WebFetch will be bounded by `allow_domain` |
| 2 | `git push` (any transport) | Out of scope by instruction; never attempted | Push from a throwaway clone. Everything it depends on — the HTTPS rewrite, the `gh` credential helper, and object/ref writes — is verified, so this is expected to work |
| — | `CLAUDE_CONFIG_DIR` as a fix for the `.claude.json.tmp` gap | Untested hypothesis; testing it mutates config state | Set it in `environment.set_vars` and confirm the atomic-write EPERM disappears |
