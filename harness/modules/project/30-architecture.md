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
