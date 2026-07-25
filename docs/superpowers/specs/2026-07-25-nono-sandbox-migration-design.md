# Sandbox Migration to nono — Design

> **Historical record — partly superseded. Do not use as the current authority.**
> This document captures the design as approved *before* implementation. The observation phase
> disproved three of its claims: (1) "there is no host wildcard on the allow side" is **false** —
> `network.allow_domain` accepts `*.host` with strict-subdomain semantics; (2) the 1Password recipe of
> `filesystem.bypass_protection` + `filesystem.read_file` on the agent socket is **superseded** — macOS
> Seatbelt treats socket `connect(2)` as network, so the shipped profile uses `filesystem.unix_socket`
> and that pair was verified redundant and removed; (3) the Sentry workaround here rests on the false
> wildcard premise and is therefore moot. Its egress claim is also overstated in the same way `CLAUDE.md`'s
> was: `open_port: [0]`, which this document seeds, means `localhost:*` on macOS, so "every other outbound
> TCP is blocked" holds only for *remote* addresses — a listener outside the sandbox can relay around the
> allowlist. The body below is left unedited as a record of its moment.
> Current authority: `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md`
> and the sandbox sections of `CLAUDE.md`.

**Date:** 2026-07-25
**Status:** Approved (pending user review of this document)

## Context

Claude Code is currently isolated by three overlapping mechanisms:

1. **safehouse** (`dot_config/safehouse/config.tmpl`) — the primary macOS Seatbelt sandbox,
   configured as a flat list of CLI flags. The `claude()` wrapper in
   `dot_config/zsh/sandbox.zsh` reads the file line by line and filters out `--add-dirs`
   entries whose path does not exist, because safehouse does not expand `$HOME` or tolerate
   missing paths.
2. **cco** (`dot_config/cco/allow-paths.tmpl`) — a fallback pulled through
   `.chezmoiexternal.toml` and symlinked by `run_onchange_after_link-cco.sh.tmpl`.
3. **Claude Code's native Bash sandbox** (`dot_claude/settings.json.tmpl`) — enabled, but
   meaningfully active only under `command claude`. Under the wrapped `claude` path it hits a
   nested `sandbox_apply` EPERM (macOS denies nested Seatbelt) and `failIfUnavailable: false`
   degrades it to unsandboxed Bash.

Three configuration surfaces express one policy, and the strongest control the setup needs —
restricting *where the agent may send data* — is only weakly available. The native sandbox's
`network.allowedDomains` prompts on first use for unlisted domains, which is a click-through,
not a boundary. safehouse has no domain filtering at all.

[nono](https://github.com/nolabs-ai/nono) (v0.68.0, homebrew-core, Apache-2.0, built by the
Sigstore team) replaces all three with a single composable JSON profile and adds
kernel-enforced egress control: when a network profile or domain allowlist is active, the
sandboxed child can reach only `localhost:<proxy-port>` and every other outbound TCP is
blocked at the kernel level. The proxy resolves DNS itself and checks resolved IPs against a
deny list (DNS-rebinding protection), and cloud metadata endpoints are denied
unconditionally.

## Requirements

- **Hard requirement:** block data transmission to networks whose trustworthiness is not
  established.
- Balance safety against day-to-day friction; the existing Claude Code configuration
  (permissions, hooks, plugins, MCP servers) must keep working.
- **Added during brainstorming:** require human approval before package/module installation.
- **Added during brainstorming:** keep a usable path for Claude Code's native Bash sandbox.

## Decisions (settled during brainstorming)

1. **nono is the single sandbox layer.** safehouse and cco are removed. Claude Code's native
   sandbox is disabled *on the nono path only* (see decision 6), per nono's documented
   recommendation to avoid nested boundaries that make denials hard to diagnose.
2. **Network posture: generous enumeration, grown on miss.** The allowlist is an explicit
   enumeration; a miss fails with `403` and the pack's hook tells Claude the denial is a nono
   boundary. The human then decides whether to add the host and commit it, so the allowlist
   doubles as a reviewed history of granted destinations.
3. **The official pack `nolabs-ai/claude` provides the base profile**, and a
   chezmoi-managed profile `extends` it.
4. **V1 is a straight translation.** `command_policies` (nono's per-tool child sandboxes with
   credential proxying) is deferred to a follow-up issue.
5. **An observation phase precedes cutover.** safehouse stays the live `claude` path while the
   allowlist is grown by hand; safehouse removal happens in the same PR after verification.
