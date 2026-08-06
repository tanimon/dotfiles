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

# Linting (mirrors CI — also runs on commit via prek; requires `just`, installed via darwin/Brewfile)
just lint                      # Run all checks (secretlint + shellcheck + shfmt + oxlint + oxfmt + actionlint + zizmor + modify_ + script tests + templates + sensitive scan + nono profile)
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

**`dot_apm/apm.yml` + APM (microsoft/apm)** — Single declarative manifest for MCP servers and (as of the Skill/plugin migration) Claude Code Skills/plugins, deployed to `~/.apm/apm.yml`. `.chezmoiscripts/run_after_apm-install.sh.tmpl` runs `apm install --global --target claude` on **every** `chezmoi apply` (not hash-gated on `apm.yml`'s content) and writes MCP servers into the top-level `mcpServers` key of `~/.claude.json` (as of 2026-07-26 this was a symlink to `~/.claude/claude.json` — do not assume that topology still holds; verify before relying on either path, see the Known Pitfalls entry below) and deploys Skills to `~/.claude/skills/`. `--target claude` is required — omitting it makes `apm install --global` fan out to every "global-capable" runtime it detects (Gemini CLI, Kiro, etc.), not just Claude Code. It must re-run on every apply, not just when `apm.yml` changes, because Skill plugins that ship hooks (e.g. `superpowers`) write those hooks directly into `~/.claude/settings.json`, which `settings.json.tmpl` also fully owns — without an unconditional re-run, the next apply's template render would silently erase the hook with no way to restore it. Plugins are pinned as git shorthand (`owner/repo#ref`, e.g. `obra/superpowers#v6.2.0`) rather than marketplace references (`name`/`marketplace` object form), since APM's own marketplace registry (`~/.apm/marketplaces.json`) isn't declaratively bootstrapped and would fail to resolve on a fresh machine. APM marks its own generated files, so hand-authored files (e.g. `dot_claude/skills/*`) are never overwritten. chezmoi no longer manages `~/.claude/claude.json` directly — this replaced the earlier `modify_claude.json` (jq-based partial ownership) approach. Some plugins bring their own MCP servers independent of `dependencies.mcp` (e.g. `getsentry/plugin-claude`, pulled in via `dependencies.apm`, installs its own `sentry` MCP server), so `dependencies.mcp` is only a subset of the MCP servers actually deployed — check the live `mcpServers` key, not just `apm.yml`, to see the full set. Of the 9 `dependencies.apm` git-shorthand pins, a few without a tag are pinned to a bare commit SHA and fall outside Renovate's tag-based update coverage, so those require manual bumping. Running `apm install <pkg>` by hand appends the dependency straight to `~/.apm/apm.yml` (the deploy target, fully owned by chezmoi via `dot_apm/apm.yml`) and that edit is silently lost on the next `chezmoi apply` — always declare new dependencies in `dot_apm/apm.yml` instead. See `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md`.

**`dot_config/karabiner/modify_karabiner.json`** — Partial management of `~/.config/karabiner/karabiner.json`, mirroring the jq-based partial-ownership pattern formerly used by `dot_claude/modify_claude.json` (now removed in favor of APM; see above). Owns `profiles[*].complex_modifications.rules` only; preserves Karabiner's runtime state (`machine_specific` UUID, profile metadata, `virtual_hid_keyboard`, sibling `complex_modifications.parameters`, etc.) verbatim. The rules array lives at `dot_config/karabiner/complex_modifications.json` and is applied to *every* profile (V1 deliberately ignores per-profile rule divergence). Empty stdin (new-machine bootstrap before Karabiner has been launched) seeds a minimal profile shape with no fabricated `machine_specific`. First apply normalizes the file mode from Karabiner's `0600` to `0644`; Karabiner restores `0600` on next save. Smoke-tested by `just test-modify`.

**Skill/plugin management via APM** — `dot_apm/apm.yml`'s `dependencies.apm` list declares every Claude Code plugin to install (superseding the earlier `marketplaces.txt` + `settings.json.tmpl` `enabledPlugins`/`extraKnownMarketplaces` combination). `run_after_apm-install.sh.tmpl` runs `apm install --global --target claude` on every `chezmoi apply` (not gated on `apm.yml`'s hash — plugin hooks land directly in `~/.claude/settings.json`, which `settings.json.tmpl` also fully owns, so this script must re-run every apply to keep hooks from silently disappearing after the next `chezmoi apply` overwrites them). Plugins are pinned as git shorthand strings (`owner/repo#ref`, e.g. `obra/superpowers#v6.2.0`) rather than marketplace references, since APM's own marketplace registry (`~/.apm/marketplaces.json`) is not declaratively bootstrapped and would fail to resolve on a fresh machine. To add a plugin: find its real upstream repo+ref (`apm view <name>@<marketplace>` after `apm marketplace add <marketplace-repo>`, or check the marketplace's `.claude-plugin/marketplace.json` directly), append `owner/repo#ref` to `dependencies.apm`, commit, and let the next `chezmoi apply` install it. To remove: delete the line from `apm.yml` — `apm install --global` reconciles deployed files against the current manifest, but only for files it generated (hand-authored files, e.g. `dot_claude/skills/*`, are never touched). Plugin install/enable runtime state (`installed_plugins.json`, `known_marketplaces.json`) is still not managed by chezmoi — these files remain in `.chezmoiignore`.

