<!-- 自動生成 — 直接編集しないこと。Source: harness/modules/ + harness/project.json。再生成: just harness-sync / 検査: just check-instructions -->

# AGENTS.md

This file provides guidance to agents other than Claude Code — Codex and Cursor both read `AGENTS.md` from the project root — when working with code in this repository. The shared sections are identical to what Claude Code receives via `CLAUDE.md` — both files are generated from the same Content Modules under `harness/modules/` — and each file additionally carries one section that applies only to its own readers.

## Notes for non-Claude agents

This section comes first deliberately: **Codex truncates this file at `project_doc_max_bytes` (default 32 KiB)** and the file is larger than that, so anything placed at the end would be dropped without a warning. Verified with `codex debug prompt-input` on 2026-09-12 (codex 0.147.0): the tail was missing by default and present with `codex -c project_doc_max_bytes=200000`. Consequences you should know about:

- **What you are missing is the tail of "Key Patterns".** The module order for this file is chosen so that every other section — Common Commands, Architecture, Verification, Known Pitfalls, Agent docs — fits inside the limit, and the cut lands inside the single "Key Patterns" section, which is last. If you need the rationale behind a chezmoi mechanism and cannot find it here, read `harness/modules/project/35-key-patterns.md` from the repository root; it is never truncated. (Markdown links inside the module files are written relative to the repository root, not to the module's own directory, because the modules are composed into files that live at the root — resolve them from there.)
- **One rule from that truncated tail still binds you, so it is stated here rather than only referenced.** This repository is **public**. Never commit the work GitHub org name or a local account name: write `{{ .ghOrg }}` in templates and a placeholder such as `<user>` in prose. `just scan-sensitive` enforces this before every commit and in CI. Elsewhere in this file, "Known Pitfalls" points at **"Identity leak guard" above** for the reasoning — that section is in the part you do not receive; read it in `harness/modules/project/35-key-patterns.md` if you need it.
- To load the whole file in one session: `codex -c project_doc_max_bytes=200000`. Setting it permanently means editing `~/.codex/config.toml`, which this repository manages only in part: APM writes the `[mcp_servers.*]` tables there (`dot_apm/apm.yml`, see `docs/adr/0006-apm-owns-only-the-mcp-servers-table-of-codex-config.md`) and everything else in that file — `project_doc_max_bytes` included — is yours to set by hand and is never overwritten.
- Cursor reads this file too. Whether Cursor applies a size limit of its own has not been verified.

The rest of this section records what does **not** apply to you, because the repository also configures Claude Code and it is easy to mistake its machinery for repository-wide instructions.

- **Claude Code slash commands do not exist here.** `/harness-reflect`, `/harness-review` and similar are Claude Code entry points. Use the `just` recipes (`just lint`, `just harness-sync`, `just check-instructions`) and the documents under `docs/` directly.
- **`~/.claude/` is a deploy target, not your configuration.** Paths under `~/.claude/` are described below because this repository generates them from `dot_claude/`. They are not where your own settings live, and editing them does not change your behavior.
- **The nono wrapper is on Claude Code's launch path only.** `dot_config/zsh/sandbox.zsh` wraps the `claude` command. Whatever isolation you run under is configured by your own product, not by this repository. Do not assume the grants in `dot_config/nono/profiles/claude-seal.json` apply to you.
- **Global instructions are out of scope for this file.** `AGENTS.md` here covers this repository only. Your user-global instructions live in `~/.codex/AGENTS.md`, which chezmoi generates from the same shared body as Claude Code's `~/.claude/CLAUDE.md` (`.chezmoitemplates/agent-instructions-common` via `dot_codex/AGENTS.md.tmpl`) — a separate mechanism from this file, which comes from `harness/`.

## What This Is

A chezmoi-managed dotfiles repository for macOS. Source directory is `~/.local/share/chezmoi/`, targeting `~/` as the destination. Managed configs include shell (zsh, starship, sheldon), editor (vim, helix), terminal (ghostty, tmux, zellij), git, Claude Code (`~/.claude/`), dev tools (mise, gh, yazi), and macOS packages (Brewfile).

## Common Commands

`chezmoi --help` covers the everyday subcommands (`apply`, `diff`, `add`, `edit`, `managed`, `data`). The ones below are not guessable from a tool's own help:

```sh
# Linting (mirrors CI — also runs on commit via prek; requires `just`, installed via darwin/Brewfile)
just lint                      # Run all checks; `just --list` shows the individual recipes
pnpm exec secretlint '**/*'   # Scan for leaked secrets only

# Branch / PR context — replaces the fetch + merge-base + diff --stat + gh pr view chain.
# Never touches the worktree, the index, HEAD, or branch state (git fetch updates remote-tracking refs)
bash scripts/pr-context.sh [<base>]   # base defaults to origin/main; PR_CONTEXT_SKIP_FETCH=1 when offline

# Agent instructions (CLAUDE.md / AGENTS.md / .cursor/rules are GENERATED — see below)
just harness-sync              # Regenerate them from harness/modules/ + harness/project.json
just check-instructions        # Fail if a generated file was hand-edited (drift)

# Security alerts (scheduled weekly in CI, also manual)
gh workflow run security-alerts.yml  # Trigger security alert sweep manually
```

## Architecture

### `.chezmoiexternal.toml`

Pulls external archives into the managed tree with auto-refresh. Current entries are the 4 ECC (affaan-m/ECC) pulls — the `ecc-code-review` command, 4 agents, `rules/typescript`, `rules/web` — all pinned to the same SHA (design: `docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md`); gstack skills were removed on 2026-09-24 by `/doctor`. Each entry uses `type = "archive"` (or `archive-file`) with the commit SHA embedded in the GitHub archive URL for supply-chain safety, and Renovate auto-updates these SHAs — see `.claude/rules/renovate-external.md` for the adjacency contract that must be preserved when adding one.

### Directory Layout

Only directories whose contents carry a contract an `ls` would not reveal are listed. `darwin/`, `windows/`, `scripts/`, and `test/` hold exactly what their names say; all four are repo-only (`.chezmoiignore`d, never deployed to `~/`).

| Directory | Purpose |
|-----------|---------|
| `.chezmoiscripts/` | All `run_onchange_` scripts live here (not in the source tree root) |
| `dot_claude/` | Claude Code config (`~/.claude/`): settings (`settings.json.tmpl`), rules, plugins, scripts (hooks), skills, keybindings |
| `dot_apm/` | APM (microsoft/apm) global manifest `apm.yml` — declares MCP servers only, deployed to `~/.apm/apm.yml`. Operating contract in `dot_apm/CLAUDE.md` |
| `dot_config/nono/` | nono sandbox policy: `profiles/claude-seal.json` (the boundary), `packs.txt` (declarative pack list) |
| `.cursor/rules/` | 生成される Cursor の Project Rule(`.mdc`)。chezmoi からは不可視(source 直下の `.` 始まりは `.chezmoi*` を除き source state に入らない)なので `.chezmoiignore` の記載は不要 |
| `CONTEXT.md` | Shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts. Glossary format per mattpocock-skills' `CONTEXT-FORMAT.md`; see `docs/agents/domain.md` |
| `CONCEPTS.md` | **Deprecated** predecessor of `CONTEXT.md`. Read-only archive: keeps the longer background paragraphs that don't fit `CONTEXT-FORMAT.md`'s one-to-two-sentence limit — **read the relevant section before deciding on permission rules, boundary exclusions, verification design, or `modify_` partial ownership** (inventory in `docs/agents/domain.md`). Never add new terms here |

## Verification

```sh
just lint                      # Run ALL checks locally (mirrors CI)
chezmoi apply --dry-run        # Preview changes before applying
```

`just --list` enumerates the individual recipes with their descriptions — do not maintain a copy of that list here, it drifts. Every recipe `lint` depends on is also a CI job except `test-nono-profile` (CI does not install nono) and `test-nono-packs` (the template it renders is darwin-only; CI runs on ubuntu), so local is a superset: green locally means green in CI, not the other way round.

Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). For similar past issues, search `docs/solutions/`.

