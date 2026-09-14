## Architecture

### Template Variables

Defined in `.chezmoi.toml.tmpl`, prompted on first `chezmoi init`:
- `.profile` — `"work"` or `"personal"` (controls gitconfig work overrides)
- `.ghOrg` — GitHub org name (used in permissions and directory paths)
- `.chezmoi.homeDir` — Home directory path

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
| `harness/` | Harness Manifest(グローバル用 `manifest.json` / このリポジトリ用 `project.json`)、Content Module(`modules/`)、同期・検証ツール(`bin/harness.sh`、`lib/`、`adapters/`)。repo-only、`~/` に配置されない |
| `harness/modules/` | エージェント指示の Source。`project/` はこのリポジトリの 3 製品共通、`global/` はプロジェクト横断の共通、`runtime/` は製品固有の Runtime Extension。`CLAUDE.md` / `AGENTS.md` / `.cursor/rules/` と `~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md` はここから生成される |
| `.cursor/rules/` | 生成される Cursor の Project Rule(`.mdc`)。chezmoi からは不可視(source 直下の `.` 始まりは `.chezmoi*` を除き source state に入らない)なので `.chezmoiignore` の記載は不要 |
| `scripts/` | Repo-only helper scripts (`update-brewfile.sh`, `update-gh-extensions.sh`) |
| `test/` | bats-core test suites — one `.bats` file per script under test, run via `just test-*` targets |
| `docs/solutions/` | Past problem resolutions — search here when encountering similar issues |
| `CONTEXT.md` | Shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts. Glossary format per mattpocock-skills' `CONTEXT-FORMAT.md`; see `docs/agents/domain.md` |
| `CONCEPTS.md` | **Deprecated** predecessor of `CONTEXT.md`. Read-only archive: keeps the longer background paragraphs that don't fit `CONTEXT-FORMAT.md`'s one-to-two-sentence limit — **read the relevant section before deciding on permission rules, boundary exclusions, verification design, or `modify_` partial ownership** (inventory in `docs/agents/domain.md`). Never add new terms here |

### Pre-commit Hooks

Uses `prek` (not husky) with `secretlint` to prevent committing secrets. Dependencies managed via pnpm. The `run_onchange_install-pre-commit-hooks.sh.tmpl` script auto-installs when `package.json` or `.pre-commit-config.yaml` change.