**Declarative gh extension sync** — `dot_config/gh/extensions.txt` lists gh extensions (one `owner/repo` per line). `run_onchange_after_install-gh-extensions.sh.tmpl` installs them when the list changes. `scripts/update-gh-extensions.sh` regenerates the list from `gh extension list`. Same pattern as marketplace sync. Note: `gh extension list` is tab-delimited — use `awk -F'\t'` to parse.

**`run_onchange_` scripts** — Track file hashes in comments (e.g., `# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}`). They re-run only when the tracked content changes.

**Claude Code sandbox (nono)** — The `claude` shell command is wrapped by `dot_config/zsh/sandbox.zsh` to run inside [nono](https://github.com/nolabs-ai/nono) (Homebrew, macOS Seatbelt / Linux Landlock, deny-all default), extending the official `claude-code` pack via `dot_config/nono/profiles/claude-seal.json`. See `dot_config/nono/CLAUDE.md` for the full policy detail (egress control, git/gh-inside-the-boundary, 1Password signing, accepted security residuals, the native-sandbox escape hatch).

**Notification hook ownership** — `dot_claude/scripts/executable_notify.sh` wires notification delivery to `Notification`/`StopFailure` only. See `dot_claude/scripts/CLAUDE.md` for the full detail (matcher filtering, orca handoff, delivery backend fallback).

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
| `dot_claude/` | Claude Code config (`~/.claude/`): settings (`settings.json.tmpl`), rules, commands, plugins, scripts (hooks), keybindings |
| `dot_apm/` | APM (microsoft/apm) global manifest: `apm.yml` — declares MCP servers and Claude Code Skills/plugins, deployed to `~/.apm/apm.yml` |
| `dot_config/nono/` | nono sandbox policy: `profiles/claude-seal.json` (the boundary), `packs.txt` (declarative pack list) |
| `scripts/` | Repo-only helper scripts (`update-brewfile.sh`, `update-gh-extensions.sh`) |
| `test/` | bats-core test suites — one `.bats` file per script under test, run via `just test-*` targets |
| `docs/solutions/` | Past problem resolutions — search here when encountering similar issues |
| `CONCEPTS.md` | Shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts |

### Pre-commit Hooks

Uses `prek` (not husky) with `secretlint` to prevent committing secrets. Dependencies managed via pnpm. The `run_onchange_install-pre-commit-hooks.sh.tmpl` script auto-installs when `package.json` or `.pre-commit-config.yaml` change.

## Verification

```sh
just lint                      # Run ALL checks locally (mirrors CI)
chezmoi apply --dry-run        # Preview changes before applying

# Individual recipes (same as CI jobs):
just secretlint                # Scan for leaked secrets
just shellcheck                # Lint non-.tmpl shell scripts
just shfmt                     # Check shell script formatting (indent=4)
just oxlint                    # Lint JS/TS files (.js, .mjs, .mts, .ts)
just oxfmt                     # Check JS/TS and JSON formatting
just actionlint                # Lint GitHub Actions workflows (syntax + types)
just zizmor                    # Security audit GitHub Actions workflows
just test-modify               # Smoke test modify_ scripts
just test-scripts              # Smoke test harness scripts
just test-harness-scripts      # Smoke test harness loop scripts (trigger/briefing/doctor)
just check-templates           # Validate chezmoi .tmpl files
just scan-sensitive            # Scan all .md files for PII and sensitive info
just test-sensitive            # Smoke test sensitive info scanner
just test-nono-profile         # Validate the nono sandbox profile (skipped if nono absent)
```

Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). CI (`.github/workflows/lint.yml`) and local use the same `just` recipes — if it passes locally, CI will pass too. For similar past issues, search `docs/solutions/`.

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
- **`docs/` is tracked** — Both `docs/plans/` and `docs/solutions/` are committed. Plan files created by `ce:plan` and solution documents are version-controlled. Ensure no PII or sensitive information is included — `just scan-sensitive` checks all `.md` files in the repo.
- **Do not judge `modify_*` files by extension** — `dot_config/karabiner/modify_karabiner.json` has a `.json` extension but is a bash script. Add `! -name 'modify_*'` exclusions to file-type-based linter/formatter globs (`*.json`, `*.yaml`, etc.). Also include `modify_` patterns in pre-commit excludes.
- **`~/.claude.json` topology has changed before and may change again — verify, don't assume** — as of 2026-07-26, Claude Code's native install symlinked `~/.claude.json` to a real runtime state file at `~/.claude/claude.json`. That was a point-in-time observation, not a permanent guarantee: a later check found `~/.claude.json` back to being a regular file (not a symlink) with its own independent `mcpServers` key, diverging from `~/.claude/claude.json`'s. Nothing in this repo manages either file directly anymore (APM's `apm install --global` writes to whichever `~/.claude.json` resolves to at runtime, outside chezmoi's control). The lasting lesson for any future `modify_` script: never assume today's topology — check with `ls -la`/`file` before writing, because writing back through a symlink target replaces it with a plain file (verified in an isolated test, `chezmoi apply -S <tmp> -D <tmp>` replaced a `120755` symlink with a `100644` regular file). `~/.claude.json` stays listed in `.chezmoiignore` so chezmoi never touches it, symlink or not.
- **`chezmoi apply` deploys from `main`, not from your branch** — The chezmoi source directory `~/.local/share/chezmoi` is a *separate git worktree pinned to `main`*; feature work happens in sibling worktrees (`~/orca/workspaces/chezmoi/<name>`). `chezmoi diff` and `chezmoi apply` therefore read `main`'s templates and show **nothing** for unmerged branch changes — which reads as "no drift", not as "wrong source". Verify branch changes by rendering instead (`chezmoi execute-template --config <test toml> --source "$(pwd)"`), and deploy only after the branch merges. Confirm with `git -C ~/.local/share/chezmoi rev-parse --abbrev-ref HEAD`. The same `--source "$(pwd)"` requirement applies to *every* chezmoi command that reads source state (`managed`, `ignored`, `diff`, `apply`), not only `execute-template` — and the reason it bites so hard is that the resulting check passes *vacuously*: see [verification through the wrong resolution path](docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md) for the general shape of that failure and how to test for it.

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
- **(過去の障害記録 — `enabledPlugins`ベースの運用は撤去済み) Plugin marketplace renames silently break `enabledPlugins`** — The ecc (everything-claude-code) plugin was renamed upstream more than once (`ecc` ↔ `everything-claude-code`). When the `plugin@marketplace` key in `settings.json.tmpl` no longer matched the marketplace's current plugin name, the plugin silently stopped loading — its hooks and agents stopped working with no error. この`enabledPlugins`/`settings.json.tmpl`を前提にした検証手順は、Task 8のAPM移行で`enabledPlugins`/`extraKnownMarketplaces`が完全に撤去されたため、もう存在しない（今`claude plugin list`や`~/.claude/plugins/installed_plugins.json`を確認する対象のキーは無い）。ただし「上流の改名でプラグインが静かに読み込まれなくなる」という教訓自体はAPM運用（`dependencies.apm`のgit shorthand参照先リポジトリが改名・移動した場合）でも起こりうるため、記録として残す。APM配下での相当する確認は、`apm.lock.yaml`の`resolved_commit`が意図通りか、および`~/.claude/skills`等に期待するSkillが実際に展開されているかを確認すること。
- **Inline hook commands: keep simple or use jq** — Inline `bash -c` hook commands in `settings.json.tmpl` have two layers of escaping (JSON `\"` + shell quoting) that are extremely error-prone. Avoid complex grep/sed patterns; use `jq` (already a dependency) or extract logic into external script files.
- **`git diff | grep '^[+-]'` verifies nothing here** — `diff.external = difft` (difftastic) is configured globally, so `git diff` emits no `+`/`-` line prefixes. Any verification that pipes `git diff` into a `^[+-]` grep matches zero lines and therefore *looks like it passed* while checking nothing. Use `git diff --no-ext-diff` when a command needs unified output; `git diff --stat`, `git show --stat`, and `chezmoi diff` are unaffected. This is the same species as the chezmoi-source pitfall above — a check that resolves something other than what it appears to and so reports a green result while verifying nothing; [verification through the wrong resolution path](docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md) collects the instances and the prevention rule.
- **Moving an entry out of `permissions.ask` widens more than the `deny` prefixes catch** — Permission rules are prefix matches, so a narrow `deny` such as `Bash(git push --force:*)` only fires when the flag immediately follows the command. While a broad `Bash(git push:*)` sat in `ask`, *every* spelling prompted; moving it to `allow` silently permitted `git push origin main --force`, `git push origin +main`, and `git push --delete origin foo` — none of which match any `deny` entry. Before moving any entry out of `ask`, enumerate the argument spellings the remaining `deny` rules do **not** match. If write intent can migrate into a flag position, the entry stays in `ask`; a narrow `deny` is not a substitute for a broad `ask`. See the Tier 1 enforceability requirement in `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`.
- **Verify GitHub Actions template output** — Workflows generated from templates (e.g., `claude-code-action`) default to read-only permissions. Posting comments requires `pull-requests: write` / `issues: write`. Do not use template output as-is — verify permissions match the intended use. See `~/.claude/rules/common/github-actions.md` for expression syntax constraints.
- **Never hardcode node/pnpm versions in CI** — All pnpm/node jobs in `lint.yml` must use `node-version-file: '.node-version'` and `packageManager` auto-detection. Direct `version:` or `node-version:` inputs are prohibited. Version sources: `.node-version` (node), `package.json` `packageManager` (pnpm).

