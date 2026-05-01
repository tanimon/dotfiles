---
title: "feat: Migrate plugin management to apm (Agent Package Manager)"
type: feat
status: active
date: 2026-05-01
---

# feat: Migrate plugin management to apm (Agent Package Manager)

## Summary

Replace the bespoke `marketplaces.txt` + `claude plugin marketplace add` declarative-sync pattern with Microsoft's [apm (Agent Package Manager)](https://github.com/microsoft/apm). Adds `apm` to the Brewfile, introduces a chezmoi-managed user-scope `~/.apm/apm.yml` manifest that declares marketplaces and plugins, and replaces the existing `run_onchange_after_add-marketplaces.sh.tmpl` script with one that runs `apm install -g`. Plugins become declaratively tracked across machines for the first time — the current pattern only tracks marketplaces.

---

## Problem Frame

The current setup tracks **marketplaces** declaratively (`dot_claude/plugins/marketplaces.txt` + `run_onchange_after_add-marketplaces.sh.tmpl`) but leaves **plugin install state** (`~/.claude/plugins/installed_plugins.json`) intentionally unmanaged — so each machine ends up with a different set of installed plugins (currently 18 on this host) and re-bootstrapping a new machine requires manual `claude plugin install` for each.

apm offers a single `apm.yml` manifest plus lockfile that pins marketplaces, plugins, MCP servers, and skills together — exactly the gap the current pattern leaves open. Issue [#178](https://github.com/tanimon/dotfiles/issues/178) tracks adopting apm as the replacement.

---

## Requirements

- R1. Adding a plugin or marketplace to the dotfiles repo causes it to be installed on every machine via `chezmoi apply`, with no manual `claude plugin` step required.
- R2. The current 7 marketplaces (`affaan-m/everything-claude-code`, `anthropics/claude-plugins-official`, `anthropics/skills`, `awslabs/agent-plugins`, `EveryInc/compound-engineering-plugin`, `jarrodwatts/claude-delegator`, `OthmanAdi/planning-with-files`) remain available after migration.
- R3. The current 18 installed plugins (see Context & Research) remain available after migration (whether deployed via apm or kept on existing native install — see Open Question).
- R4. `apm` is installed automatically on a fresh `chezmoi apply` run on macOS — no manual install step.
- R5. The new declarative-sync script is hash-tracked (`run_onchange_`) and idempotent — repeated `chezmoi apply` runs produce no spurious work.
- R6. `make lint` continues to pass; CI (`.github/workflows/lint.yml`) continues to pass.
- R7. `CLAUDE.md` reflects the new pattern; obsolete documentation about `marketplaces.txt` is removed or updated to point at the apm.yml location.

---

## Scope Boundaries

- This plan covers **macOS only** — the existing marketplace-sync script is gated on `darwin`, and apm install methods on Linux are not exercised by the current target machines. Linux support is deferred.
- This plan does **not** migrate MCP server management to apm. `modify_dot_claude.json` continues to own `mcpServers` injection. (apm supports MCP, but parallel migration is out of scope.)
- This plan does **not** migrate `~/.claude/skills/`, `~/.claude/agents/`, or other primitives that are not managed via the marketplace/plugin lifecycle today. They are deployed via apm only as a transitive effect of plugin installs.
- This plan does **not** add Windows support; the `windows/` tree continues to manage plugins manually.

### Deferred to Follow-Up Work

- Linux apm install path (currently `curl -sSL https://aka.ms/apm-unix | sh`): handled in a separate change once a Linux target machine exists.
- MCP server migration to apm (`apm install --mcp ...`): defer until the plugin migration is stable.
- Plugin removal automation (apm leaves stale plugin files outside its tracked manifest until cleanup runs): document the manual reset procedure rather than automating in this plan.

---

## Context & Research

### Relevant Code and Patterns

- `dot_claude/plugins/marketplaces.txt` — current declarative marketplace list (7 entries).
- `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` — current registration script that runs `claude plugin marketplace add` for each entry.
- `scripts/update-marketplaces.sh` — companion script regenerating `marketplaces.txt` from `claude plugin marketplace list --json`.
- `dot_claude/plugins/config.json` — currently empty `{ "repositories": {} }`; chezmoi-managed.
- `.chezmoiignore` — excludes `~/.claude/plugins/{cache,marketplaces,repos,blocklist.json,install-counts-cache.json,installed_plugins.json,data,known_marketplaces.json,marketplaces.txt}`.
- `darwin/Brewfile` — current package manifest; gets new `tap "microsoft/apm"` + `brew "apm"` entries.
- `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl` — runs Brewfile install during the change phase, before `_after_` scripts.
- Existing pattern parallel: `dot_config/gh/extensions.txt` + `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` + `scripts/update-gh-extensions.sh`. Same shape as marketplace sync but for `gh` extensions — the apm migration replaces a similar declarative-list pattern with a richer manifest.
- Chezmoi naming: `dot_apm/` source dir maps to `~/.apm/` target. `apm.yml.tmpl` allows Go template substitution if needed.
- Currently 18 plugins installed (`~/.claude/plugins/installed_plugins.json`):
  - `claude-code-setup@claude-plugins-official`
  - `claude-delegator@jarrodwatts-claude-delegator`
  - `claude-md-management@claude-plugins-official`
  - `code-review@claude-plugins-official`
  - `commit-commands@claude-plugins-official`
  - `compound-engineering@compound-engineering-plugin`
  - `ecc@everything-claude-code`
  - `everything-claude-code@everything-claude-code`
  - `feature-dev@claude-plugins-official`
  - `github@claude-plugins-official`
  - `gopls-lsp@claude-plugins-official`
  - `planning-with-files@planning-with-files`
  - `playwright@claude-plugins-official`
  - `plugin-dev@claude-plugins-official`
  - `pr-review-toolkit@claude-plugins-official`
  - `ralph-loop@claude-plugins-official`
  - `superpowers@claude-plugins-official`
  - `typescript-lsp@claude-plugins-official`

### Institutional Learnings

- `docs/solutions/...` — pattern of "declarative list + hash-tracked `run_onchange_` script" is reused for marketplaces, gh extensions, and ECC rules. apm replaces this for plugins but follows the same overall ordering: `chezmoi apply` → Brewfile install → `_after_` scripts.
- `CLAUDE.md` Known Pitfalls: `run_onchange_` scripts must guard for missing tools (`command -v apm >/dev/null || exit 0`) — first-apply on a clean machine may not yet have `apm` even after Brewfile install, depending on shell PATH resolution. The current marketplace script checks `command -v claude`; the new script should match.

### External References

- [microsoft/apm README](https://github.com/microsoft/apm) — three promises: portable by manifest, secure by default, governed by policy.
- [apm CLI commands](https://microsoft.github.io/apm/reference/cli-commands/) — `apm install [-g]`, `apm marketplace add`, manifest-driven installs.
- [apm marketplaces guide](https://microsoft.github.io/apm/guides/marketplaces/) — supports both Claude Code `marketplace.json` format and Copilot CLI format; `name@marketplace` install syntax.
- [apm plugins guide](https://microsoft.github.io/apm/guides/plugins/) — auto-detects `plugin.json` at `.claude-plugin/plugin.json`, deploys primitives to `.claude/skills/`, etc.
- [apm manifest schema](https://microsoft.github.io/apm/reference/manifest-schema/) — `dependencies.apm` accepts `owner/repo`, `owner/repo/subpath`, `name@marketplace`, with optional `#ref` for pinning.
- Homebrew tap: `brew install microsoft/apm/apm` (tap+formula form). Verify with `brew tap microsoft/apm && brew install apm` if direct form fails.

---

## Key Technical Decisions

- **Manifest location: `~/.apm/apm.yml` (user scope), source `dot_apm/apm.yml.tmpl`.** apm's `--global` flag installs from a manifest in the current directory and deploys to `~/.claude/`, `~/.copilot/`, etc. By placing the chezmoi-managed manifest at `~/.apm/apm.yml` and `cd ~/.apm` before running `apm install -g`, we get a single canonical user-scope manifest that all machines share. Rationale: matches apm's user-scope conventions and avoids polluting the chezmoi source tree's project root with an apm.yml that would conflict with chezmoi's own manifest semantics.
- **Marketplaces remain registered imperatively via `apm marketplace add`.** apm.yml does not have a top-level `marketplaces:` field for *registering* (only `marketplace:` for *authoring*). The chezmoi script registers each marketplace before running `apm install`. Rationale: matches apm's design; idempotent (registering an already-registered marketplace is a no-op).
- **Plugin dependencies use `name@marketplace` syntax in apm.yml.** All 18 currently-installed plugins map cleanly to this form. Rationale: keeps the manifest concise (one line per plugin) and matches the existing mental model.
- **Pin plugin refs explicitly when stability matters.** apm allows `plugin@marketplace#tag-or-sha`; without a pin, apm uses the marketplace's default ref. For this iteration, plugins are listed without pins (matching current behavior of `claude plugin install` floating on the marketplace head). Pinning is left as a follow-up.
- **The new chezmoi script is `_after_` to run post-Brewfile.** `run_onchange_after_apm-install.sh.tmpl` ensures `apm` is on PATH before invocation. Tool-availability guard (`command -v apm` ≥ exit 0) handles first-apply ordering edge cases.
- **`marketplaces.txt` and its sync are deleted, not deprecated.** Keeping both in parallel invites drift. Deleting `dot_claude/plugins/marketplaces.txt`, the `run_onchange_after_add-marketplaces.sh.tmpl` script, and `scripts/update-marketplaces.sh` removes the legacy pattern in one PR. Existing plugins on disk are not removed by `chezmoi apply`; they stay until the user manually uninstalls them or runs the documented reset procedure.
- **`installed_plugins.json` is left alone.** Plugins installed via the legacy `claude plugin install` mechanism continue to work; apm-deployed primitives coexist in the same `~/.claude/skills/`, `~/.claude/agents/` directories. This means short-term duplication during transition — accepted as a known trade-off documented in CLAUDE.md.
- **`update-marketplaces.sh` companion is replaced by manual apm.yml editing.** The list of plugins/marketplaces is small enough that hand-editing a YAML manifest is fine. A regeneration helper can be added later if the list grows.

---

## Open Questions

### Resolved During Planning

- **Where does the apm.yml live?** → `~/.apm/apm.yml` (chezmoi source `dot_apm/apm.yml.tmpl`). See Key Technical Decisions.
- **Do we keep `marketplaces.txt` for backward compat?** → No. Single source of truth in apm.yml.
- **Should marketplaces be registered declaratively in apm.yml?** → Not directly possible in current apm schema; the chezmoi script registers them. Opening an upstream feature request is out of scope.

### Deferred to Implementation

- **Plugin compatibility check**: Are all 18 plugins installable via apm? apm requires either `plugin.json` (at root, `.github/plugin/`, `.claude-plugin/`, or `.cursor-plugin/`) OR an `apm.yml`. The implementer must `apm install -g --dry-run` each marketplace's plugins on a test branch before deleting the legacy pattern. If any plugin lacks a discoverable manifest, surface it as an upstream issue and either pin to a known-good ref or temporarily exclude it from apm.yml.
- **Brew tap formula name verification**: README shows `brew install microsoft/apm/apm`. Implementer should confirm this works on the target Brewfile syntax (`tap "microsoft/apm"; brew "apm"` vs `brew "microsoft/apm/apm"`) and adjust `darwin/Brewfile` accordingly.
- **PATH availability after first install**: On a fresh machine, `apm` may not be on PATH in the same `chezmoi apply` invocation that installs it (depends on whether brew's bin dir is on PATH from the parent shell). The script's `command -v apm` guard returns exit 0 if missing, deferring install to the next `chezmoi apply` — this is acceptable but should be verified.
- **Lockfile (`apm.lock.yaml`) tracking**: apm produces a lockfile alongside `apm.yml`. The implementer must decide whether to commit `apm.lock.yaml` to the chezmoi source tree (under `dot_apm/`) for reproducible installs across machines, or `.chezmoiignore` it as runtime state. Recommendation: commit it, mirroring how npm and pnpm projects commit lockfiles.
- **One-time migration steps**: Should the implementer add a `docs/solutions/...` entry documenting the migration, including how existing users clean up `installed_plugins.json` if they want a pure apm-managed setup? Recommended.

---

## Implementation Units

- U1. **Add `apm` to Brewfile**

**Goal:** Ensure `apm` is installed automatically by `brew bundle install`.

**Requirements:** R4

**Dependencies:** None

**Files:**
- Modify: `darwin/Brewfile`

**Approach:**
- Add `tap "microsoft/apm"` and `brew "apm"` (or the single-line `brew "microsoft/apm/apm"` if Brewfile syntax accepts it) near the other AI/dev tooling brews.
- Verify locally that `brew bundle install --file=darwin/Brewfile` succeeds with the change.
- Confirm `apm --version` reports a version after install.

**Patterns to follow:**
- Existing `tap`+`brew` entries in `darwin/Brewfile`.

**Test scenarios:**
- Happy path: `brew bundle install --file=darwin/Brewfile` exits 0; `apm --version` prints a version on the same machine afterwards.
- Edge case: idempotency — running `brew bundle install` twice in a row is a no-op on the second run (no error, no reinstall).

**Verification:**
- `apm --version` works in a non-sandboxed shell after running `brew bundle install`.
- `make lint` continues to pass (Brewfile is not directly linted but `darwin-install-packages.sh.tmpl` hash changes pick up the new entry on next `chezmoi apply`).

---

- U2. **Create chezmoi-managed `~/.apm/apm.yml` manifest**

**Goal:** Declare all 7 marketplaces' plugins as apm dependencies in a manifest deployed to `~/.apm/apm.yml`.

**Requirements:** R1, R2, R3

**Dependencies:** U1 (need apm available to validate the manifest with `apm install -g --dry-run`)

**Files:**
- Create: `dot_apm/apm.yml.tmpl`

**Approach:**
- Top-level fields: `name: dotfiles-user`, `version: 1.0.0`, `description: User-scope apm manifest managed by chezmoi`.
- `target: claude` (or omit and rely on auto-detection from `~/.claude/`).
- `dependencies.apm:` lists each of the 18 plugins in `name@marketplace` form (or `owner/repo/plugin` long form when the marketplace alias resolution is uncertain).
- Use chezmoi templating only if a value differs by `.profile` (work vs personal); otherwise keep the file static and rename to `apm.yml` (no `.tmpl`). Default to non-template form.
- Run `apm install -g --dry-run` from `~/.apm/` after first apply to validate the manifest before committing.

**Patterns to follow:**
- `dot_claude/mcp-servers.json` for chezmoi-managed config files at user scope.
- apm manifest examples from [microsoft/apm-sample-package](https://github.com/microsoft/apm-sample-package).

**Test scenarios:**
- Happy path: `chezmoi apply` deploys the file to `~/.apm/apm.yml`; `cd ~/.apm && apm install -g --dry-run` lists the expected plugins as "would install" without errors.
- Edge case: re-applying with no changes leaves `~/.apm/apm.yml` byte-identical to the previous run (chezmoi diff is empty).
- Error path: removing a marketplace's plugin from apm.yml causes `apm install -g` on the next run to clean up the deployed plugin's primitives (per apm's stale-file cleanup semantics) — verify by removing one plugin, re-applying, and confirming `~/.claude/skills/<that-plugin>/` is gone (only if it was deployed via apm).

**Verification:**
- `chezmoi apply` produces `~/.apm/apm.yml` with the documented dependencies.
- `apm install -g --dry-run` succeeds on the deployed manifest.

---

- U3. **Create `run_onchange_after_apm-install.sh.tmpl` chezmoi script**

**Goal:** Register marketplaces and run `apm install -g` whenever `apm.yml` changes, replacing the existing marketplace-add script.

**Requirements:** R1, R5

**Dependencies:** U1 (apm must exist), U2 (apm.yml must exist)

**Files:**
- Create: `.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl`

**Approach:**
- Gate on `darwin` (matching the existing marketplace script's gating).
- `set -euo pipefail`.
- Hash-track both `dot_apm/apm.yml(.tmpl)` (manifest contents) so the script re-runs when dependencies change.
- Tool guard: `command -v apm >/dev/null 2>&1 || { echo "apm not found, skipping (re-run chezmoi apply after brew install completes)"; exit 0; }` — matches the existing pattern.
- Iterate over the 7 marketplaces (sourced from a literal list in the script, or from a small `dot_apm/.marketplaces.txt` data file): `apm marketplace add "$marketplace" || true` (idempotent; failures don't abort).
- `cd "${HOME}/.apm" && apm install -g`.
- Surface clear logging: `echo "Registering marketplace: $name"`, `echo "Running apm install -g"`.

**Patterns to follow:**
- `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` for hash tracking, OS gating, and tool guarding.
- `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` for iterating a list and calling a CLI.

**Test scenarios:**
- Happy path: First-apply on a machine with `apm` installed succeeds; all 7 marketplaces register; `apm install -g` deploys plugins.
- Edge case: `apm` not on PATH → script logs the warning and exits 0.
- Edge case: re-apply with unchanged apm.yml → chezmoi reports script not run (hash unchanged).
- Edge case: changing one plugin in apm.yml → script re-runs; `apm install` updates only the changed dependency.
- Error path: marketplace registration fails (network error, deleted marketplace) → `|| true` suppresses; `apm install` later fails with a clear error if the marketplace is still referenced.

**Verification:**
- `chezmoi apply` runs the script; `~/.apm/apm.lock.yaml` is created/updated; `~/.claude/` contains expected plugin primitives.

---

- U4. **Remove obsolete marketplace sync files**

**Goal:** Delete the legacy declarative-marketplace pattern.

**Requirements:** R7

**Dependencies:** U2, U3 (replacement must be in place first)

**Files:**
- Delete: `dot_claude/plugins/marketplaces.txt`
- Delete: `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl`
- Delete: `scripts/update-marketplaces.sh`
- Modify: `.chezmoiignore` (remove the `dot_claude/plugins/marketplaces.txt` and `dot_claude/plugins/known_marketplaces.json` entries that referenced the legacy pattern, if any)
- Modify: `Makefile` (if `update-marketplaces` is referenced as a target)

**Approach:**
- Verify with `grep -rn marketplaces` that no documentation references the deleted files outside of CLAUDE.md (which is updated in U6).
- Run `make lint` to confirm no test-target globbing references the deleted scripts.

**Patterns to follow:**
- Past deletion PRs in `git log` — atomic delete + ensure `make lint` still passes.

**Test scenarios:**
- Test expectation: none beyond CI green — no behavioral change beyond the file removals; behavior is verified by U2/U3.

**Verification:**
- `git status` shows the three files deleted, no other unintended changes.
- `make lint` passes.

---

- U5. **Add `~/.apm/` runtime state to `.chezmoiignore`**

**Goal:** Prevent chezmoi from trying to manage apm's runtime state files (lockfile, registries cache, apm_modules).

**Requirements:** R5

**Dependencies:** None (can land in parallel with U2)

**Files:**
- Modify: `.chezmoiignore`

**Approach:**
- Add `.apm/registries`, `.apm/apm_modules`, `.apm/cache`, and any other apm runtime-state directories to `.chezmoiignore`.
- Decide whether to commit `apm.lock.yaml` (recommended: commit it, so it's NOT in `.chezmoiignore` — chezmoi source path `dot_apm/apm.lock.yaml`).
- Verify with `chezmoi managed | grep apm` that only the intended files are tracked.

**Patterns to follow:**
- Existing `.chezmoiignore` block for `~/.claude/plugins/` runtime state.

**Test scenarios:**
- Happy path: After `chezmoi apply`, `chezmoi managed | grep -E '^\.apm/'` lists exactly `.apm/apm.yml` (and `.apm/apm.lock.yaml` if committed) — nothing else.

**Verification:**
- `chezmoi diff` is clean after `apm install -g` runs (runtime state changes don't show up as drift).

---

- U6. **Update CLAUDE.md and README documentation**

**Goal:** Reflect the new apm-based pattern; remove obsolete `marketplaces.txt` references.

**Requirements:** R7

**Dependencies:** U4 (after deletion is final)

**Files:**
- Modify: `CLAUDE.md`
- Modify: `dot_claude/CLAUDE.md` (only if it references marketplaces — check first)

**Approach:**
- Update the "Common Commands" section: replace `pnpm exec ...` for marketplaces with `apm install -g`, `apm marketplace list`, etc.
- Update the "Architecture / Key Patterns / Declarative marketplace sync" subsection to describe the apm pattern: manifest at `dot_apm/apm.yml`, `apm install -g` deployment, `apm marketplace add` registration done by the chezmoi script.
- Document the one-time migration step for existing users: "Run `claude plugin uninstall <name>` for any plugin you want apm to manage exclusively, then `chezmoi apply` to re-deploy via apm."
- Add a "Known Pitfalls" entry: `apm install -g` deploys files into `~/.claude/skills/`, `~/.claude/agents/`, etc. directly — these are NOT visible in `claude plugin list` output (which reads `installed_plugins.json`). To audit what apm manages, use `apm list -g` (or whatever command apm provides for listing).
- Remove the `update-marketplaces.sh` reference under `scripts/` table.

**Patterns to follow:**
- Existing `Architecture / Key Patterns` subsection structure in CLAUDE.md.

**Test scenarios:**
- Test expectation: none — documentation change. Manual review verifies accuracy.

**Verification:**
- `make lint` passes (CLAUDE.md is scanned by `make scan-sensitive`).
- A reader unfamiliar with the change can determine, from CLAUDE.md alone, where to add a new plugin.

---

- U7. **Verify CI and add a smoke test if cheap**

**Goal:** Ensure CI exercises the new pattern without a heavy lift.

**Requirements:** R6

**Dependencies:** U2, U3

**Files:**
- Modify (only if needed): `Makefile` (add a `test-apm-yml` target that runs `apm install -g --dry-run` against the source manifest)
- Modify (only if needed): `.github/workflows/lint.yml`

**Approach:**
- If `apm` is easily installable in the GitHub-hosted Ubuntu runner used by `lint.yml`, add a smoke test target `test-apm-yml` that:
  - Installs apm via `curl -sSL https://aka.ms/apm-unix | sh`
  - Copies `dot_apm/apm.yml.tmpl` to a temp dir, renders if needed
  - Runs `apm install -g --dry-run` and fails the build on validation errors
- If apm install is heavy (>30s) or unreliable in CI, **skip** this unit and rely on local `apm install -g --dry-run` during development.
- Update `make lint` only if a new target is genuinely added — do not add ceremony for its own sake.

**Execution note:** Defer this unit if it adds CI flakiness. Local validation in U2 covers the manifest-correctness signal at acceptable cost.

**Patterns to follow:**
- Existing smoke tests like `make test-modify`, `make test-scripts`.

**Test scenarios:**
- Happy path (only if implemented): `make test-apm-yml` exits 0 on a valid manifest.
- Error path (only if implemented): a syntactically invalid `apm.yml` causes the target to exit non-zero with a clear message.

**Verification:**
- CI passes on the PR branch.

---

## System-Wide Impact

- **Interaction graph:** `chezmoi apply` ordering — Brewfile install (`run_onchange_darwin-install-packages.sh.tmpl`) must complete before `run_onchange_after_apm-install.sh.tmpl` runs. The `_after_` prefix achieves this. If apm is missing on first apply, the script exits 0 with a warning and runs successfully on the next `chezmoi apply`.
- **Error propagation:** Marketplace registration failures (`apm marketplace add ... || true`) do not abort the script. `apm install -g` will surface clear errors if a referenced marketplace is missing. Plugin install failures from `apm install -g` propagate as non-zero exit and stop `chezmoi apply` — this matches the current behavior of `claude plugin marketplace add`.
- **State lifecycle risks:**
  - Existing plugins in `~/.claude/plugins/installed_plugins.json` are not removed by this migration. They continue to be loaded by Claude Code alongside apm-deployed primitives. Risk: duplicated commands/skills if a plugin is installed via both paths — mitigated by documenting the one-time cleanup procedure.
  - `apm.lock.yaml` becomes a tracked artifact (per Open Question recommendation). When committed, it must be regenerated and re-committed any time `apm.yml` changes. This is a new mental-model burden the implementer must communicate.
- **API surface parity:** `claude plugin install <name>` from the CLI continues to work for one-off installs not tracked in apm.yml. apm and Claude Code's native plugin lifecycle coexist without explicit integration.
- **Integration coverage:** Verifying that all 18 plugins are loadable post-migration requires manual inspection — start a `claude` session and confirm slash commands like `/code-review`, `/superpowers:brainstorm`, etc. resolve. apm's `--dry-run` only validates manifest syntax, not runtime loadability.
- **Unchanged invariants:**
  - `~/.claude.json` `mcpServers` continues to be managed by `modify_dot_claude.json` — this plan does NOT migrate MCP to apm.
  - `dot_claude/settings.json.tmpl`, `dot_claude/scripts/`, and other chezmoi-managed Claude Code config remains untouched.
  - `~/.claude/plugins/installed_plugins.json` continues to be untracked by chezmoi (in `.chezmoiignore`).

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| apm is a new tool (recently released) and may have bugs or breaking changes that disrupt `chezmoi apply` | Pin to a specific apm version in Brewfile if upstream releases prove unstable; revert to legacy pattern is one-PR away (deletion is reversible via git revert) |
| One or more of the 7 marketplaces lacks an apm-compatible manifest at root, so `apm install` fails | Validate each marketplace with `apm install -g --dry-run` during U2 before deleting the legacy pattern in U4. If a marketplace is incompatible, file an upstream issue and either pin to a known-good ref or temporarily exclude that marketplace's plugins from apm.yml |
| Brew tap `microsoft/apm` may not be the canonical install path on macOS — README also lists `pip install apm-cli` and `curl ... | sh` | Verify Brewfile syntax during U1 implementation; if brew tap fails, fall back to a `run_onchange_` script that runs `curl ... | sh` |
| apm-deployed primitives shadow Claude Code's plugin system, leading to confusion about which path "owns" a given skill/agent | Document explicitly in CLAUDE.md (U6); reset procedure tells users to `claude plugin uninstall` if they want apm-only management |
| First-apply ordering: apm not yet on PATH when `_after_` script runs | Tool guard exits 0 with a clear warning; user re-runs `chezmoi apply` once apm is on PATH. Acceptable trade-off; matches existing pattern |
| Lockfile (`apm.lock.yaml`) drift between machines if not committed | Commit `dot_apm/apm.lock.yaml` to the chezmoi source tree (matches npm/pnpm conventions); document the regen workflow in CLAUDE.md |

---

## Documentation / Operational Notes

- **Migration runbook for existing users** (added to CLAUDE.md or `docs/solutions/...`):
  1. `git pull` the new branch.
  2. `chezmoi apply` — installs `apm` via Brewfile, deploys `~/.apm/apm.yml`, runs `apm install -g`.
  3. (Optional) `claude plugin uninstall <name>` for plugins now managed by apm to avoid duplication.
  4. Verify in a fresh `claude` session that all expected slash commands resolve.
- **Adding a new plugin or marketplace going forward:**
  1. Edit `dot_apm/apm.yml.tmpl` to add the new dependency.
  2. (For new marketplaces only) Edit the marketplace list in `run_onchange_after_apm-install.sh.tmpl` if marketplaces are sourced from the script literal — or skip if the marketplace is referenced via direct `owner/repo/plugin` form in apm.yml.
  3. `chezmoi apply` to install locally.
  4. Commit and push.
- **Lockfile workflow:** After `apm install -g` runs, `~/.apm/apm.lock.yaml` is updated. To propagate the lock to other machines, copy it back to the chezmoi source: `cp ~/.apm/apm.lock.yaml ~/.local/share/chezmoi/dot_apm/apm.lock.yaml`, then commit.

---

## Sources & References

- Issue: [tanimon/dotfiles#178](https://github.com/tanimon/dotfiles/issues/178)
- apm: https://github.com/microsoft/apm
- apm CLI commands: https://microsoft.github.io/apm/reference/cli-commands/
- apm marketplaces: https://microsoft.github.io/apm/guides/marketplaces/
- apm plugins: https://microsoft.github.io/apm/guides/plugins/
- apm manifest schema: https://microsoft.github.io/apm/reference/manifest-schema/
- Existing pattern: `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl`, `dot_claude/plugins/marketplaces.txt`, `scripts/update-marketplaces.sh`
- CLAUDE.md sections: "Common Commands", "Architecture / Key Patterns / Declarative marketplace sync"