6. **The native sandbox is disabled inside nono rather than removed from settings.**
   `settings.json.tmpl` keeps `sandbox.enabled: true`; the nono wrapper passes
   `--settings '{"sandbox":{"enabled":false}}'`. `command claude` therefore remains the escape
   hatch and runs with the native sandbox active.

### Why the allowlist is the only real control

Two findings constrain the network design and were verified against nono's source and docs:

- **There is no host wildcard on the allow side.** `allow_domain` accepts a plain hostname or
  a URL with a path glob (`https://github.com/org/**`). Only `deny_domain` accepts `*.host`
  patterns. So "allow anything" cannot be expressed as a policy, and every trusted destination
  must be named.
- **L7 method filtering is not an exfiltration control.** `allow_domain` entries can carry
  `endpoints` rules that TLS-intercept and restrict method+path. This is useful for scoping an
  API, but it does not stop data from leaving: a `GET` can carry payload in the path or query
  string. "Read-only egress" is not a thing nono (or anything else at this layer) can offer.

Therefore the enumerated allowlist *is* the mechanism, and the design question is only how
misses are handled — which decision 2 answers.

## Architecture

```
Before:  claude() → safehouse (Seatbelt; config = list of CLI flags)
                  → cco (fallback; allow-paths)
         + Claude Code native sandbox (settings.json; effective only under `command claude`)

After:   claude() → nono run --profile claude-seal -- claude \
                      --settings '{"sandbox":{"enabled":false}}' \
                      --dangerously-skip-permissions
         command claude / \claude → native Bash sandbox, unchanged
```

One boundary, one policy file, plus a deliberate second path that reuses the native sandbox
configuration already tuned in this repository.

### Deliverables

| Added | Contents |
|---|---|
| `dot_config/nono/profiles/claude-seal.json` | The profile. Plain JSON, **not** a chezmoi template |
| `dot_config/nono/packs.txt` | Declarative pack list (`nolabs-ai/claude`), mirroring `marketplaces.txt` |
| `.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl` | Runs `nono pull` when the `packs.txt` hash changes |
| `Makefile: test-nono-profile` | `nono profile validate`, wired into `make lint` |

| Removed | Reason |
|---|---|
| `dot_config/safehouse/config.tmpl` | Superseded |
| `dot_config/cco/allow-paths.tmpl` | nono covers Linux (Landlock); no fallback needed |
| `.chezmoiexternal.toml` entry `.local/share/cco` | Same. One fewer Renovate-tracked external |
| `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl` | Same |
| `darwin/Brewfile: tap "eugene1g/safehouse"` | Replaced by `brew "nono"` (homebrew-core, no tap) |

The profile does not need to be a template: nono expands `$HOME`, `$XDG_CONFIG_HOME`,
`$WORKDIR`, `$TMPDIR`, `$NONO_CONFIG`, and `$NONO_PACKAGES` itself. Keeping it as plain JSON
means `make oxfmt` validates its syntax and `nono profile validate` can check it semantically.

**Incidental finding, fixed by this migration:** `darwin/Brewfile` contains
`tap "eugene1g/safehouse"` but **no `brew "safehouse"` line**. A fresh machine gets the tap and
not the binary, so `sandbox.zsh` silently falls through to the cco path. Adding `brew "nono"`
closes that gap because nono is a plain formula.

## The profile

`dot_config/nono/profiles/claude-seal.json` → `~/.config/nono/profiles/claude-seal.json`.

The name must differ from `claude-code`: a user profile shadows a pack profile of the same
name, which would silently discard the base.

```jsonc
{
  "meta": { "name": "claude-seal", "version": "1.0.0" },
  "extends": "claude-code",
  "workdir": { "access": "readwrite" },

  "groups": { "include": [ /* git_config, mise_manager, homebrew_macos,
                              node_runtime, go_runtime, rust_runtime,
                              python_runtime, bun_runtime, user_tools,
                              user_caches_macos, codex_macos */ ] },

  "filesystem": {
    "allow": ["$HOME/ghq", "$HOME/.cache", "$HOME/.codex", "$HOME/.gstack"],
    "read":  ["$HOME/.local/bin",
              "$XDG_CONFIG_HOME/chezmoi", "$HOME/.local/share/chezmoi",
              "$HOME/Library/Caches/ms-playwright"
              /* plus the $HOME-root dotfiles and .config/* subdirs that
                 `chezmoi diff` compares against */],
    "bypass_protection": ["$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"],
    "read_file":         ["$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"]
  },

  "network": {
    "network_profile": "developer",
    "allow_domain": [ /* seed list below */ ],
    "open_port": [0]
  },

  "environment": { "set_vars": { "INSIDE_NONO_SANDBOX": "1" } }
}
```