検証コマンドは手で組まない。`shellcheck -x <files>` や `shfmt -i 4 -d <files>` を並べず `just lint` か個別レシピを呼ぶ — 手組みは対象の漏れや `-i 4` の落としで CI と静かにずれる。ブランチ / PR の状態も同じ理由で `bash scripts/pr-context.sh` を使う。

## Known Pitfalls

### chezmoi CLI & File Management

- **`chezmoi add --autotemplate` breaks JSON** — `:` and `/` get over-substituted. Use `chezmoi add --template` + manual `sed` for homeDir substitution instead.
- **`run_after_` scripts calling `chezmoi add` cause recursion** — Use `cp` + `sed` to write directly to the source directory.
- **`.chezmoiignore` silently skips** — If `chezmoi add` does nothing, check `.chezmoiignore`.
- **`.chezmoiignore` `*.txt` is root-level only** — `*.txt` does NOT match nested paths like `.config/gh/extensions.txt`. Use `**/*.txt` for recursive matching, or add explicit entries for nested files. Always verify with `chezmoi managed | grep <pattern>`.
- **Repo-only files need `.chezmoiignore`** — Files like `CLAUDE.md`, `README.md` at repo root are excluded via `.chezmoiignore` so they don't deploy to `~/`. New repo-only files must be added there.
- **`.chezmoiignore` bare filenames match target paths** — `.chezmoiignore` evaluates target paths, not source filenames. Adding `.gitignore` blocks `dot_gitignore` → `~/.gitignore` deployment because the target path is `.gitignore`. Likewise, non-prefixed source files (`README.md`, `LICENSE`) are still managed and need explicit entries to stay out of `~/`. `dot_` / `private_` are name-mapping conventions, not a gate on whether chezmoi treats a file as a source.
- **Choosing chezmoi file patterns** — Regular `.tmpl` for fully-owned files. `create_` for provision-once. `modify_` for runtime-mutable files (IDE configs). `.chezmoiignore` to exclude entirely. For files modified by external tools (plugins), prefer `.chezmoiignore` + declarative `run_onchange_` scripts over bidirectional sync.
- **`CLAUDE.md`, `AGENTS.md`, and `.cursor/rules/*.mdc` are generated — never edit them directly** — Their Source is `harness/modules/` plus `harness/project.json`. Edit the module, then run `just harness-sync`. A hand edit survives locally but `just check-instructions` (part of `just lint` and CI) fails with `DRIFT target <path>`, and the next `harness sync` overwrites it. To find which module owns a passage, grep `harness/modules/`. Shared repository facts go in `harness/modules/project/`; product-specific operating instructions go in `harness/modules/runtime/`.
- **ルート合成モジュールから nested `CLAUDE.md` へ段落を移すときはリンクを書き換える** — `harness/modules/` 内の Markdown リンクはルートに合成される前提でリポジトリルート相対に書かれている。`dot_apm/CLAUDE.md` 等へ移すと `docs/…` が `dot_apm/docs/…` を指して壊れる(2026-09-24 の Check 4 移行で実際に発生)。`../` を付け直すこと。`just lint` にリンクチェッカーは無く検出されない。
- **Never edit deployed targets directly** — Always edit the chezmoi source file (under `~/.local/share/chezmoi/`), never the deployed target under `~/`: changes there are overwritten on the next `chezmoi apply` and are not version-controlled. `chezmoi source-path <target>` finds the source file for any managed target.
- **`docs/` is tracked** — Both `docs/plans/` and `docs/solutions/` are committed. Plan files created by `ce:plan` and solution documents are version-controlled. Ensure no PII or sensitive information is included — `just scan-sensitive` checks every file in the repo (see "Identity leak guard" above).
- **Do not judge `modify_*` files by extension** — `dot_config/karabiner/modify_karabiner.json` has a `.json` extension but is a bash script. Add `! -name 'modify_*'` exclusions to file-type-based linter/formatter globs (`*.json`, `*.yaml`, etc.). Also include `modify_` patterns in pre-commit excludes.
- **`~/.claude.json` topology has changed before and may change again — never assume, always check with `ls -la`/`file` before writing.** Writing back through a symlink target replaces it with a plain file, so a `modify_` script that assumes today's topology can silently break it. Nothing in this repo manages either file directly, and `.chezmoiignore` excludes **both** paths regardless of topology. **その symlink を張っているのは nono**(2026-09-24 に一次証拠で確定)で、`nono run --profile claude-seal` のたびに張り直すため、手で消しても次の nono 起動で戻る。APM は追加(configure)時に symlink を平のファイルに潰し(split-brain)、0.30.0 の prune 時は symlink を拒否して install 全体を失敗させるので、**`apm install --global` は素で叩かず `bash scripts/apm-install-global.sh` を使う**(`.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl` もこれを呼ぶ)。**手で de-link したときは、戻す `mv` の前に `[ ! -e ~/.claude/claude.json ]` を必ず確認する** — 怠ると、de-link 中に nono が復活させた実体を symlink で上書きして設定を失う(2026-09-24 に実際に起きた。回帰テストは `test/apm-install-global.bats`)。一次証拠・対比ペアの実測・事故の経緯は `dot_apm/CLAUDE.md` の「`~/.claude.json` symlink と APM」節に移してある。
- **その 2 パスはどちらも消せない** — 両パスがそれぞれなぜ必要かと測定手順は [chezmoi-modify-script-symlink-target.md](docs/solutions/integration-issues/chezmoi-modify-script-symlink-target.md) の追記節。
- **`chezmoi apply` deploys from `main`, not from your branch** — The chezmoi source directory `~/.local/share/chezmoi` is a *separate git worktree pinned to `main`*; feature work happens in sibling worktrees (`~/orca/workspaces/chezmoi/<name>`). `chezmoi diff` and `chezmoi apply` therefore read `main`'s templates and show **nothing** for unmerged branch changes — which reads as "no drift", not as "wrong source". Verify branch changes by rendering instead (`chezmoi execute-template --config <test toml> --source "$(pwd)"`), and deploy only after the branch merges (`git -C ~/.local/share/chezmoi rev-parse --abbrev-ref HEAD` confirms which branch the source is on). The same `--source "$(pwd)"` requirement applies to *every* chezmoi command that reads source state (`managed`, `ignored`, `diff`, `apply`). The check passes *vacuously* — see [verification through the wrong resolution path](docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md).

