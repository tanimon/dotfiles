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

**`dot_apm/apm.yml` + APM (microsoft/apm)** — Declarative manifest for MCP servers only (`dependencies.mcp`), deployed to `~/.apm/apm.yml`. Claude Code Skills/plugins were briefly unified into this same manifest (`dependencies.apm`) but that was reverted (see "Skill/plugin management via native Claude Code marketplace" below) — `dependencies.apm` no longer exists in `apm.yml`. `.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl` runs `apm install --global --target claude` only when `apm.yml`'s hash changes (a plain hash-gated `run_onchange_`, not `run_after_`) and writes MCP servers into the top-level `mcpServers` key of `~/.claude.json` (as of 2026-07-26 this was a symlink to `~/.claude/claude.json` — do not assume that topology still holds; verify before relying on either path, see the Known Pitfalls entry below). `--target claude` is required — omitting it makes `apm install --global` fan out to every "global-capable" runtime it detects (Gemini CLI, Kiro, etc.), not just Claude Code. Hash-gating is sufficient here (unlike the Skill-era `run_after_`) because `~/.claude.json` has no competing chezmoi-owned `.tmpl` that re-renders it every apply — see [run-after-vs-run-onchange-for-shared-config-ownership.md](docs/solutions/architecture-patterns/run-after-vs-run-onchange-for-shared-config-ownership.md) for the general criterion. chezmoi no longer manages `~/.claude/claude.json` directly — this replaced the earlier `modify_claude.json` (jq-based partial ownership) approach. Some plugins bring their own MCP servers independent of `dependencies.mcp` (e.g. `getsentry/plugin-claude`'s native-marketplace `sentry` plugin), so `dependencies.mcp` is only a subset of the MCP servers actually deployed — check the live `mcpServers` key, not just `apm.yml`, to see the full set. Running `apm install <pkg>` by hand appends the dependency straight to `~/.apm/apm.yml` (the deploy target, fully owned by chezmoi via `dot_apm/apm.yml`) and that edit is silently lost on the next `chezmoi apply` — always declare new dependencies in `dot_apm/apm.yml` instead. See `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md` for the original MCP+Skill unification design (Skill part since reverted).

**`dot_config/karabiner/modify_karabiner.json`** — Partial management of `~/.config/karabiner/karabiner.json`, mirroring the jq-based partial-ownership pattern formerly used by `dot_claude/modify_claude.json` (now removed in favor of APM; see above). Owns `profiles[*].complex_modifications.rules` only; preserves Karabiner's runtime state (`machine_specific` UUID, profile metadata, `virtual_hid_keyboard`, sibling `complex_modifications.parameters`, etc.) verbatim. The rules array lives at `dot_config/karabiner/complex_modifications.json` and is applied to *every* profile (V1 deliberately ignores per-profile rule divergence). Empty stdin (new-machine bootstrap before Karabiner has been launched) seeds a minimal profile shape with no fabricated `machine_specific`. First apply normalizes the file mode from Karabiner's `0600` to `0644`; Karabiner restores `0600` on next save. Smoke-tested by `just test-modify`.