### 1Password signing socket

nono's built-in `deny_credentials` group denies the 1Password container paths by default.
`bypass_protection` removes the deny rule but **does not grant access** — the path must also
appear in a grant field, hence the paired `read_file`. nono can attach capabilities to a Unix
socket directly, so only the socket is exposed, not the container directory.

This matters beyond signing: on the nono path there is no `excludedCommands` concept, so
`git`, `gh`, and `docker` all run *inside* the boundary. Today `git commit` and `git push` are
listed in `excludedCommands` and run **fully unsandboxed**, which means repository-controlled
hooks and SSH transports execute outside any boundary and `push` bypasses the domain
allowlist. Moving to nono recovers all of that without editing `excludedCommands` at all,
because that list only governs the native-sandbox path (decision 6).

### Domain allowlist seed

The `developer` network profile supplies `llm_apis`, `package_registries`, `github`, `gitlab`,
`sigstore`, and `documentation`. Known gaps to add explicitly:

| Domain | Purpose |
|---|---|
| `formulae.brew.sh` | Homebrew API (bottles come from `ghcr.io`, already in `github`) |
| `proxy.golang.org`, `sum.golang.org` | Go module proxy — **absent from `developer`**; `go get` / `go mod` fail without it |
| `mcp.deepwiki.com` | deepwiki MCP server |
| `chatgpt.com`, `auth.openai.com` | codex MCP via ChatGPT auth |
| `mise.jdx.dev` | mise tool downloads |
| `registry.nono.sh` | nono pack pull |
| `cdn.playwright.dev`, `storage.googleapis.com` | Chromium download for gstack `/browse` |
| `code.claude.com`, `docs.anthropic.com` | documentation lookups |

This list is assumed incomplete and is grown during the observation phase. Two known risks:

- **Sentry plugin** — endpoints are `*.ingest.sentry.io`. With no allow-side wildcard, the
  choice is to enumerate the specific org hostname or to leave it blocked.
- **`statsig.anthropic.com`** (Claude Code telemetry) — expected to fail harmlessly if
  blocked; confirm during observation.

## Claude Code settings changes

### Native sandbox: disabled inside nono, not removed

`--settings <file-or-json>` accepts a JSON string and loads it as an additional settings
layer. The nono wrapper uses it to turn the native sandbox off for that invocation only.

Consequences, all of which reduce churn:

- The escape hatch needs no new file and no new shell function. `command claude` *is* the
  native-sandbox path, and the bypass instructions already documented in CLAUDE.md keep their
  meaning.
- The tuned `allowWrite`, `denyRead`, `allowRead`, and `excludedCommands` blocks are kept
  verbatim. They remain the correct configuration for the native-sandbox path, including the
  `git commit` / `git push` exclusion that works around the native Seatbelt profile blocking
  the 1Password agent socket.
- The failure mode is graceful. If `--settings` does not override the base file's
  `enabled: true`, the inner sandbox nests, EPERMs, and `failIfUnavailable: false` degrades it
  — i.e. today's behavior. Nothing breaks.

**Verification item:** confirm that `--settings '{"sandbox":{"enabled":false}}'` actually
overrides `~/.claude/settings.json`, via `claude --debug` or `/doctor`.

### Human approval before package installation

`Bash(npm:*)`, `Bash(pnpm:*)`, `Bash(mise:*)`, and `Bash(go get:*)` are currently in
`permissions.allow`, so installs are auto-approved today. Install commands move to
`permissions.ask`. Since precedence is `deny > ask > allow`, the broad `allow` entries can stay
and the narrower `ask` entries win. `ask` fires even under `bypassPermissions`, so the gate
holds on the `--dangerously-skip-permissions` path the wrapper uses.

**Commands that pull in new code:**
`npm install|i|ci|add|update`, `pnpm install|add|update`, `yarn add|install`,
`bun add|install`, `pip install`, `pip3 install`, `uv add`, `uv pip install`,
`go get`, `go install`, `cargo add`, `cargo install`, `gem install`,
`brew install|tap|bundle`, `mise install|use|plugin`, `gh extension install`,
`claude plugin install`, `claude plugin marketplace add`, `nono pull|update`.

**Commands that execute remote code without installing:**
`npx`, `pnpm dlx`, `yarn dlx`, `bunx`, `uvx`.

`curl` and `wget` are already in `deny`, which closes `curl … | sh`.

