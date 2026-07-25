# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A chezmoi-managed dotfiles repository for macOS. Source directory is `~/.local/share/chezmoi/`, targeting `~/` as the destination. Managed configs include shell (zsh, starship, sheldon), editor (vim, helix), terminal (ghostty, tmux, zellij), git, Claude Code (`~/.claude/`), dev tools (mise, gh, yazi), and macOS packages (Brewfile).

## Common Commands

```sh
chezmoi apply                  # Apply all dotfiles to ~/
chezmoi apply --dry-run        # Preview what would change
chezmoi diff                   # Show diff between source and destination
chezmoi add <file>             # Add a file to chezmoi management
chezmoi edit <file>            # Edit a managed file's source
chezmoi managed                # List all managed files
chezmoi data                   # Show template data (profile, ghOrg, etc.)

# Linting (mirrors CI — also runs on commit via prek)
make lint                      # Run all checks (secretlint + shellcheck + shfmt + oxlint + oxfmt + actionlint + zizmor + modify_ + script tests + templates + sensitive scan + nono profile)
pnpm exec secretlint '**/*'   # Scan for leaked secrets only

# Security alerts (scheduled weekly in CI, also manual)
gh workflow run security-alerts.yml  # Trigger security alert sweep manually

# Harness self-improvement loop (local, PR-gated)
/harness-reflect                     # Extract session learnings into ~/.claude/harness/queue.md
/harness-review                      # Health check + queue triage -> one PR (7-day cadence)
bash ~/.claude/scripts/harness-doctor.sh  # Deterministic liveness check
```

## chezmoi Naming Conventions

Source files use chezmoi's naming scheme — understand these prefixes when working here:

| Prefix | Meaning |
|--------|---------|
| `dot_` | File starts with `.` in target (e.g., `dot_zshrc` → `~/.zshrc`) |
| `private_` | Target has `0600`/`0700` permissions |
| `modify_` | Script that receives current target on stdin, outputs modified version |
| `run_onchange_` | Script runs when its tracked hash changes |
| `run_onchange_after_` | Combines `run_onchange_` (hash-triggered) + ordering after file targets |
| `.tmpl` suffix | Go template — rendered with `.chezmoi.homeDir`, `.profile`, `.ghOrg` |

## Architecture

### Template Variables

Defined in `.chezmoi.toml.tmpl`, prompted on first `chezmoi init`:
- `.profile` — `"work"` or `"personal"` (controls gitconfig work overrides)
- `.ghOrg` — GitHub org name (used in permissions and directory paths)
- `.chezmoi.homeDir` — Home directory path

### Key Patterns

**`modify_dot_claude.json`** — Partially manages `~/.claude.json` (a large runtime file). Uses `jq` to replace only the `mcpServers` key from `dot_claude/mcp-servers.json`, preserving all other runtime state. This is the correct pattern for files where chezmoi should own a subset of keys.

**`dot_config/karabiner/modify_karabiner.json`** — Partial management of `~/.config/karabiner/karabiner.json`, mirroring the `modify_dot_claude.json` pattern. Owns `profiles[*].complex_modifications.rules` only; preserves Karabiner's runtime state (`machine_specific` UUID, profile metadata, `virtual_hid_keyboard`, sibling `complex_modifications.parameters`, etc.) verbatim. The rules array lives at `dot_config/karabiner/complex_modifications.json` and is applied to *every* profile (V1 deliberately ignores per-profile rule divergence). Empty stdin (new-machine bootstrap before Karabiner has been launched) seeds a minimal profile shape with no fabricated `machine_specific`. First apply normalizes the file mode from Karabiner's `0600` to `0644`; Karabiner restores `0600` on next save. Smoke-tested by `make test-modify`.

**Declarative marketplace sync** — `dot_claude/plugins/marketplaces.txt` lists marketplace sources (one per line: `owner/repo` or URL). `run_onchange_after_add-marketplaces.sh.tmpl` tracks the file hash and runs `claude plugin marketplace add` for each entry when it changes. To add a new marketplace: register it locally with `claude plugin marketplace add`, run `scripts/update-marketplaces.sh` to regenerate the list, then commit and push. To remove: run `claude plugin marketplace remove` manually on each machine — removing a line from `marketplaces.txt` does not unregister the marketplace. Plugin install/enable state (`installed_plugins.json`, `known_marketplaces.json`) is not managed by chezmoi — these files are in `.chezmoiignore`.

**Declarative gh extension sync** — `dot_config/gh/extensions.txt` lists gh extensions (one `owner/repo` per line). `run_onchange_after_install-gh-extensions.sh.tmpl` installs them when the list changes. `scripts/update-gh-extensions.sh` regenerates the list from `gh extension list`. Same pattern as marketplace sync. Note: `gh extension list` is tab-delimited — use `awk -F'\t'` to parse.

**`run_onchange_` scripts** — Track file hashes in comments (e.g., `# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}`). They re-run only when the tracked content changes.