### nono Sandbox

- **nono profiles must not be chezmoi templates** — nono expands `$HOME`, `$XDG_CONFIG_HOME`, `$WORKDIR`, `$TMPDIR`, `$NONO_CONFIG`, and `$NONO_PACKAGES` itself. Writing `{{ .chezmoi.homeDir }}` works but forfeits `just oxfmt` JSON validation and `nono profile validate`. Keep profiles as plain JSON with **no comments** (both oxfmt and nono reject JSONC).
- **`nono run` needs `--allow-cwd`** — `workdir.access` sets the access *level*, not the grant. Without the flag the working directory is denied outright (`Sandbox denial: … (read)`) and nono falls back to an interactive prompt a non-interactive run cannot answer. Any wrapper must pass it, or stay inside a directory the profile already grants (e.g. `~/ghq`).
- **`filesystem.bypass_protection` grants nothing on its own** — it only lifts a deny-group rule. The path must *also* appear in `filesystem.allow` / `read` / `write` (or a `*_file` variant) to become accessible; listing it in `bypass_protection` alone silently changes nothing. The shipped profile pairs both for `~/.bashrc`, `~/.bash_profile`, `~/.zshrc`, `~/.zprofile` (blocked by the required `deny_shell_configs` group). Note it was **not** the answer for the 1Password socket — see `filesystem.unix_socket` above.
- **`filesystem.deny` does not override `filesystem.write`** — tested by adding the paths to `deny`: the profile validates and they stay `ALLOWED / Granted by: <the write grant>`. A carve-out inside a granted directory is **not expressible within `filesystem`** — there, the only way to narrow is to grant less. (`command_policies.commands.<name>.fs_write` is a separate mechanism that can scope one tool's writes, including via `@git:*` provider tokens; see the `commondir` residual above.)
- **`nono why --host X --port 22` falsely reports ALLOWED** — `nono why` models the HTTP(S) proxy allowlist and nothing else, so it does not see the raw-TCP restriction. Any `nono why` host result is valid for HTTP(S) only. For anything else, probe the real connection.
- **`nono profile validate` rejects unknown keys** as a hard parse error, but `nono profile schema` output is **incomplete** (its `FilesystemConfig` omits all six `unix_socket*` keys the parser itself accepts). Trust the parser error over the emitted schema.
- **`~/.claude/settings.json` is fought over by chezmoi and APM, not just the nono pack** — the old hand-maintained `enabledPlugins`/`extraKnownMarketplaces` blocks (kept in sync with the nono pack's install-time write) were removed entirely in Task 8 of the APM migration; APM does not use Claude Code's native plugin-marketplace registry. Instead, `apm install --global --target claude` deploys plugin Skill/Command/Hook content directly under `~/.claude/` and writes hook definitions straight into `settings.json`'s `hooks` key (discovered during Task 6 implementation; see `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md`, "実装時の訂正" item 2). `run_after_apm-install.sh.tmpl` re-runs this install on every `chezmoi apply` (not hash-gated) precisely because that merged `hooks` content would otherwise be silently wiped by the next template render, which still fully owns `settings.json`. Verify with `jq '.hooks' ~/.claude/settings.json` after apply that APM-authored hooks (e.g. superpowers' `SessionStart`) are present.
- **A nono user profile shadows a pack profile of the same name** — naming a local profile `claude-code` silently discards the pack's base grants. Use a distinct name (`claude-seal`) and `extends`.
- **MCP stdio servers do not pass through zsh wrapper functions** — `mcpServers` entries (declared in `dot_apm/apm.yml`, written into `~/.claude/claude.json` by APM) are exec'd directly, so the `codex()` wrapper's nested-sandbox handling does not apply to the codex MCP server. In this case nothing was needed (nesting does not break the stdio server — it connected in 89 ms inside nono, and `codex mcp-server` accepts no `--sandbox` flag at all; only *interactive* codex needs `--sandbox danger-full-access`), but for a server that does need a nested-sandbox flag it must go in `args` or a shim script.
- **Verify Homebrew formula names before uninstalling** — the formula for safehouse was `agent-safehouse`, not `safehouse`; `brew uninstall safehouse` silently no-ops and leaves the tool installed. Confirm with `brew list | grep <name>` after any removal.
- **`.chezmoiremove` with `path/**` can break `chezmoi apply` outright** — a leftover Unix socket under a directory removed via the `path/**` convention produced `unsupported file type socket` and exit 1. Bare directory entries (no `/**`) worked.

## gstack

Use the `/browse` skill from gstack for **all web browsing**. Never use `mcp__claude-in-chrome__*` tools.

### Available Skills

`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`, `/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`, `/learn`