**Lockfile restore is gated too.** Splitting into "new dependencies require approval,
lockfile restore does not" looks like the balanced choice, but it is an illusory boundary: an
agent can edit `package.json` and then run bare `pnpm install` to walk straight through it.

The friction is smaller than it appears, and for a reason worth recording: **Claude Code
permissions match the Bash string the agent issues, not its subprocesses.** This repository's
common path is `make lint` / `make test-*`, and `Bash(make:*)` stays in `allow`, so `make`-
invoked package operations are not prompted. That is also a hole — but `make` targets are
version-controlled and reviewable, which is an acceptable line. `gh api` likewise remains
auto-approved (its read/write intent lives in `--method`, not a prefix), unchanged from today.

### Other settings changes

Add nono's read-only diagnostic commands to `permissions.allow`, as the pack's hook invokes
them and would otherwise prompt every session:
`Bash(nono why:*)`, `Bash(nono profile guide)`, `Bash(nono profile validate:*)`,
`Bash(nono profile show:*)`.

Add the pack's plugin key to `enabledPlugins`. The pack writes this key into
`~/.claude/settings.json` at install time, and chezmoi fully owns `settings.json.tmpl`, so
without reflecting it the key is wiped on the next `chezmoi apply` and the plugin silently
stops loading — the same failure shape as #228 and as the marketplace-rename pitfall already
recorded in CLAUDE.md. The exact key is determined at implementation time by pulling the pack
and reading `~/.claude/plugins/installed_plugins.json`, because the README's namespace
migration (`always-further` → `nolabs-ai`) and the client documentation disagree.

### `.chezmoiignore`

- Add `.config/nono/packages` — the nono-managed pack store.
- Add `.config/nono/packs.txt` — source-tree only, consumed via `include` for hash tracking.
  A bare `*.txt` entry does not match nested paths, so an explicit entry is required, exactly
  as for `.config/gh/extensions.txt`.
- Do **not** ignore `.config/nono/profiles/` — the profile must deploy.

## codex

The `codex()` wrapper currently detects an outer sandbox via `$APP_SANDBOX_CONTAINER_ID`, a
safehouse/Seatbelt artifact that nono does not set. Left as-is, detection fails, codex nests
its own Seatbelt inside nono, and the call EPERMs — the failure already recorded in
`docs/solutions/integration-issues/codex-nested-seatbelt-sandbox-bypass.md`.

- Switch detection to `$INSIDE_NONO_SANDBOX`, injected by the profile's
  `environment.set_vars`. During the migration the condition checks both variables; the
  safehouse one is dropped at cutover.
- Change the flags from `--dangerously-bypass-approvals-and-sandbox` to
  `--sandbox danger-full-access --ask-for-approval on-request`, nono's documented
  recommendation. This is strictly safer than today: it drops the nested sandbox without also
  discarding codex's approval flow.
- **`mcp-servers.json`'s codex entry is spawned as an MCP stdio server via direct exec and does
  not pass through the zsh function.** Confirm during observation whether nesting actually
  breaks it. If it does, either add `--sandbox danger-full-access` to `args` (verify
  `mcp-server` accepts the flag) or introduce a shim script. If it does not, change nothing.

## Verification

The `claude` function stays on safehouse during the observation phase; nono is exercised by
invoking it explicitly, so day-to-day work is never blocked by an incomplete allowlist.

```sh
nono run --profile claude-seal -vv -- claude \
  --settings '{"sandbox":{"enabled":false}}' --dangerously-skip-permissions
```

`-vv` prints `ALLOW CONNECT <host>` and `DENY CONNECT <host> reason=<r>` for every proxy
decision; the allowlist is grown from the denials. Filesystem denials are diagnosed with
`nono why --path <p> --op read`.

| # | Item | What to confirm |
|---|---|---|
| 1 | `git commit` (1Password signing) | **Highest risk.** That `bypass_protection` + socket `read_file` work, and that `/Applications/1Password.app/Contents/MacOS/op-ssh-sign` is executable (whether `system_read_macos` covers `/Applications` is unverified) |
| 2 | `git push` / `git fetch` | Whether SSH transport works under the proxy. `allow_domain` is an HTTP(S) proxy allowlist, **not** raw TCP, so SSH may be blocked; fallback options are an HTTPS remote or `open_port` |
| 3 | `gh pr view` / `gh issue list` | Keychain auth readable |
| 4 | `make lint` | secretlint / oxlint / actionlint / zizmor plus pnpm dependency resolution |
| 5 | `chezmoi diff`, `chezmoi apply --dry-run` | Coverage of `$HOME`-root dotfiles and `.config/*` read grants |
| 6 | MCP: codex | ChatGPT backend reachable; whether nested Seatbelt actually breaks |
| 7 | MCP: deepwiki | `mcp.deepwiki.com` reachable |
| 8 | gstack `/browse` | Chromium launches; `open_port: [0]` sufficient; measure which sites 403 |
| 9 | WebFetch / WebSearch | How far each is constrained (WebSearch is expected to work, routing via `api.anthropic.com`) |
| 10 | Claude Code hooks | `harness-briefing.sh`, `notify-wrapper.sh`, the secretlint hook, and the `node --experimental-strip-types` statusline |
| 11 | Plugin loading | Marketplace updates (covered by `github`) and the pack plugin active |
| 12 | `--settings` precedence | The native sandbox is genuinely disabled inside nono |

