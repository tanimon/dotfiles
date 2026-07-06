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
make lint                      # Run all checks (secretlint + shellcheck + shfmt + oxlint + oxfmt + actionlint + zizmor + modify_ + script tests + templates + sensitive scan)
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

**Claude Code sandbox** — The `claude` shell command is wrapped by `dot_config/zsh/sandbox.zsh` to run inside a macOS Seatbelt sandbox. Primary tool is [agent-safehouse](https://github.com/eugene1g/agent-safehouse) (Homebrew, deny-all default), with [cco](https://github.com/nikvdp/cco) as fallback. Sandbox configuration lives in `dot_config/safehouse/config.tmpl` (safehouse CLI flags, one per line) and `dot_config/cco/allow-paths.tmpl` (cco path allowlist). cco is still pulled via `.chezmoiexternal.toml` for Linux fallback; `run_onchange_after_link-cco.sh.tmpl` symlinks the binary. Use `command claude` or `\claude` to bypass sandboxing.

**Native Bash sandbox (migration target)** — `dot_claude/settings.json.tmpl` enables Claude Code's built-in Bash sandbox (`sandbox.enabled: true`; macOS Seatbelt / Linux bubblewrap), the intended replacement for the external safehouse/cco wrapper above. The policy is modeled on `dot_config/safehouse/config.tmpl`: `network.allowLocalBinding` permits localhost/loopback, `network.allowedDomains` pre-approves dev domains (GitHub, npm/pnpm/yarn registries, Homebrew, Anthropic API — other domains prompt on first use), `filesystem.denyRead` blocks credential reads (`~/.ssh`, `~/.aws/credentials`) with `allowRead` re-permitting the non-secret SSH files git needs (`~/.ssh/config`, `~/.ssh/known_hosts`), `filesystem.allowWrite` grants tool caches (Go/npm/Cargo build caches, pnpm store at `~/Library/pnpm/store`) that the default cwd+tmp write boundary would block — deliberately excluding `~/.local/share/mise` and other dirs that hold `$PATH`-resident executables, so a sandboxed write cannot plant a binary that later runs unsandboxed; rare writes there (e.g. `mise install`) fall back to the `allowUnsandboxedCommands` escape hatch, and `excludedCommands` runs sandbox-incompatible tools (`docker`, `gh`, `gcloud`, `terraform`, `open`, `osascript`) outside the sandbox. `failIfUnavailable: false` keeps behavior graceful during migration. The native sandbox is the primary isolation when running `command claude` (no outer Seatbelt, so no nested `sandbox_apply` conflict). Under the wrapped `claude` path both sandboxes are active: the inner native sandbox hits a nested `sandbox_apply` EPERM (macOS denies nested Seatbelt — see `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md`), and `failIfUnavailable: false` degrades it to unsandboxed Bash while safehouse continues to isolate. So today the native sandbox is meaningfully active only via `command claude`; once safehouse is retired, re-audit the safehouse path allowlist (`dot_config/safehouse/config.tmpl`) for parity before `command claude` becomes the sole path. Filesystem paths use the sandbox's native `~/` prefix, not chezmoi's `.chezmoi.homeDir` template variable.

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

Pulls external archives (e.g., gstack skills, cco) into the managed tree with auto-refresh. Each entry uses `type = "archive"` with the commit SHA embedded in the GitHub archive URL for supply-chain safety. Renovate auto-updates these SHAs — see `.claude/rules/renovate-external.md` for the adjacency contract that must be preserved.

### Directory Layout

| Directory | Purpose |
|-----------|---------|
| `darwin/` | macOS-specific resources: `Brewfile`, `DefaultKeyBinding.dict`, `defaults.sh` |
| `windows/` | Windows-specific resources: `alacritty.yml`, `chocolatey` |
| `.chezmoiscripts/` | All `run_onchange_` scripts live here (not in the source tree root) |
| `dot_claude/` | Claude Code config (`~/.claude/`): settings (`settings.json.tmpl`), MCP servers (`mcp-servers.json`), rules, commands, plugins, scripts (hooks), keybindings |
| `scripts/` | Repo-only helper scripts (`update-brewfile.sh`, `update-marketplaces.sh`, `update-gh-extensions.sh`) |
| `docs/solutions/` | Past problem resolutions — search here when encountering similar issues |

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

### Template Syntax

- **Template escaping** — To output literal `{{ .chezmoi.homeDir }}` in a `.tmpl` file, use `{{ "{{ .chezmoi.homeDir }}" }}`.
- **`chezmoi execute-template` in CI needs config + source** — `--init --promptString` only answers `promptStringOnce` prompts; it does NOT populate the `.data` namespace (`.ghOrg`, `.profile`) that templates reference. Use a test `chezmoi.toml` with `[data]` section and pass `--config <path> --source "$(pwd)"`. Also exclude `.chezmoi.toml.tmpl` itself since it uses `promptStringOnce` (interactive).

### Script Safety

- **`modify_` scripts: empty stdout = target deletion** — Never use OS guards (`{{ if eq .chezmoi.os "darwin" }}`); on non-matching OS the script outputs nothing and chezmoi zeros the file. Always include `set -e`. Use `printf '%s\n'` (not `printf '%s'`) to preserve trailing newlines stripped by `$(cat)`.
- **Hook scripts: set one-shot flags after guards, not before** — When using `/tmp` flag files for "run once per session" behavior, place the `touch` **after** context guards (directory exclusions, git checks), not before. If the flag is set before guards, a non-project context (e.g., `$HOME`) consumes the one-shot flag, and navigating to a project later in the same session silently skips the hook.

### External Constraints & Tool Integration

- **Git commit signing** — Requires 1Password SSH agent (`op-ssh-sign`). Commits will fail without it running.
- **Plugin marketplace renames silently break `enabledPlugins`** — The ecc (everything-claude-code) plugin has been renamed upstream more than once (`ecc` ↔ `everything-claude-code`). When the `plugin@marketplace` key in `settings.json.tmpl` no longer matches the marketplace's current plugin name, the plugin silently stops loading — its hooks and agents stop working with no error. After marketplace auto-updates, verify `claude plugin list` output and check `~/.claude/plugins/installed_plugins.json` contains the expected key.
- **Inline hook commands: keep simple or use jq** — Inline `bash -c` hook commands in `settings.json.tmpl` have two layers of escaping (JSON `\"` + shell quoting) that are extremely error-prone. Avoid complex grep/sed patterns; use `jq` (already a dependency) or extract logic into external script files.
- **Verify GitHub Actions template output** — Workflows generated from templates (e.g., `claude-code-action`) default to read-only permissions. Posting comments requires `pull-requests: write` / `issues: write`. Do not use template output as-is — verify permissions match the intended use. See `~/.claude/rules/common/github-actions.md` for expression syntax constraints.
- **Never hardcode node/pnpm versions in CI** — All pnpm/node jobs in `lint.yml` must use `node-version-file: '.node-version'` and `packageManager` auto-detection. Direct `version:` or `node-version:` inputs are prohibited. Version sources: `.node-version` (node), `package.json` `packageManager` (pnpm).

## gstack

Use the `/browse` skill from gstack for **all web browsing**. Never use `mcp__claude-in-chrome__*` tools.

### Available Skills

`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`, `/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`, `/learn`