### Template Syntax

- **Template escaping** — To output literal `{{ .chezmoi.homeDir }}` in a `.tmpl` file, use `{{ "{{ .chezmoi.homeDir }}" }}`.
- **`chezmoi execute-template` in CI needs config + source** — `--init --promptString` only answers `promptStringOnce` prompts; it does NOT populate the `.data` namespace (`.ghOrg`, `.profile`) that templates reference. Use a test `chezmoi.toml` with `[data]` section and pass `--config <path> --source "$(pwd)"`. Also exclude `.chezmoi.toml.tmpl` itself since it uses `promptStringOnce` (interactive).
- **`chezmoi diff`/`apply` from a secondary worktree needs `--source`** — chezmoi resolves its source directory from its own config (`~/.local/share/chezmoi`), not from the current directory. Running bare `chezmoi diff` inside a git worktree of this repo therefore compares against the *main* worktree's sources and silently omits the branch's changes — a false negative that reads as "no drift". Always pass `--source "$(pwd)"` when verifying template changes from a worktree.
- **`scripts/update-brewfile.sh` regenerates the whole Brewfile, drift included** — it runs `brew bundle dump --force`, so its diff is "this machine's current state" and not "the one package you just installed" — on a machine with packages installed outside chezmoi that is a ~100-line diff of unrelated taps/casks/mas apps. To add a single package, hand-add the one `brew "..."` line in alphabetical position, note in the commit that the file is no longer a faithful dump, and reconcile the accumulated drift as its own separate change. Verify with `git diff --stat darwin/Brewfile` that exactly one line was added and none removed.