Only item 12's mechanism and profile validity are automatable. `make test-nono-profile` runs
`nono profile validate` behind a `command -v nono || exit 0` guard (per
`.claude/rules/shell-scripts.md`) and is wired into `make lint`. CI does not install nono, so
JSON syntax is covered by the existing `make oxfmt` and semantic validation is local-only —
recorded as a known gap and deferred to a follow-up issue. The checklist above is a manual
procedure and lives in this document.

## Commit sequence (single PR)

1. **Add nono.** `brew "nono"`, the profile, `packs.txt`, the `run_onchange_` script,
   `.chezmoiignore` entries, and the `settings.json.tmpl` changes (install gates, nono
   diagnostic allows, `enabledPlugins`). `sandbox.zsh` is untouched, so `claude` still runs
   through safehouse and daily work is unaffected.
2. **Observation-phase commits.** Incremental profile growth.
3. **Cutover.** Switch `sandbox.zsh` to nono, move `codex()` detection to
   `$INSIDE_NONO_SANDBOX`, and remove safehouse/cco (Brewfile tap, `.chezmoiexternal.toml`
   entry, `link-cco` script, both config templates).
4. **Documentation.** Rewrite CLAUDE.md and open the follow-up issues.

`run_onchange_after_pull-nono-packs.sh.tmpl` must set `NONO_AUTO_MIGRATE=1`: in a non-TTY
context nono otherwise behaves as if `NONO_NO_MIGRATE=1` and exits without pulling.

## Documentation changes

**CLAUDE.md** — restructure the current "Claude Code sandbox" (safehouse/cco) and "Native Bash
sandbox (migration target)" paragraphs into:

- **Sandbox (nono)** — the primary layer: profile location, declarative pack sync, the
  1Password socket grant, and how to grow the allowlist.
- **Native Bash sandbox (escape hatch)** — keep the existing paragraph and add that the nono
  path disables it via `--settings` and that `command claude` is this path. The
  `excludedCommands` list and the 1Password workaround keep their rationale as native-path
  documentation.
- The git/gh write-governance paragraph is unchanged; add a paragraph on the package-install
  gate, including its holes (`make` subprocesses are not matched; `gh api` stays
  auto-approved).

**Known Pitfalls** — add:

- `allow_domain` has no host wildcard; only `deny_domain` accepts `*.host`.
- `bypass_protection` removes a deny rule but grants nothing — it must be paired with
  `read`/`allow` (or a `*_file` variant).
- nono profiles expand `$HOME` / `$XDG_CONFIG_HOME` themselves, so the profile must **not** be
  a chezmoi template.
- The pack writes `enabledPlugins` into `~/.claude/settings.json`; the key must be reflected
  into `settings.json.tmpl` or `chezmoi apply` silently disables the plugin.

## Follow-up issues

1. **Tool sandboxing via `command_policies`.** Put `gh` behind the credential proxy with
   kernel-enforced method+path endpoint policy, and give `git` its own narrow child policy.
   Requires reworking `gh` auth from keychain to a `GITHUB_TOKEN` route.
2. **`environment.allow_vars`.** The sandbox currently inherits the parent's entire
   environment, so API keys exported in the shell pass straight through.
3. **CI semantic validation of the profile**, and a decision on Sentry's
   `*.ingest.sentry.io` (enumerate the real hostname or leave it blocked).

## Out of scope

- Windows/WSL2. nono's domain filtering does not work on WSL2 (Landlock V3 lacks TCP
  filtering); only `--block-net` does. This repository targets macOS.
- Sandboxing agents other than Claude Code and codex.
- Changing the `--dangerously-skip-permissions` posture of the wrapper. The rationale — the
  outer sandbox is the real boundary, and `deny`/`ask` still fire — is unchanged by this
  migration.