**Skill/plugin management via native Claude Code marketplace** — Reverted from APM back to Claude Code's own plugin/marketplace mechanism (2026-08-10) to get per-plugin Skill namespacing (`plugin:skill` invocation names, e.g. `/commit-commands:commit`) — APM deploys all Skills flatly to `~/.claude/skills/<name>/SKILL.md` regardless of how the dependency is declared (git shorthand or marketplace form), so it can't provide this namespacing; only Claude Code's native plugin loader (which keeps each plugin's Skills under its own `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/`) does. `dot_claude/settings.json.tmpl` declares `enabledPlugins` (which plugins are on) and `extraKnownMarketplaces` (which marketplace repos are known) directly — both chezmoi-owned, declarative. There is deliberately **no automation** for marketplace registration: `extraKnownMarketplaces` alone does not fetch/clone a marketplace, so on a new machine you must run `claude plugin marketplace add <owner/repo>` once per marketplace listed in `extraKnownMarketplaces` before `enabledPlugins` entries can resolve — this manual step was accepted as a tradeoff for keeping the mechanism to a single file. Accepted risk: if a marketplace or plugin is renamed upstream, the `plugin@marketplace` key in `enabledPlugins` silently stops matching and the plugin stops loading with no error (see the Known Pitfalls entry below) — re-running is what surfaces it. `nono@nolabs-ai` is a special case: the nono pack registers its own marketplace as a local `directory` source (not a GitHub repo) as a side effect of `nono pull`/`nono update`, so it has no corresponding `extraKnownMarketplaces` entry — only the `enabledPlugins` flag is chezmoi-managed for it (see the comment above that key in `settings.json.tmpl`). MCP servers are unaffected by this reversion and remain on APM (`dot_apm/apm.yml`'s `dependencies.mcp`, see above).

**Declarative gh extension sync** — `dot_config/gh/extensions.txt` lists gh extensions (one `owner/repo` per line). `run_onchange_after_install-gh-extensions.sh.tmpl` installs them when the list changes. `scripts/update-gh-extensions.sh` regenerates the list from `gh extension list`. Same pattern as marketplace sync. Note: `gh extension list` is tab-delimited — use `awk -F'\t'` to parse.

**`run_onchange_` scripts** — Track file hashes in comments (e.g., `# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}`). They re-run only when the tracked content changes.

**リポジトリの場所ベースの gitignore 切り替え(includeIf)** — superpowers/ce 系スキル生成の経緯ドキュメント(`docs/{brainstorms,ideation,plans,residual-review-findings,superpowers}/`)は、仕事リポジトリではノイズになるため除外し、個人リポジトリでは開発経緯として commit したい。これを git の `includeIf "gitdir:..."` で場所単位に切り替える: デフォルトの `~/.gitignore`(`dot_gitignore.tmpl`)はこれらを除外し、`dot_gitconfig.tmpl` の `includeIf`(`~/ghq/github.com/tanimon/` と `~/.local/share/chezmoi/`)が `~/.config/git/personal.inc` 経由で `core.excludesfile` を `~/.gitignore_personal`(`dot_gitignore_personal.tmpl`、これらを除外しない版)に差し替える。共通部分は `.chezmoitemplates/gitignore-common` に一本化し、両 `.tmpl` が `{{ template "gitignore-common" }}` で取り込む(対象ブロック以外の重複管理を避けるため)。フェイルセーフはデフォルト除外側: 未登録の場所(仕事の新リポジトリ・OSS クローン)では commit されず、個人リポジトリの登録漏れの損害は「commit されない」だけで軽微。`gitdir` は worktree でも本体の `.git` 配下を指すため、`~/orca/workspaces/` 等に切った worktree にも本体側のルールが自動で効く。新しい個人開発の場所を増やしたら `includeIf` セクションを追記する。仕事リポジトリへの commit-then-delete(レビュー前削除)方式は検討のうえ不採用: gitignore されたファイルもローカルには存在し続けるので開発中の参照に commit は不要で、削除後も push 済みブランチの中間コミットには残り、削除忘れガードを仕事リポジトリの CI/フックに置くこともできないため。

**Identity leak guard(`scripts/scan-sensitive-info.sh`)** — このリポジトリは public なので、work 用 GitHub org 名とローカルアカウント名は git 管理下に置かない。ガードは 2 層で、1 層では両方の形を覆えない。

**(1) 形(shape)のパターン** — `sensitive-patterns.txt` に commit され、CI でも動く。識別子そのものを含まないので commit できる。
- `ghq/github\.com/[A-Za-z0-9._-]+` — `~/ghq/github.com/<literal>` のハードコードを検出し、`~/ghq/github.com/{{ .ghOrg }}/**`(正例は `dot_claude/settings.json.tmpl`)を強制する。
- `-Users-[A-Za-z][A-Za-z0-9.-]*--` — Claude Code のプロジェクトスラグ(`/Users/<user>/.local/share/chezmoi` → `-Users-<user>--local-share-chezmoi`。実際には `<user>` の位置に実アカウント名が入る)。`/` が消えるため既存の `/Users/...` パターンでは**構造的に捕まらない**。実際にこの形で実アカウント名が docs/ に残っていた。
- プレースホルダ(`{{ .ghOrg }}`、`<work-org>`、`-Users-<user>--`)はいずれも文字クラス外なので誤検知しない。

**(2) 識別子そのもの** — 散文中の言及(「<org> の worktree では…」)は形が無いので (1) では捕まらない。**リポジトリには書かず**、スキャン時にマシンから解決する: work org は `chezmoi data` の `.ghOrg`、アカウント名は `id -un`。それぞれ `SENSITIVE_WORK_ORG` / `SENSITIVE_LOCAL_USER` で上書き可(set-but-empty で無効化)。`id -un` が CI runner やコンテナの汎用アカウント名(`runner`/`node`/`root` 等)を返した場合は**識別子として扱わない** — これらは repo 内に普通の単語として頻出し、狩ると CI が無意味に赤くなる(実測で 14 行以上)。明示的な上書きは常に優先されるので、この除外が本当に守りたい名前を隠すことはない。マシンから引けない文字列(改名前のアカウント名や、システムが保持していない実名など)は gitignore 済みの `scripts/sensitive-patterns.local.txt` に書く — **その文字列はここに書けない**(書けば漏洩そのもの)ので、この CLAUDE.md も含め commit されるファイルには具体例を残さない。**このファイルは自己ブートストラップできない**(seed のために commit したら、それがまさに防ぎたい漏洩)ので、新しいマシンでは手で作り直す。

**出力の作法。** パターンは行頭 `@redact ` で出力モードを切り替える。redact は `file:line` だけを出力する — public リポの Actions ログにマッチ行を出すと、ガードが守っている文字列をガード自身が公開してしまうため。redaction は*マッチ内容*に対するもので、commit 済みパターン自体は既に公開なので**パターン名は出す** — これが「1行に2ガードが当たった」のか「別々の2件」なのかの区別になる。形を表すパターンは既定の show のまま(マッチ行が見えないと修正できない)。識別子が解決できないときは黙って exit 0 せず、**どの resolver がなぜ skip されたかを名前で**出す — 静かな pass は「clean」に見えるうえ、resolver が複数ある状態で「何かが skip された」だけでは片方だけ解決した実行を誤って説明してしまう。

**強制点。** CI は (1) だけを強制する(chezmoi 設定も実ユーザー名も無い)。(2) の強制点はローカルの pre-commit フックと `just lint`。意図的に公開している情報(公開済みの commit identity・SSH 公開鍵・このリポの公開アカウント名)は `scripts/sensitive-allowlist.txt` に `<path-suffix or *>:<regex>` 形式で例外登録する。識別子そのものはこのファイルに書けない(書けば漏洩そのもの)ことが設計上の制約。

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
| `dot_apm/` | APM (microsoft/apm) global manifest: `apm.yml` — declares MCP servers only (`dependencies.mcp`), deployed to `~/.apm/apm.yml`. Skills/plugins are managed via native Claude Code marketplace (`enabledPlugins`/`extraKnownMarketplaces` in `dot_claude/settings.json.tmpl`), not APM |
| `dot_config/nono/` | nono sandbox policy: `profiles/claude-seal.json` (the boundary), `packs.txt` (declarative pack list) |
| `scripts/` | Repo-only helper scripts (`update-brewfile.sh`, `update-gh-extensions.sh`) |
| `test/` | bats-core test suites — one `.bats` file per script under test, run via `just test-*` targets |
| `docs/solutions/` | Past problem resolutions — search here when encountering similar issues |
| `CONTEXT.md` | Shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts. Glossary format per mattpocock-skills' `CONTEXT-FORMAT.md`; see `docs/agents/domain.md` |
| `CONCEPTS.md` | **Deprecated** predecessor of `CONTEXT.md`. Read-only archive: keeps the longer background paragraphs that don't fit `CONTEXT-FORMAT.md`'s one-to-two-sentence limit. Never add new terms here |

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
just scan-sensitive            # Scan every file for PII, credentials, and literal work-org / account names
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
- **`docs/` is tracked** — Both `docs/plans/` and `docs/solutions/` are committed. Plan files created by `ce:plan` and solution documents are version-controlled. Ensure no PII or sensitive information is included — `just scan-sensitive` checks every file in the repo (see "Identity leak guard" above).
- **Do not judge `modify_*` files by extension** — `dot_config/karabiner/modify_karabiner.json` has a `.json` extension but is a bash script. Add `! -name 'modify_*'` exclusions to file-type-based linter/formatter globs (`*.json`, `*.yaml`, etc.). Also include `modify_` patterns in pre-commit excludes.
- **`~/.claude.json` topology has changed before and may change again — never assume, always check with `ls -la`/`file` before writing.** Writing back through a symlink target replaces it with a plain file (verified: `chezmoi apply -S <tmp> -D <tmp>` turned a `120755` symlink into a `100644` regular file) — so a future `modify_` script that assumes today's topology can silently break it. History: as of 2026-07-26 Claude Code's native install symlinked `~/.claude.json` to `~/.claude/claude.json`; a later check found it back to being a plain file with its own independent `mcpServers` key. Nothing in this repo manages either file directly (APM's `apm install --global` writes to whichever `~/.claude.json` resolves to at runtime). `~/.claude.json` stays in `.chezmoiignore` regardless of topology.
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
- **Plugin marketplace renames silently break `enabledPlugins`** — The ecc (everything-claude-code) plugin was renamed upstream more than once (`ecc` ↔ `everything-claude-code`). When the `plugin@marketplace` key in `settings.json.tmpl` no longer matched the marketplace's current plugin name, the plugin silently stopped loading — its hooks and agents stopped working with no error. This was the reason `enabledPlugins`/`extraKnownMarketplaces` were once removed entirely in favor of APM (2026-08-03), but the Skill/plugin management reverted back to `enabledPlugins`/`extraKnownMarketplaces` on 2026-08-10 to get per-plugin Skill namespacing (see "Skill/plugin management via native Claude Code marketplace" above) — this rename-breakage risk was explicitly re-accepted as a tradeoff, not overlooked. Verify with `claude plugin list` or `~/.claude/plugins/installed_plugins.json` that a `plugin@marketplace` key you expect to be active is actually present after any upstream rename.
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
- **(historical, superseded 2026-08-10) `run_after_` vs `run_onchange_` choice mattered when APM wrote hooks directly into `settings.json`** — no longer applicable now that Skill/plugin management is back on native `enabledPlugins`/`extraKnownMarketplaces` and `apm install` only touches MCP servers. Full history: [run-after-vs-run-onchange-for-shared-config-ownership.md](docs/solutions/architecture-patterns/run-after-vs-run-onchange-for-shared-config-ownership.md).
- **A nono user profile shadows a pack profile of the same name** — naming a local profile `claude-code` silently discards the pack's base grants. Use a distinct name (`claude-seal`) and `extends`.
- **MCP stdio servers do not pass through zsh wrapper functions** — `mcpServers` entries (declared in `dot_apm/apm.yml`, written into `~/.claude/claude.json` by APM) are exec'd directly, so the `codex()` wrapper's nested-sandbox handling does not apply to the codex MCP server. In this case nothing was needed (nesting does not break the stdio server — it connected in 89 ms inside nono, and `codex mcp-server` accepts no `--sandbox` flag at all; only *interactive* codex needs `--sandbox danger-full-access`), but for a server that does need a nested-sandbox flag it must go in `args` or a shim script.
- **Verify Homebrew formula names before uninstalling** — the formula for safehouse was `agent-safehouse`, not `safehouse`; `brew uninstall safehouse` silently no-ops and leaves the tool installed. Confirm with `brew list | grep <name>` after any removal.
- **`.chezmoiremove` with `path/**` can break `chezmoi apply` outright** — a leftover Unix socket under a directory removed via the `path/**` convention produced `unsupported file type socket` and exit 1. Bare directory entries (no `/**`) worked.

## gstack

Use the `/browse` skill from gstack for **all web browsing**. Never use `mcp__claude-in-chrome__*` tools.

### Available Skills

`/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/design-shotgun`, `/design-html`, `/review`, `/ship`, `/land-and-deploy`, `/canary`, `/benchmark`, `/browse`, `/connect-chrome`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/setup-deploy`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/cso`, `/autoplan`, `/plan-devex-review`, `/devex-review`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`, `/learn`

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (`tanimon/dotfiles`, via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. `triage` does not create labels itself — see the creation commands in `docs/agents/triage-labels.md`.

### Domain docs

Single-context, on mattpocock-skills' default layout: the glossary is `CONTEXT.md` (`CONCEPTS.md` is its deprecated predecessor, kept as a read-only archive) and ADRs live in `docs/adr/` — distinct from `docs/solutions/`, which records past breakages rather than decisions. See `docs/agents/domain.md`.