**Claude Code sandbox (nono)** — The `claude` shell command is wrapped by `dot_config/zsh/sandbox.zsh` to run inside [nono](https://github.com/nolabs-ai/nono) (Homebrew, macOS Seatbelt / Linux Landlock, deny-all default). Policy lives in one file: `dot_config/nono/profiles/claude-seal.json`, which `extends` the `claude-code` base profile from the official pack `nolabs-ai/claude`. The pack is synced declaratively via `dot_config/nono/packs.txt` + `.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl` (same pattern as marketplace and gh-extension sync; removal requires `nono remove` on each machine). The profile is **plain JSON, not a template** — nono expands `$HOME` / `$XDG_CONFIG_HOME` itself — so `make oxfmt` checks its syntax and `make test-nono-profile` checks it semantically. The wrapper passes **three** flags: `--allow-cwd` (the profile's `workdir.access` sets the access *level*, not the grant), `--settings '{"sandbox":{"enabled":false}}'` (see the escape-hatch block below — load-bearing, not cosmetic), and `--dangerously-skip-permissions`. Use `command claude` or `\claude` to bypass nono; that path runs under Claude Code's native Bash sandbox instead.

**What `--dangerously-skip-permissions` does to the governance blocks below.** The nono session runs in bypass mode, so the *only* surviving permission gates are `permissions.deny` rules and explicit `permissions.ask` rules — everything else is auto-approved with no prompt. The git / gh / package-install governance paragraphs further down are therefore **not** vacuous, for two reasons established by reading Claude Code 2.1.220's permission-resolution path (re-check if that behaviour ever changes): an `ask` match early-returns *before* the bypass-mode short-circuit, so `ask` rules fire even under `bypassPermissions`; and `--settings` **merges** rather than replaces (flag settings are one source in the precedence chain), so the `permissions` block in `settings.json.tmpl` stays in force. Read those paragraphs as describing exactly `deny` + explicit `ask`, and nothing beyond that.

**`gh api` under this posture — re-examined after egress became a hard requirement, and deliberately kept.** `api.github.com` is reachable — not via the profile's `network.allow_domain` list (it is not one of the 12 entries there), but via the `developer` network preset's baseline, which the next block explains supplies a wider reachable set than `allow_domain` alone. `gh api` is deliberately unlisted in `permissions` (see the escape-hatch block for why: `--method` can appear anywhere in the argument list, so no prefix rule separates writes from reads), and the wrapper passes `--dangerously-skip-permissions`. Concrete consequence: `gh api --method POST /gists` is an authenticated, unprompted, arbitrary-payload upload to an allowlisted domain — not gated, even though `gh gist create` is. `Bash(python3:*)` is in `allow`, so the *network path* to `api.github.com` is reachable without `gh` at all (authenticating it would additionally need a token — `gh auth token` is itself unlisted and therefore ungated); `curl` / `wget` are in `deny`, so that route is closed. The acceptance was originally inherited from a permissions-only context; it was re-put to the human after egress control became the hard requirement and **maintained as-is**, because `Bash(gh api:*)` would prompt on every read-only `gh api` as well, and that is a command agents use constantly for investigation. Argument-pattern gating is tracked in issue #225.

The reason to run nono rather than the native sandbox alone is **egress control**: with `network.network_profile` / `allow_domain` active, the sandboxed child cannot open a *direct* connection to a remote address at all — raw `network-outbound` is denied (verified: SSH fails with `Operation not permitted` on port 22 **and** on 443) — so its only sanctioned route off the machine is nono's local proxy, which blocks HTTP(S) to any host outside the reachable set at the kernel level. **The reachable set is not just the profile's `network.allow_domain` list** — it is that list **union** the `developer` network preset's baseline. Re-verified against the shipped profile (observations doc, "Network baseline" section), the preset's baseline alone allows at least `github.com`, `api.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `api.anthropic.com`, `registry.npmjs.org` and `pypi.org` — none of which are among the profile's 12 `allow_domain` entries. Read `allow_domain` as *extending* that baseline, not defining the whole boundary; check the observations doc when auditing exactly what is reachable. Read the localhost caveat in the next paragraph before treating either as a complete egress guarantee. Per nono's design the proxy resolves DNS itself and checks resolved IPs against a deny list (DNS-rebinding protection); cloud metadata endpoints are denied unconditionally, and `169.254.169.254` plus the common exfiltration hosts (`pastebin.com`, `webhook.site`, `transfer.sh`, …) were verified DENIED under the shipped profile. The native sandbox's `allowedDomains` only *prompts* for unlisted domains, which is a click-through, not a boundary.

**The egress guarantee stops at localhost, because of `open_port: [0]`.** Do **not** read the paragraph above as "all non-allowlisted outbound traffic is impossible". On macOS `open_port: [0]` means `localhost:*` — *every* localhost port — and `open_port` is documented as connect **+ bind** (`nono profile guide`, the `open_port` row: "Localhost TCP IPC (connect + bind) … Port **0**: macOS only (`localhost:*` outbound)"). nono's own startup banner prints `ipc  localhost:0`. So a process inside the sandbox can connect to any listener running *outside* it, and any such listener is a relay that bypasses `allow_domain` entirely. This is not theoretical: a listener started outside nono received the bytes `EXFIL-PROBE` from a process inside nono over `127.0.0.1` during review. **This is what makes observations row 8 (gstack `/browse`, UNVERIFIED) an egress-guarantee gap and not merely a functional one:** this file instructs that `/browse` be used for *all* web browsing, `$HOME/.gstack` is granted read+write, and a Chromium CDP endpoint is a localhost port — so whether browsing is proxied (Chromium launched *inside* nono) or relayed (attaching to a browser daemon *outside* nono) decides whether `allow_domain` bounds web fetches at all. Nobody has checked which it is. `open_port: [0]` also stands apart from the rest of `network` **in kind**: every `allow_domain` entry names one destination with a recorded purpose that can be reviewed on its own, whereas `open_port: [0]` grants a whole class of local connectivity whose only recorded justification is parity with the native sandbox's `network.allowLocalBinding: true`. Whether `open_port` is itself what authorizes nono's own HTTP(S) proxy hop (the proxy is itself a localhost listener) was tested, not just left unprobed: a copy of the profile was deployed with `network.open_port` deleted entirely, and `git ls-remote origin HEAD` still succeeded inside nono — so nono grants the proxy hop independently of `open_port`. That test covered one command exercising the proxy hop, not every workflow this pass verified. Provenance and the exact command/output are in the observations doc's grant-provenance section. Ruling: **not narrowed in V1** — but the candidate is now **removal**, not merely narrowing via `open_port_range`, once row 8 is settled: removing `open_port` would close the localhost relay channel entirely, and row 8 (gstack `/browse`, still UNVERIFIED) is the one plausible localhost consumer — a Chromium CDP endpoint is itself a localhost port — so removing it now, before row 8 is checked, could break browsing.

**Growing the allowlist** — a miss fails with `403`; the pack's `PostToolUseFailure` hook tells Claude the denial is a nono boundary and to run `nono why`. Decide whether the destination is one you trust with your data, then add it to `network.allow_domain` and commit — the allowlist doubles as a reviewed history of granted destinations. `allow_domain` accepts a plain hostname, a URL with a path glob (`https://github.com/org/**`), **and** a host wildcard (`*.ingest.sentry.io`), with strict-subdomain semantics: the wildcard matches `abc123.ingest.sentry.io` but not the bare apex `ingest.sentry.io`, and there is no suffix confusion (`ingest.sentry.io.attacker.com` stays DENIED). Do not reach for L7 `endpoints` rules as an exfiltration control: they restrict method+path but a `GET` can carry payload in the query string.

**1Password signing, and git/gh inside the boundary** — nono has no `excludedCommands` concept, so `git`, `gh` and `docker` all run **inside** the boundary. Four consequences, each traced to an observed denial:

- **Commit signing.** nono's required `deny_credentials` group blocks the 1Password container, and a filesystem read grant does not authorize the socket: on macOS, Seatbelt treats `connect(2)` on a Unix socket as a *network* operation. The profile therefore uses `filesystem.unix_socket` on the agent socket — that key **alone** is sufficient, and the `read_file` + `bypass_protection` pair that preceded it was verified redundant and removed. `op-ssh-sign` itself needs no grant: `/Applications` is already covered by the `system_read_macos` group.
- **git transport is HTTPS-only.** SSH cannot be made to work under nono on macOS — `--allow-connect-port` errors with `Seatbelt cannot filter by TCP port`, SSH over 443 is blocked as raw `network-outbound`, and `~/.ssh/config` is deny-listed on top. Only `--allow-net` would work, which would destroy the egress control that is the whole point. Instead `environment.set_vars` injects `GIT_CONFIG_*` **inside nono only**, rewriting `git@github.com:` → `https://github.com/` (`insteadOf`) and setting `credential.helper=!gh auth git-credential`; the user's global gitconfig and the repository's SSH remotes stay untouched, and egress control is preserved because the HTTPS traffic still traverses the proxy — reachable via the `developer` preset's baseline, since `github.com` is preset-allowed rather than one of the profile's `allow_domain` entries (see the union note above). Two traps: `insteadOf` matches **scp-form remotes only**, so an `ssh://git@github.com/...` remote is *not* rewritten and fails as an unexplained port-22 `Operation not permitted`; and the `GIT_CONFIG_*` namespace is numerically indexed while nono's `set_vars` **wins** over the launching shell, so `GIT_CONFIG_COUNT=5` deliberately re-declares Claude Code's own `credential.interactive=false` and `credential.guiPrompt=false` (which the profile would otherwise shadow and silently drop, turning a clean auth failure into an interactive hang inside a sandbox) plus `core.fsmonitor=false` to silence fsmonitor denial noise. Any addition must keep the indices contiguous and `GIT_CONFIG_COUNT` in sync, or git silently ignores the tail.
- **Write-side git needed filesystem grants.** This repository is a git worktree whose object store lives at `~/.local/share/chezmoi/.git`, outside the `--allow-cwd` grant, so *every* write-side git operation (commit, fetch, pull, rebase, stash) failed during object write. The profile grants `filesystem.write` on `objects`/`refs`/`logs`/`worktrees` there, plus `write_file` on `packed-refs` and `packed-refs.lock` (a `write_file` grant does **not** cover the `.lock` sibling). `.git/config` and `.git/hooks` are deliberately **not** writable.
- **`gh` needs its own config** — `$XDG_CONFIG_HOME/gh` read plus `$HOME/.local/state/gh/device-id`. This does **not** contradict `sandbox.filesystem.denyRead: ~/.config/gh` in `settings.json.tmpl`: that key governs the `command claude` path, where `gh *` is in `excludedCommands` and runs outside the boundary anyway. Two coherent policies for two different boundaries. The grant exposes no secret *in `hosts.yml`* — the token lives in the macOS keyring and `hosts.yml` carries no token line — but note residual (3) below: the keyring files themselves are granted read+write by the pack, so this is not a claim of "no keychain exposure".

`chezmoi diff` / `apply --dry-run` additionally need read on the shell rc files chezmoi manages. Those are blocked by nono's required `deny_shell_configs` group, so the profile pairs `read_file` with `bypass_protection` for exactly four of them — defensible because all four are chezmoi-managed, so their content lives in this version-controlled repository and is scanned by `make lint`'s secretlint pass, which is precisely the "may embed secrets" premise the group assumes. Read only, per-file: the group still blocks `~/.profile`, `~/.zshenv`, `~/.zlogin`, `~/.bash_login`, `~/.env`, `~/.envrc`, `~/.config/fish`.

**Accepted security residuals** — documented, not mitigated; do not read the narrow git grant as a claim that escalation is prevented. (1) `filesystem.write` on `.git/worktrees` also grants write to that worktree's `commondir`, which can redirect git's common dir to an agent-writable location where the agent controls `config` / `hooks`. On the nono path that does **not** buy unsandboxed execution — git runs *inside* the boundary here, as the paragraph above says — the risk is **persistence**: the planted `core.hooksPath` / `core.sshCommand` stays in the repository and executes later, when a human runs git, or when the `command claude` path does (where `git commit` / `git push` sit in `excludedCommands` and run outside the native sandbox entirely). Same outcome as hook-planting, a different door and a delayed fuse. A narrow carve-out **does** exist and was deferred, not ruled impossible: `filesystem.deny` does **not** override `filesystem.write` (tested — the path stayed ALLOWED) and the per-file alternative is brittle enough that one missed `.lock` breaks git obscurely, but nono 0.69's `command_policies.commands.git` tool sandbox accepts the provider tokens `@git:common-dir` and `@git:config-files` in its `fs_write` list, and those tokens are documented to ignore repo-local and worktree git config "so a checkout cannot grant itself extra host filesystem access" — a mechanism built for this exact class of problem. V1 is a straight translation and defers all of `command_policies` (issue #235), so the residual stands for now. Accepted because the exposure is strictly dominated by what already exists: (2) `$HOME/ghq` is granted `allow` (read+write), so `.git/hooks` and `.git/config` *are* writable for every repository under it, and the files that define this sandbox — including `claude-seal.json` itself — live inside the writable working tree. (3) **The `claude-code` pack grants `$HOME/Library/Keychains` read+write.** The pack lists it in both `filesystem.allow` and `filesystem.bypass_protection`, so the required `deny_keychains_macos` group does not stop it; `login.keychain-db` is separately read+write via the pack's `claude_code_macos` group. Verified with `nono why` — read *and* write ALLOWED, on the directory and on `login.keychain-db`. It is **inherited and not removable**: nono appends array values on `extends` and `nono profile guide` states there is no mechanism to remove inherited filesystem paths (only `groups.exclude`, for groups), so short of abandoning `extends` it stays. Not introduced by this migration either — the native path's `filesystem.denyRead` (`~/.ssh`, `~/.aws/credentials`, `~/.config/gh`, `~/.git-credentials`, `~/.netrc`) does not cover it. It does **narrow** the argument made above for granting `~/.config/gh` read ("the grant exposes no secret *in `hosts.yml`* — the token lives in the macOS keyring"): the keyring *files* are read+write here. That is still not catastrophic, because the real defence is `securityd`'s per-item ACL — keychain entries are encrypted and decryption goes through `securityd`, so file-level read alone does not yield them — but write is a destructive capability regardless. Read that argument as "no secret in `hosts.yml`", not "no keychain exposure".

**Known limitation: `~/.claude.json` does not persist inside nono.** Claude Code writes it via a randomized atomic temp sibling (`~/.claude.json.tmp.<pid>.<hex>`) at `$HOME` root. nono has no filesystem glob, so the temp name cannot be granted and the only fix nono suggests is write access to the entire home directory. `CLAUDE_CONFIG_DIR` would relocate to a *fresh empty* config, silently breaking MCP — strictly worse. Sessions work, but trust dialogs, tips-shown flags and MCP approvals do not persist, and Claude Code degrades silently (`Config fallback write also failed; continuing without persisting`).

**Not fully exercised.** gstack `/browse` (Chromium launch), WebFetch / WebSearch, and `git push` were never run inside nono. Check the observations doc's "Not verified in this pass" table before assuming they work. Row 8 (`/browse`) is the one to close first: per the `open_port: [0]` note above it bounds the **egress guarantee**, not just a feature.

See `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md` for what the allowlist was grown against and what was left blocked, and `docs/superpowers/specs/2026-07-25-nono-sandbox-migration-design.md` for the migration design — that document records the design as approved *before* implementation, so read its top banner first: the observation phase disproved several of its claims.

**Native Bash sandbox (escape hatch)** — `dot_claude/settings.json.tmpl` keeps Claude Code's built-in Bash sandbox enabled (`sandbox.enabled: true`; macOS Seatbelt / Linux bubblewrap), but the nono wrapper passes `--settings '{"sandbox":{"enabled":false}}'` so it is off inside nono and nono is the single boundary. This block therefore governs the `command claude` / `\claude` path, which is the deliberate escape hatch for when a nono policy blocks something — you still get a sandbox rather than falling back to nothing. Everything below (the `allowWrite` temp-dir grants, `denyRead` credential blocks, and the `excludedCommands` list including the `git commit` / `git push` 1Password-socket workaround) is the correct configuration for *that* path and remains in force there. The policy: `network.allowLocalBinding` permits localhost/loopback, `network.allowedDomains` pre-approves dev domains (GitHub, npm/pnpm/yarn registries, Homebrew, Anthropic API — other domains prompt on first use), `filesystem.denyRead` blocks credential reads (`~/.ssh`, `~/.aws/credentials`) with `allowRead` re-permitting the non-secret SSH files git needs (`~/.ssh/config`, `~/.ssh/known_hosts`), `filesystem.allowWrite` grants tool caches (Go/npm/Cargo build caches, pnpm store at `~/Library/pnpm/store`) plus the low-risk OS temp dirs `/tmp`, `/private/tmp` (the macOS symlink pair) and `/var/folders` (the Darwin per-user temp `_CS_DARWIN_USER_TEMP_DIR` a bare `mktemp -d` and `$TMPDIR`-ignoring libc calls resolve to) — all of which the default cwd+session-`$TMPDIR` write boundary would block. The temp dirs unblock tools that hardcode `/tmp` or bypass `$TMPDIR`, and are safe to grant for the same reason `~/.local/share/mise` and other `$PATH`-resident-executable dirs are deliberately excluded: they hold no executables, system config, or shell rc, so a sandboxed write cannot plant a binary that later runs unsandboxed. Rare writes to the excluded dirs (e.g. `mise install`) fall back to the `allowUnsandboxedCommands` escape hatch, and `excludedCommands` runs sandbox-incompatible tools (`docker`, `gh`, `gcloud`, `terraform`, `open`, `osascript`) outside the sandbox. `git commit`/`git push` are **also** in `excludedCommands` so `op-ssh-sign` can reach the 1Password SSH agent Unix socket under `command claude` — the native Seatbelt profile blocks that socket's `network-outbound` and v2.1.205 has no Unix-socket allow key (see `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md`). Trade-off (accepted, not mitigated by hook-neutralization), and it now differs per command: `push` is ask-gated (below), so its unsandboxed SSH transport (`GIT_SSH_COMMAND`, `ext::`) and its `network.allowedDomains` bypass stay prompt-backstopped. `commit` sits in `allow`, so it runs unsandboxed **and** unprompted — a repo-controlled `pre-commit` hook executes outside the sandbox with nothing prompting. Accepted because this repo's own trusted `prek`/`secretlint` pre-commit hooks must **not** be `--no-verify`/`core.hooksPath`-disabled (that would drop a real secret-detection gate). `failIfUnavailable: false` covers *sandbox unavailability* only — it does **not** soften a runtime `sandbox_apply` EPERM, which is why the wrapper's `--settings` override is load-bearing (see the last paragraph of this block). **git write governance:** `permissions.ask` gates `push` and history-altering git (`rebase`, `reset`, `cherry-pick`, `filter-branch`) behind an approval prompt (deny > ask > allow; `ask` fires even under `bypassPermissions` — established by reading Claude Code 2.1.220's permission-resolution path, re-check if that behaviour ever changes — so unattended runs *block* on these — intended). `push` stays gated because the force-push `deny` rules are **prefix-only**: trailing-flag force (`git push origin main --force`), `+refspec`, and `--delete`/`:branch` all evade them, so `push` is not append-only. Locally-reversible writes (`commit`, `merge`, `revert`) and routine writes (`add`, `checkout`, `fetch`, `pull`, `submodule`, `worktree`) stay in `allow` so autonomous loops don't deadlock; read-only git is built-in no-prompt. `gh pr comment` / `gh issue comment` likewise sit in `allow` (append-only to an existing PR/issue). All three force-push forms (`--force`, `--force-with-lease`, `-f`) stay in `deny`. **gh write governance:** `permissions.ask` likewise gates state-changing `gh` subcommands (`issue`/`pr`/`repo`/`release`/`run`/`secret`/`variable`/`workflow`/`label`/`gist`/`cache` verbs like `create`/`edit`/`merge`/`close`/`delete`/`comment`/`run`/`set`), enumerated at the *verb* level because `gh` nests read and write under the same noun (`gh pr view` reads, `gh pr create` writes), so a noun-level `gh pr:*` wildcard would over-gate reads — read-only `gh` (`gh pr view`/`reviews`, and unlisted read verbs under `defaultMode: auto`) stays frictionless. `gh repo delete`/`gh repo archive` are the exception: they sit in **`deny`** (not `ask`) for parity with the publish/force-push tier — irreversible, no legitimate agent use, and `deny` can't be click-through-approved like `ask`. `gh secret set`/`gh variable set` are `ask`-gated only, and the PostToolUse `secretlint` hook matches `Write` to `*.env`/`*secret*` files — **not** Bash `gh` command strings — so a secret passed inline (`gh secret set NAME --body <value>`) is not scanned and lands in shell history/transcripts; prefer `--body-file`/stdin and rely on prompt-time review. `gh api` is deliberately left unlisted (its read/write intent lives in `--method`, not a fixed prefix, so it can't be prefix-gated cleanly) and thus stays auto-approved under `defaultMode: auto` — a known, accepted residual, re-examined and maintained after egress control became a hard requirement (see the `gh api` note in the nono block above for the concrete consequence; arg-pattern gating is tracked in issue #225). Since `gh *` is also in `excludedCommands` (runs outside the sandbox), the `ask` gate is the only remaining control on `gh` mutations. **Package-install governance:** `permissions.ask` also gates commands that pull in new code (`npm`/`pnpm`/`yarn`/`bun` install-family, `pip`/`uv`, `go get`/`go install`, `cargo add`/`install`, `gem install`, `brew install`/`tap`/`bundle`, `mise install`/`use`/`plugin`, `gh extension install`, `claude plugin install`/`marketplace add`, `nono pull`/`update`) and commands that execute remote code without installing (`npx`, `pnpm dlx`, `yarn dlx`, `bunx`, `uvx`). `curl`/`wget` are in `deny`, which closes `curl … | sh`. Lockfile restore (bare `pnpm install`, `npm ci`) is gated **deliberately**: splitting "new deps ask, restore allow" is an illusory boundary, because an agent can edit `package.json` and then run bare `pnpm install` straight through it. Two accepted holes: Claude Code permissions match the Bash string the agent issues and **not its subprocesses**, so `make lint` (`Bash(make:*)`, still in `allow`) invokes `pnpm` without a prompt — acceptable because `make` targets are version-controlled and reviewable; and `gh api` remains unlisted for the reasons above. Filesystem paths use the sandbox's native `~/` prefix, not chezmoi's `.chezmoi.homeDir` template variable.

Why `--settings` and not nesting: macOS denies nested `sandbox_apply`, and the failure is **hard, not graceful**. Without the override, a Bash tool call inside nono dies with `Exit code 71 / sandbox-exec: sandbox_apply: Operation not permitted` — in the observed contrast pair even the agent's own `nono why` diagnostic died with 71 (background: `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md`). The session recovers only because the nono pack injects denial guidance and the agent retries per command, which is recovery by retry, not degradation. So the native sandbox is meaningfully active only on the `command claude` path.

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

**Automated security alert handling** — `.github/workflows/security-alerts.yml` runs a weekly Saturday sweep (schedule) and supports manual dispatch (`gh workflow run security-alerts.yml`). Uses `claude-code-action` to analyze all open security alerts (Dependabot, code scanning, secret scanning) and either auto-fix (low-risk Dependabot/code scanning → PR) or escalate (high-risk/secret scanning → issue with `security` label).

**Scheduled workflow failure alerting** — The scheduled workflow
(`security-alerts.yml`) ends with an `if: failure()` step calling the local composite
action `.github/actions/harness-issue-alert`, which creates (or comments on) an issue
deduplicated by exact title. This prevents silent scheduled failures (an expired
`CLAUDE_CODE_OAUTH_TOKEN` once caused 401 failures for a month unnoticed). Any new
scheduled workflow must include the same step; the alerting steps need `issues: write`
permission.

**Harness self-improvement loop** — Local-only, PR-gated. A SessionEnd hook
(`harness-reflect-trigger.sh`) records substantial sessions (>= 10 assistant turns) to
`~/.claude/harness/pending.jsonl` — deterministic, no LLM. `/harness-reflect` extracts
learnings from the current session and pending transcripts into
`~/.claude/harness/queue.md`. `/harness-review` (nudged by the SessionStart briefing when
overdue >7 days) runs `harness-doctor.sh`, triages the queue against existing rules, and
opens one PR per run; humans review and merge — no auto-apply. Runtime state in
`~/.claude/harness/` is chezmoi-ignored; only rule changes are version-controlled. All
monitoring is deterministic shell — the briefing prints a status line every session, so
silence itself signals a dead hook. Design:
`docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`.

### `.chezmoiignore`

Extensively excludes `~/.claude/` dynamic directories (projects, sessions, cache, etc.) so only curated config files are managed. Also excludes repo-only files like `docs/`, `package.json`, `node_modules/`.

### `.chezmoiexternal.toml`

Pulls external archives (currently gstack skills) into the managed tree with auto-refresh. Each entry uses `type = "archive"` with the commit SHA embedded in the GitHub archive URL for supply-chain safety. Renovate auto-updates these SHAs — see `.claude/rules/renovate-external.md` for the adjacency contract that must be preserved.

### Directory Layout

| Directory | Purpose |
|-----------|---------|
| `darwin/` | macOS-specific resources: `Brewfile`, `DefaultKeyBinding.dict`, `defaults.sh` |
| `windows/` | Windows-specific resources: `alacritty.yml`, `chocolatey` |
| `.chezmoiscripts/` | All `run_onchange_` scripts live here (not in the source tree root) |
| `dot_claude/` | Claude Code config (`~/.claude/`): settings (`settings.json.tmpl`), MCP servers (`mcp-servers.json`), rules, commands, plugins, scripts (hooks), keybindings |
| `dot_config/nono/` | nono sandbox policy: `profiles/claude-seal.json` (the boundary), `packs.txt` (declarative pack list) |
| `scripts/` | Repo-only helper scripts (`update-brewfile.sh`, `update-marketplaces.sh`, `update-gh-extensions.sh`) |
| `docs/solutions/` | Past problem resolutions — search here when encountering similar issues |
| `CONCEPTS.md` | Shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts |
| `CONCEPTS.md` | Shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts |

### Pre-commit Hooks

Uses `prek` (not husky) with `secretlint` to prevent committing secrets. Dependencies managed via pnpm. The `run_onchange_install-pre-commit-hooks.sh.tmpl` script auto-installs when `package.json` or `.pre-commit-config.yaml` change.

## Verification

```sh
make lint                      # Run ALL checks locally (mirrors CI)
chezmoi apply --dry-run        # Preview changes before applying

# Individual targets (same as CI jobs):
make secretlint                # Scan for leaked secrets
make shellcheck                # Lint non-.tmpl shell scripts
make shfmt                     # Check shell script formatting (indent=4)
make oxlint                    # Lint JS/TS files (.js, .mjs, .mts, .ts)
make oxfmt                     # Check JS/TS and JSON formatting
make actionlint                # Lint GitHub Actions workflows (syntax + types)
make zizmor                    # Security audit GitHub Actions workflows
make test-modify               # Smoke test modify_ scripts
make test-scripts              # Smoke test harness scripts
make test-harness-scripts      # Smoke test harness loop scripts (trigger/briefing/doctor)
make check-templates           # Validate chezmoi .tmpl files
make scan-sensitive            # Scan all .md files for PII and sensitive info
make test-sensitive            # Smoke test sensitive info scanner
make test-nono-profile         # Validate the nono sandbox profile (skipped if nono absent)
```

Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). CI (`.github/workflows/lint.yml`) and local use the same `make` targets — if it passes locally, CI will pass too. For similar past issues, search `docs/solutions/`.

## Known Pitfalls

### chezmoi CLI & File Management

- **`chezmoi add --autotemplate` breaks JSON** — `:` and `/` get over-substituted. Use `chezmoi add --template` + manual `sed` for homeDir substitution instead.
- **`run_after_` scripts calling `chezmoi add` cause recursion** — Use `cp` + `sed` to write directly to the source directory.
- **`.chezmoiignore` silently skips** — If `chezmoi add` does nothing, check `.chezmoiignore`.
- **`.chezmoiignore` `*.txt` is root-level only** — `*.txt` does NOT match nested paths like `.config/gh/extensions.txt`. Use `**/*.txt` for recursive matching, or add explicit entries for nested files. Always verify with `chezmoi managed | grep <pattern>`.
- **Repo-only files need `.chezmoiignore`** — Files like `CLAUDE.md`, `README.md` at repo root are excluded via `.chezmoiignore` so they don't deploy to `~/`. New repo-only files must be added there.
- **`.chezmoiignore` bare filenames match target paths** — `.chezmoiignore` evaluates target paths, not source filenames. Adding `.gitignore` blocks `dot_gitignore` → `~/.gitignore` deployment because the target path is `.gitignore`. Likewise, regular non-prefixed source files (e.g., `README.md`, `LICENSE`) are still managed by chezmoi and need explicit `.chezmoiignore` entries to prevent deployment to `~/`. `dot_`, `private_`, etc. are mapping conventions for how source names translate to targets, not a gate for whether chezmoi considers a file a source.
- **Choosing chezmoi file patterns** — Regular `.tmpl` for fully-owned files. `create_` for provision-once. `modify_` for runtime-mutable files (IDE configs). `.chezmoiignore` to exclude entirely. For files modified by external tools (plugins), prefer `.chezmoiignore` + declarative `run_onchange_` scripts over bidirectional sync.
- **Never edit deployed targets directly** — Always edit the chezmoi source file (under `~/.local/share/chezmoi/`), never the deployed target (under `~/`). For example, edit `dot_claude/scripts/executable_harness-briefing.sh`, not `~/.claude/scripts/harness-briefing.sh`. Changes to deployed targets are overwritten on next `chezmoi apply` and are not version-controlled. Use `chezmoi source-path <target>` to find the source file for any managed target.
- **`docs/` is tracked** — Both `docs/plans/` and `docs/solutions/` are committed. Plan files created by `ce:plan` and solution documents are version-controlled. Ensure no PII or sensitive information is included — `make scan-sensitive` checks all `.md` files in the repo.
- **Do not judge `modify_*` files by extension** — `modify_dot_claude.json` has a `.json` extension but is a bash script. Add `! -name 'modify_*'` exclusions to file-type-based linter/formatter globs (`*.json`, `*.yaml`, etc.). Also include `modify_` patterns in pre-commit excludes.
- **`chezmoi apply` deploys from `main`, not from your branch** — The chezmoi source directory `~/.local/share/chezmoi` is a *separate git worktree pinned to `main`*; feature work happens in sibling worktrees (`~/orca/workspaces/chezmoi/<name>`). `chezmoi diff` and `chezmoi apply` therefore read `main`'s templates and show **nothing** for unmerged branch changes — which reads as "no drift", not as "wrong source". Verify branch changes by rendering instead (`chezmoi execute-template --config <test toml> --source "$(pwd)"`), and deploy only after the branch merges. Confirm with `git -C ~/.local/share/chezmoi rev-parse --abbrev-ref HEAD`.

### Template Syntax

- **Template escaping** — To output literal `{{ .chezmoi.homeDir }}` in a `.tmpl` file, use `{{ "{{ .chezmoi.homeDir }}" }}`.
- **`chezmoi execute-template` in CI needs config + source** — `--init --promptString` only answers `promptStringOnce` prompts; it does NOT populate the `.data` namespace (`.ghOrg`, `.profile`) that templates reference. Use a test `chezmoi.toml` with `[data]` section and pass `--config <path> --source "$(pwd)"`. Also exclude `.chezmoi.toml.tmpl` itself since it uses `promptStringOnce` (interactive).
- **`chezmoi diff`/`apply` from a secondary worktree needs `--source`** — chezmoi resolves its source directory from its own config (`~/.local/share/chezmoi`), not from the current directory. Running bare `chezmoi diff` inside a git worktree of this repo therefore compares against the *main* worktree's sources and silently omits the branch's changes — a false negative that reads as "no drift". Always pass `--source "$(pwd)"` when verifying template changes from a worktree.
- **`scripts/update-brewfile.sh` regenerates the whole Brewfile, drift included** — it runs `brew bundle dump --force`, so its diff is "this machine's current state" and not "the one package you just installed". On a machine with packages installed outside chezmoi it produces a ~100-line diff mixing unrelated taps/casks/mas apps (and brew's description comments) into whatever change you were making. To add a single package to an existing feature branch, hand-add the one `brew "..."` line in alphabetical position and note in the commit that the file is no longer a faithful dump; reconcile the accumulated drift as its own separate change. Verify with `git diff --stat darwin/Brewfile` that exactly one line was added and none removed.

### Script Safety

- **`modify_` scripts: empty stdout = target deletion** — Never use OS guards (`{{ if eq .chezmoi.os "darwin" }}`); on non-matching OS the script outputs nothing and chezmoi zeros the file. Always include `set -e`. Use `printf '%s\n'` (not `printf '%s'`) to preserve trailing newlines stripped by `$(cat)`.
- **Hook scripts: set one-shot flags after guards, not before** — When using `/tmp` flag files for "run once per session" behavior, place the `touch` **after** context guards (directory exclusions, git checks), not before. If the flag is set before guards, a non-project context (e.g., `$HOME`) consumes the one-shot flag, and navigating to a project later in the same session silently skips the hook.

### External Constraints & Tool Integration

- **Git commit signing** — Requires 1Password SSH agent (`op-ssh-sign`). Commits will fail without it running.
- **Plugin marketplace renames silently break `enabledPlugins`** — The ecc (everything-claude-code) plugin has been renamed upstream more than once (`ecc` ↔ `everything-claude-code`). When the `plugin@marketplace` key in `settings.json.tmpl` no longer matches the marketplace's current plugin name, the plugin silently stops loading — its hooks and agents stop working with no error. After marketplace auto-updates, verify `claude plugin list` output and check `~/.claude/plugins/installed_plugins.json` contains the expected key.
- **Inline hook commands: keep simple or use jq** — Inline `bash -c` hook commands in `settings.json.tmpl` have two layers of escaping (JSON `\"` + shell quoting) that are extremely error-prone. Avoid complex grep/sed patterns; use `jq` (already a dependency) or extract logic into external script files.
- **`git diff | grep '^[+-]'` verifies nothing here** — `diff.external = difft` (difftastic) is configured globally, so `git diff` emits no `+`/`-` line prefixes. Any verification that pipes `git diff` into a `^[+-]` grep matches zero lines and therefore *looks like it passed* while checking nothing. Use `git diff --no-ext-diff` when a command needs unified output; `git diff --stat`, `git show --stat`, and `chezmoi diff` are unaffected.
- **Moving an entry out of `permissions.ask` widens more than the `deny` prefixes catch** — Permission rules are prefix matches, so a narrow `deny` such as `Bash(git push --force:*)` only fires when the flag immediately follows the command. While a broad `Bash(git push:*)` sat in `ask`, *every* spelling prompted; moving it to `allow` silently permitted `git push origin main --force`, `git push origin +main`, and `git push --delete origin foo` — none of which match any `deny` entry. Before moving any entry out of `ask`, enumerate the argument spellings the remaining `deny` rules do **not** match. If write intent can migrate into a flag position, the entry stays in `ask`; a narrow `deny` is not a substitute for a broad `ask`. See the Tier 1 enforceability requirement in `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`.
- **Verify GitHub Actions template output** — Workflows generated from templates (e.g., `claude-code-action`) default to read-only permissions. Posting comments requires `pull-requests: write` / `issues: write`. Do not use template output as-is — verify permissions match the intended use. See `~/.claude/rules/common/github-actions.md` for expression syntax constraints.
- **Never hardcode node/pnpm versions in CI** — All pnpm/node jobs in `lint.yml` must use `node-version-file: '.node-version'` and `packageManager` auto-detection. Direct `version:` or `node-version:` inputs are prohibited. Version sources: `.node-version` (node), `package.json` `packageManager` (pnpm).

### nono Sandbox

- **nono profiles must not be chezmoi templates** — nono expands `$HOME`, `$XDG_CONFIG_HOME`, `$WORKDIR`, `$TMPDIR`, `$NONO_CONFIG`, and `$NONO_PACKAGES` itself. Writing `{{ .chezmoi.homeDir }}` works but forfeits `make oxfmt` JSON validation and `nono profile validate`. Keep profiles as plain JSON with **no comments** (both oxfmt and nono reject JSONC).
- **`nono run` needs `--allow-cwd`** — `workdir.access` sets the access *level*, not the grant. Without the flag the working directory is denied outright (`Sandbox denial: … (read)`) and nono falls back to an interactive prompt a non-interactive run cannot answer. Any wrapper must pass it, or stay inside a directory the profile already grants (e.g. `~/ghq`).
- **`filesystem.bypass_protection` grants nothing on its own** — it only lifts a deny-group rule. The path must *also* appear in `filesystem.allow` / `read` / `write` (or a `*_file` variant) to become accessible; listing it in `bypass_protection` alone silently changes nothing. The shipped profile pairs both for `~/.bashrc`, `~/.bash_profile`, `~/.zshrc`, `~/.zprofile` (blocked by the required `deny_shell_configs` group). Note it was **not** the answer for the 1Password socket — see `filesystem.unix_socket` above.
- **`filesystem.deny` does not override `filesystem.write`** — tested by adding the paths to `deny`: the profile validates and they stay `ALLOWED / Granted by: <the write grant>`. A carve-out inside a granted directory is **not expressible within `filesystem`** — there, the only way to narrow is to grant less. (`command_policies.commands.<name>.fs_write` is a separate mechanism that can scope one tool's writes, including via `@git:*` provider tokens; see the `commondir` residual above.)
- **`nono why --host X --port 22` falsely reports ALLOWED** — `nono why` models the HTTP(S) proxy allowlist and nothing else, so it does not see the raw-TCP restriction. Any `nono why` host result is valid for HTTP(S) only. For anything else, probe the real connection.
- **`nono profile validate` rejects unknown keys** as a hard parse error, but `nono profile schema` output is **incomplete** (its `FilesystemConfig` omits all six `unix_socket*` keys the parser itself accepts). Trust the parser error over the emitted schema.
- **The nono pack writes `enabledPlugins` into `~/.claude/settings.json`** — chezmoi fully owns `settings.json.tmpl`, so the key must be reflected there or `chezmoi apply` wipes it and the pack's sandbox-diagnostic hooks silently stop firing. Same failure shape as the marketplace-rename pitfall above. Verify with `jq '.enabledPlugins' ~/.claude/settings.json` after apply.
- **A nono user profile shadows a pack profile of the same name** — naming a local profile `claude-code` silently discards the pack's base grants. Use a distinct name (`claude-seal`) and `extends`.
- **MCP stdio servers do not pass through zsh wrapper functions** — `mcp-servers.json` entries are exec'd directly, so the `codex()` wrapper's nested-sandbox handling does not apply to the codex MCP server. In this case nothing was needed (nesting does not break the stdio server — it connected in 89 ms inside nono, and `codex mcp-server` accepts no `--sandbox` flag at all; only *interactive* codex needs `--sandbox danger-full-access`), but for a server that does need a nested-sandbox flag it must go in `args` or a shim script.
- **Verify Homebrew formula names before uninstalling** — the formula for safehouse was `agent-safehouse`, not `safehouse`; `brew uninstall safehouse` silently no-ops and leaves the tool installed. Confirm with `brew list | grep <name>` after any removal.
- **`.chezmoiremove` with `path/**` can break `chezmoi apply` outright** — a leftover Unix socket under a directory removed via the `path/**` convention produced `unsupported file type socket` and exit 1. Bare directory entries (no `/**`) worked.

## gstack

Use the `/browse` skill from gstack for **all web browsing**. Never use `mcp__claude-in-chrome__*` tools.

### Available Skills

`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`, `/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`, `/learn`