### Script Safety

- **`modify_` scripts: empty stdout = target deletion** — Never use OS guards (`{{ if eq .chezmoi.os "darwin" }}`); on non-matching OS the script outputs nothing and chezmoi zeros the file. Always include `set -e`. Use `printf '%s\n'` (not `printf '%s'`) to preserve trailing newlines stripped by `$(cat)`.
- **Hook scripts: set one-shot flags after guards, not before** — When using `/tmp` flag files for "run once per session" behavior, place the `touch` **after** context guards (directory exclusions, git checks), not before. If the flag is set before guards, a non-project context (e.g., `$HOME`) consumes the one-shot flag, and navigating to a project later in the same session silently skips the hook.

### External Constraints & Tool Integration

- **Git commit signing** — 対話ターミナルの `~/.gitconfig` は 1Password SSH agent(`op-ssh-sign`)で署名するので、1Password が動いていないと commit が失敗する。**Claude Code の git は別**: `dot_config/git/claude-code.inc`(`GIT_CONFIG_GLOBAL` 経由)が `user.signingkey` を `~/.config/git/signing/ai-agent`(`run_onchange_generate-ai-agent-signing-key.sh.tmpl` が生成するパスフレーズ無しのローカル鍵。鍵が消えると次の `chezmoi apply` で再生成される)、`gpg.ssh.program` を `/usr/bin/ssh-keygen` に上書きするため、1Password のロック状態に依存せず人間不在でも署名が通る。公開鍵を GitHub に **signing key として登録**するのは人手ステップで、未登録だと Unverified になり `required_signatures` ルールのあるリポジトリ(このリポジトリを含む)ではマージできない。鍵を `~/.ssh` 外に置く理由を含む詳細は `claude-code.inc` のコメントと `dot_config/nono/CLAUDE.md` の署名段落。
- **Plugin marketplace renames silently break `enabledPlugins`** — When the `plugin@marketplace` key in `settings.json.tmpl` stops matching the marketplace's current plugin name (the since-removed ecc plugin was renamed upstream more than once, `ecc` ↔ `everything-claude-code`), the plugin silently stops loading — its hooks and agents stop working with no error. This is an accepted tradeoff of the native-marketplace approach (see "Skill/plugin management via native Claude Code marketplace"). After any upstream rename, verify with `claude plugin list` or `~/.claude/plugins/installed_plugins.json` that the `plugin@marketplace` key you expect is actually present.
- **Inline hook commands: keep simple or use jq** — Inline `bash -c` hook commands in `settings.json.tmpl` have two layers of escaping (JSON `\"` + shell quoting) that are extremely error-prone. Avoid complex grep/sed patterns; use `jq` (already a dependency) or extract logic into external script files.
- **`git diff | grep '^[+-]'` verifies nothing here** — `diff.external = difft` (difftastic) is configured globally, so `git diff` emits no `+`/`-` line prefixes. Any verification that pipes `git diff` into a `^[+-]` grep matches zero lines and therefore *looks like it passed* while checking nothing. Use `git diff --no-ext-diff` when a command needs unified output; `git diff --stat`, `git show --stat`, and `chezmoi diff` are unaffected. Same species as the chezmoi-source pitfall above — see [verification through the wrong resolution path](docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md).
- **Moving an entry out of `permissions.ask` widens more than the `deny` prefixes catch** — Permission rules are prefix matches, so a narrow `deny` such as `Bash(git push --force:*)` only fires when the flag immediately follows the command; `git push origin main --force` and `git push origin +main` match no `deny` entry at all. Before moving any entry out of `ask`, enumerate the argument spellings the remaining `deny` rules do **not** match. If write intent can migrate into a flag position, the entry stays in `ask` **unless a third channel enforces it**; a narrow `deny` is not a substitute for a broad `ask`. See the Tier 1 enforceability requirement in `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`.
- **A `PreToolUse` フックは rule syntax で表現できない判定の受け皿になる(ただし Tier 1 ではない)** — 上の pitfall の出口は「ask に残す」だけではない。フックはコマンド文字列全体を受け取るので、引数位置に依存しない判定が書ける(2026-09-16 に `Bash(git push:*)` を `ask` から外し、`executable_git-push-guard.sh` で塞いだのがこの形)。ただしこれは Tier 1 への昇格ではなく **hook-enforced** という別枠で、外す前に次の 3 点を設計判断として明記すること: (1) 未配置・未配線・クラッシュ時は無出力=判定なしで**フェイルオープン**する(rule は常に評価される)ため、最も一般的な綴りの `deny` 行は多層防御として残す。(2) 判定はスクリプトの語彙走査に依存するので、alias・シェル関数・`eval` / `bash -c` の内側・`gh api` 経由の等価操作は素通りする。(3) **認識器そのものがフェイルオープンする形に注意** — 読み切れない入力を `ask` に倒す判定が「認識に成功したセグメント」の内側にしか無いと、認識が外れた瞬間に保険ごと無効になる(初版は `for r in …; do git push $r --force; done` が無出力だった)。認識の失敗自体を fail-closed に落とす経路を必ず用意する。実装の要点と実測は `dot_claude/scripts/CLAUDE.md` の「git push guard hook」、設計は `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` の 2026-09-16 addendum。
- **Verify GitHub Actions template output** — Workflows generated from templates (e.g., `claude-code-action`) default to read-only permissions. Posting comments requires `pull-requests: write` / `issues: write`. Do not use template output as-is — verify permissions match the intended use. See `dot_claude/rules/common/github-actions.md` (deployed to `~/.claude/rules/`) for expression syntax constraints.
- **Never hardcode node/pnpm versions in CI** — All pnpm/node jobs in `lint.yml` must use `node-version-file: '.node-version'` and `packageManager` auto-detection. Direct `version:` or `node-version:` inputs are prohibited. Version sources: `.node-version` (node), `package.json` `packageManager` (pnpm).

### nono Sandbox

- **nono profiles must not be chezmoi templates** — nono expands `$HOME`, `$XDG_CONFIG_HOME`, `$WORKDIR`, `$TMPDIR`, `$NONO_CONFIG`, and `$NONO_PACKAGES` itself. Writing `{{ .chezmoi.homeDir }}` works but forfeits `just oxfmt` JSON validation and `nono profile validate`. Keep profiles as plain JSON with **no comments** (both oxfmt and nono reject JSONC).
- **`nono run` needs `--allow-cwd`** — `workdir.access` sets the access *level*, not the grant. Without the flag the working directory is denied outright (`Sandbox denial: … (read)`) and nono falls back to an interactive prompt a non-interactive run cannot answer. Any wrapper must pass it, or stay inside a directory the profile already grants (e.g. `~/ghq`).
- **`filesystem.bypass_protection` grants nothing on its own** — it only lifts a deny-group rule. The path must *also* appear in `filesystem.allow` / `read` / `write` (or a `*_file` variant) to become accessible; listing it in `bypass_protection` alone silently changes nothing. The shipped profile pairs both for the shell rc files blocked by the required `deny_shell_configs` group. Note it was **not** the answer for the 1Password socket — see `filesystem.unix_socket`.
- **`filesystem.deny` does not override `filesystem.write`** — tested by adding the paths to `deny`: the profile validates and they stay `ALLOWED / Granted by: <the write grant>`. A carve-out inside a granted directory is **not expressible within `filesystem`** — there, the only way to narrow is to grant less. (`command_policies.commands.<name>.fs_write` is a separate mechanism that can scope one tool's writes; see `dot_config/nono/CLAUDE.md`.)
- **`nono why --host X --port 22` falsely reports ALLOWED** — `nono why` models the HTTP(S) proxy allowlist and nothing else, so it does not see the raw-TCP restriction. Any `nono why` host result is valid for HTTP(S) only. For anything else, probe the real connection.
- **`nono profile validate` rejects unknown keys** as a hard parse error, but `nono profile schema` output is **incomplete** (its `FilesystemConfig` omits all six `unix_socket*` keys the parser itself accepts). Trust the parser error over the emitted schema.
- **A nono user profile shadows a pack profile of the same name** — naming a local profile `claude-code` silently discards the pack's base grants. Use a distinct name (`claude-seal`) and `extends`.
- **MCP stdio servers do not pass through zsh wrapper functions** — MCP entries (declared in `dot_apm/apm.yml`, written by APM into `~/.claude.json`'s `mcpServers` and `~/.codex/config.toml`'s `[mcp_servers.*]`) are exec'd directly, so a `foo()` wrapper defined in `dot_config/zsh/` never runs for a server whose `command` is `foo`. Measured on the since-removed `codex` MCP server, where nothing was needed anyway (nesting does not break the stdio server; only *interactive* codex needs `--sandbox danger-full-access`). For a server that *does* need a wrapper's behaviour, the flag must go in `args` or the command must point at a shim script.
- **APM's MCP ownership boundary is the lock, not authorship** — dropping a server from `dot_apm/apm.yml` prunes that name from every active target including hand-written entries, and a changed definition is never updated in place (`already configured`, no error; #349). Both behaviours, their measurements and the workaround are in `docs/adr/0006-apm-owns-only-the-mcp-servers-table-of-codex-config.md`; never hand-add a server under a name `apm.yml` also uses.
- **Verify Homebrew formula names before uninstalling** — the formula for safehouse was `agent-safehouse`, not `safehouse`; `brew uninstall safehouse` silently no-ops and leaves the tool installed. Confirm with `brew list | grep <name>` after any removal.
- **`.chezmoiremove` with `path/**` can break `chezmoi apply` outright** — a leftover Unix socket under a directory removed via the `path/**` convention produced `unsupported file type socket` and exit 1. Bare directory entries (no `/**`) worked.

## Agent docs

### Issue tracker

Issues live in this repo's GitHub Issues (`tanimon/dotfiles`, via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. `triage` does not create labels itself — see the creation commands in `docs/agents/triage-labels.md`.

### Domain docs

Single-context, on mattpocock-skills' default layout: the glossary is `CONTEXT.md` (`CONCEPTS.md` is its deprecated predecessor, kept as a read-only archive) and ADRs live in `docs/adr/` — distinct from `docs/solutions/`, which records past breakages rather than decisions. See `docs/agents/domain.md`.

### Key Patterns

**`dot_apm/apm.yml` + APM (microsoft/apm)** — MCP サーバーだけを宣言する APM のグローバル manifest(`~/.apm/apm.yml` に配置)。Skills / plugins は APM ではなく Claude Code ネイティブの marketplace で管理する(次項)。ターゲットの二重宣言・APM の所有境界・`~/.claude.json` symlink との関係・手動 `apm install` が apply で消える点など運用上の契約は `dot_apm/CLAUDE.md`(`dot_apm/` 配下の作業時に読み込まれる)にまとめてある。

**`dot_config/karabiner/modify_karabiner.json`** — `~/.config/karabiner/karabiner.json` の `profiles[*].complex_modifications.rules` だけを所有する部分管理(`modify_` スクリプト。ルールの実体は `complex_modifications.json`)。所有範囲・空 stdin の扱い・ファイルモードの挙動は `dot_config/karabiner/CLAUDE.md`(`dot_config/karabiner/` 配下の作業時に読み込まれる)にまとめてある。Smoke-tested by `just test-modify`.

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

**Worktree seeding hook** — `dot_claude/scripts/executable_worktree-include.sh` runs at `SessionStart` and copies the files a repo's `.worktreeinclude` lists from the main worktree into the linked worktree, filling the gap left when a worktree is created by anything other than `gtr new` (orca, plain `git worktree add`). Copy-if-absent, never overwrite. See `dot_claude/scripts/CLAUDE.md` for the full detail (why not `git gtr copy`, the deliberate leading-`/` divergence from gtr, pattern semantics).

**git push guard hook** — `dot_claude/scripts/executable_git-push-guard.sh` は `PreToolUse`(`matcher: "Bash"`)で走り、`git push` の破壊的な綴り(force / delete / mirror / prune / `+refspec` / `:branch`)を**引数位置に関係なく** `deny` する。素の push は無出力 exit 0 で `defaultMode: auto` のクラシファイア判定に落ちるため、日常の push はプロンプトが出ない。これは `Bash(git push:*)` を `permissions.ask` に置いていた構成(毎回プロンプト = 承認疲れ)の置き換えで、prefix 照合では表現できない判定をフックへ逃がしたもの。読み切れない引数(変数・コマンド置換、`push` / `mirror` に触れる `-c` 上書き、`git` が認識できない位置にあるセグメント)は fail-closed で `ask`。詳細と残存リスクは `dot_claude/scripts/CLAUDE.md` と `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` の addendum を参照。

**curl localhost guard hook** — `dot_claude/scripts/executable_curl-localhost-guard.sh` は `PreToolUse`(`matcher: "Bash"`)で走り、宛先がすべてループバック(`localhost` / `127.0.0.0/8` / `[::1]`)の `curl` だけを `allow` で通す。それ以外は無出力で、`permissions.ask` に**残してある** `Bash(curl:*)` が従来どおりプロンプトを出す。**向きが git push guard と逆である点が要点**: あちらは `ask` を外した穴をフックで塞ぐのでフックが死ぬとフェイルオープンするが、こちらは `ask` を土台にフックが緩める側なので、未配置・クラッシュ・`jq` 不在・読み切れない綴りのいずれでもフェイルクローズ(= プロンプト)になり、`deny` 側に多層防御の床を置く必要がない。フックの `allow` が `ask` を上書きできることは対照ペアで実測済み。認識は全階層がホワイトリスト(フラグ・パイプ先・URL スキーム・ホスト)で、`--resolve` / `--connect-to` / `-x` / `-K` / `--next` / `--unix-socket` / `-L`(リダイレクトで curl 自身が外へ出る)、userinfo 形(`http://localhost@evil.example/`)、`$`・バッククォート、引用符の外の `{}` / `*` / `?` / `[`(シェルの展開で引数の個数が変わり、cwd のファイル名が curl の URL になる。`?` / `[` だけは「そのトークン自身がループバック URL で authority に glob が無い」場合に限り通すので、`…/api?a=1` と `[::1]` は従来どおり動く)、`| sh` はいずれも通さない。curlrc(`$CURL_HOME` / `$XDG_CONFIG_HOME` / `$HOME`)が存在する場合も、`proxy = …` 1 行で宛先が振り替わるため無出力にする。`0.0.0.0` と `host.docker.internal` は意図的に対象外、`wget` も対象外。残存: ループバックのリスナーは外部への中継になりうるが、`Bash(python3:*)` が既に `allow` にあり同じソケットを開けるため新たな到達性は増えない(`-o` による任意パス書き込みも同じ論法で受容。ただし glob は宛先チェックそのものを破るため受容せず拒否する)。詳細は `dot_claude/scripts/CLAUDE.md`。

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
`~/.claude/harness/pending.jsonl` — deterministic, no LLM. Claude Code's `/harness-reflect`
slash command extracts learnings from the current session and pending transcripts into
`~/.claude/harness/queue.md`. Claude Code's `/harness-review` (nudged by the SessionStart briefing when
overdue >7 days) runs `harness-doctor.sh`, triages the queue against existing rules, and
opens one PR per run; humans review and merge — no auto-apply. Runtime state in
`~/.claude/harness/` is chezmoi-ignored; only rule changes are version-controlled. All
monitoring is deterministic shell — the briefing prints a status line every session, so
silence itself signals a dead hook. Design:
`docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`.

**Harness sync seam (`harness/`)** — Claude Code / Codex / Cursor / APM の harness 設定を Harness Manifest から検証・同期する repo-only ツール(#308 の基盤、#309)。`bash harness/bin/harness.sh check` が runtime の Capability Probe と Target の drift を報告し、`sync` が Atomic Sync(staging → 全体検証 → 置換)で Target を更新する。`--no-probe` を付けると Capability Probe を飛ばして Target の drift だけを見る(製品が入っていない CI 用。省略したことは出力に必ず出る)。`init` / `update` は未実装(#322 / #323)。`harness/` は `.chezmoiignore` で除外され `~/` には配置されない。manifest は 2 つある: `harness/manifest.json` はグローバル用で **runtime 宣言のみ、`targets` は空のまま**(グローバル指示は harness ではなく chezmoi テンプレートが合成する。下の「Global agent instructions」と ADR 0005 を参照)、`harness/project.json` はこのリポジトリを Managed Project として扱うもので、下の「Generated agent instructions」の 3 Target を持つ。adapter は `harness/adapters/<owner>.sh render <staging-file> <target-json>` の契約で追加する。設計: `docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md`

**Generated agent instructions (`CLAUDE.md` / `AGENTS.md` / `.cursor/rules/dotfiles.mdc`)** — この 3 ファイルは**生成物**であり、直接編集してはいけない。Source は `harness/modules/` の Content Module 群で、`harness/project.json` が「どの Target がどのモジュールを、どの順で持つか」を宣言する。`just harness-sync` で再生成し、`just check-instructions`(`just lint` と CI に組み込み済み)が手編集を drift として検出する。分割の原則は **「このリポジトリについての事実」= `harness/modules/project/` の共有モジュール / 「あなた(この製品)がここでどう動くか」= `harness/modules/runtime/` の Runtime Extension**。`dot_claude/` や `~/.claude/` への言及も、リポジトリの中身の説明であるかぎり共有側に置く(Codex がこのリポジトリを編集するのに必要な事実だから)。Cursor は project root の `AGENTS.md` をネイティブに読むので、`.cursor/rules/dotfiles.mdc` には Cursor 固有の記述だけを置き、共有内容を二重にロードさせない(`docs/adr/0004-cursor-project-instructions-via-agents-md.md`)。**Codex は `AGENTS.md` を `project_doc_max_bytes`(既定 32 KiB)で黙って切り捨てる**(`codex debug prompt-input` で実測)。生成後の `AGENTS.md` は 32 KiB を超えるので、`AGENTS.md` の `modules` だけ順序が違う: Runtime Extension を先頭に置き、この「Key Patterns」モジュールを末尾に置いて、**切り捨てが 1 つの宣言されたモジュールの内側で起きる**ようにしてある。並びを変えるときはこの不変条件を壊さないこと(`test/harness-instructions.bats` が強制する)。設計: `docs/superpowers/specs/2026-09-12-project-instruction-sync-design.md`

**Global agent instructions (`~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`)** — リポジトリ内の指示(上の「Generated agent instructions」)とは合成の機構が違う。**グローバル指示は `harness/` を通らず、chezmoi テンプレートだけで合成する**(ADR 0005。`harness/manifest.json` の `targets` は空のまま)。共有本文は `.chezmoitemplates/agent-instructions-common` に 1 箇所だけ置き、`dot_claude/CLAUDE.md.tmpl` と `dot_codex/AGENTS.md.tmpl` が `{{ template "agent-instructions-common" }}` で取り込む(`gitignore-common` と同じパターン)。`~/.codex/AGENTS.md` は「Codex 用前置き → 共有本文 → `dot_claude/rules/common/*.md` の連結」で、rules の Source は移動せず Codex 側が `include` で直接読む。**連結されるのは `dot_claude/rules/common/` に Source として存在するものだけ**で、`~/.claude/rules/{typescript,web}/` は `.chezmoiexternal.toml` が ECC リポジトリから SHA 固定で取り込むものなので Source に無く、Codex には連結されない(Codex 前置きの「ルール構成」はこの事実を明示する)。ECC は plugin として丸ごと有効化せず、使っているファイルだけを external で取り込む(`docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md`)。`~/.claude/rules/` 配下に symlink で差し込まれる仕事用ルールはマシン固有なので含まれない。Cursor はグローバル rules を持たないため対象外(ADR 0004)。共有本文には製品名も製品固有のツール名も書かない — `AskUserQuestion` は Claude 側の末尾セクションにだけ置き、共有本文は「番号付きの選択肢を提示する」という製品非依存の意図だけを持つ。**rules の取り込みは `glob` ではなく `include` の明示列挙**: 第一の理由は連結順序が読めること(その順序が `AGENTS.md` の並びで、Codex の切り捨ては末尾から起きる)。加えて `glob` の**相対**パターンは cwd 相対で評価されるため、`chezmoi apply` の実行位置によっては黙って空リストを返し、ルールが 1 件も入らない `AGENTS.md` を静かに生成する(実測済み。`glob (joinPath .chezmoi.sourceDir "…")` の**絶対**パターンなら cwd に依存しないことも実測済みなので、これは glob を採らない決め手ではなく副次的な理由)。ファイルを足したら `dot_codex/AGENTS.md.tmpl` にも 1 行足すこと。検査は `just test-global-instructions`(`test/global-instructions.bats`、seam は `chezmoi execute-template --config <test toml> --source <repo>` の 1 つだけ)で、共有本文が両出力に入ること・rules 全件が `AGENTS.md` に入ること・`AskUserQuestion` が `CLAUDE.md` にしか出ないこと・`AGENTS.md` が Codex の `project_doc_max_bytes`(32 KiB)に収まることを見る。chezmoi が無い環境では skip せず fail する(skip にすると CI で空振りするため、CI job `global-instructions` が chezmoi を入れている)。
