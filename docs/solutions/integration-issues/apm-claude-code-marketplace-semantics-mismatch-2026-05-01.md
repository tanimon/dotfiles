---
title: "apm migration breaks chezmoi apply due to Claude Code marketplace.json semantics mismatch"
date: 2026-05-01
category: integration-issues
module: dot_apm
problem_type: integration_issue
component: tooling
severity: high
symptoms:
  - "apm install rejects `name@marketplace` form in apm.yml -- apm only accepts canonical `owner/repo[/subpath]`"
  - "apm install fails on LSP-only plugins (gopls-lsp, typescript-lsp) whose plugin subdirs contain only LICENSE/README"
  - "Marketplace registration loop is dead infrastructure -- canonical owner/repo paths bypass marketplace resolution entirely"
  - "Three cascading failures during chezmoi apply when migrating to apm"
root_cause: config_error
resolution_type: migration
related_components:
  - dot_apm/apm.yml
  - .chezmoiscripts/run_onchange_after_apm-install.sh.tmpl
  - marketplace.json
tags:
  - apm
  - agent-package-manager
  - claude-code
  - plugin-management
  - chezmoi
  - declarative-sync
  - marketplace-json
  - manifest-format
---

# apm migration breaks chezmoi apply due to Claude Code marketplace.json semantics mismatch

> **Supersedes** [chezmoi-declarative-marketplace-sync-over-bidirectional.md](chezmoi-declarative-marketplace-sync-over-bidirectional.md) for plugin management. Meta-rules (unidirectional sync, single source of truth, idempotent CLIs) from that doc remain valid; the mechanism (`claude plugin marketplace add` + `marketplaces.txt`) is replaced by `apm install -g` with canonical paths.

## Problem

Migrating Claude Code plugin management from declarative marketplace sync (`marketplaces.txt` + `run_onchange_` scripts) to apm (Microsoft Agent Package Manager) produced three cascading failures during `chezmoi apply`. All three traced to a single root cause: **conflating apm's manifest semantics with Claude Code's `marketplace.json` semantics**. The two tools share filesystem layout (`~/.claude/skills/`, `~/.claude/agents/`) and superficially similar plugin IDs, but their package resolution models differ fundamentally.

## Symptoms

**Failure 1 -- `apm.yml` syntax rejected:**

```
[x] Failed to parse $HOME/.apm/apm.yml: Invalid APM dependency
'claude-code-setup@claude-plugins-official': Use 'user/repo' or
'github.com/user/repo' or 'dev.azure.com/org/project/repo' format
chezmoi: .chezmoiscripts/apm-install.sh: exit status 1
```

**Failure 2 -- LSP-only plugins have no installable structure:**

```
[x] 2 packages failed:
  +- claude-plugins-official-gopls-lsp -- Failed to download dependency
anthropics/claude-plugins-official: Subdirectory is not a valid APM package or
Claude Skill: Not a valid APM package: no apm.yml, SKILL.md, hooks, or plugin
structure found in gopls-lsp.
  +- claude-plugins-official-typescript-lsp -- Failed to download dependency
anthropics/claude-plugins-official: ... no apm.yml, SKILL.md, hooks, or plugin
structure found in typescript-lsp.
```

**"Failure" 3 -- dead infrastructure surfaced by user feedback** (not an error):

> "dot_apm/marketplaces.txt は不要ではないでしょうか？"

With canonical paths in `apm.yml`, the marketplace-registration layer was no longer load-bearing. Not a tool error -- a redundancy revealed only after the canonical-path fix landed.

## What Didn't Work

- **Using `name@marketplace` form in `apm.yml`** (e.g., `claude-delegator@jarrodwatts-claude-delegator`). The form was lifted from Claude Code's `installed_plugins.json` plugin IDs because the strings looked identical to apm's CLI shorthand. Reality: apm's CLI accepts and normalizes that form, but the **manifest grammar itself only accepts canonical git-resolvable paths**.
- **Reaching for `--force` on Failure 2.** First instinct on the "no valid APM package" error. Reading the error carefully showed the subdirectory genuinely contains no `plugin.json` / `SKILL.md` / `apm.yml` -- `--force` cannot conjure a package structure. The actual config lives in marketplace.json's `lspServers` field, which apm cannot read.
- **Treating a reviewer's "alias inconsistency" flag as a bug.** A cross-reviewer noted that `jarrodwatts-claude-delegator` looked like `<owner>-<repo>` while other entries used just `<repo>`. Direct verification via `gh api .../marketplace.json` confirmed the alias is what the marketplace declares -- the inconsistency lives in marketplace.json itself, not in apm.yml. False positive; do not normalize away.

## Solution

### 1. Use canonical git-resolvable paths in `apm.yml`

Look up each plugin's `source` field in its marketplace.json:

```bash
gh api repos/<owner>/<repo>/contents/.claude-plugin/marketplace.json \
  --jq '.content' | base64 -d | jq '.plugins[] | {name, source}'
```

Map `source` forms to apm.yml dependency strings:

| `marketplace.json` source | `apm.yml` entry |
|---|---|
| `"./plugins/<name>"` | `owner/repo/plugins/<name>` |
| `{ "type": "url", "url": "https://github.com/x/y.git" }` | `x/y` (the source repo, not the marketplace repo) |
| `"./"` | `owner/repo` |
| (no marketplace.json, just `plugin.json` at repo root) | `owner/repo` |

Final `apm.yml` `dependencies.apm` for this migration:

```yaml
dependencies:
  apm:
    - anthropics/claude-plugins-official/plugins/claude-md-management
    - anthropics/claude-plugins-official/external_plugins/github
    - obra/superpowers                  # URL source -> separate repo
    - EveryInc/compound-engineering-plugin/plugins/compound-engineering
    - affaan-m/everything-claude-code   # source "./"
    - jarrodwatts/claude-delegator      # source "./"
    - OthmanAdi/planning-with-files     # plugin.json only, no marketplace.json
```

### 2. Exclude LSP-only plugins from `apm.yml`

The `lspServers` field in marketplace.json is Claude Code-specific. Plugins whose entire content lives in that field have no installable structure. Diagnostic:

```bash
gh api repos/anthropics/claude-plugins-official/contents/plugins/gopls-lsp \
  --jq '.[].name'
# returns: LICENSE, README.md  (no plugin.json/SKILL.md/apm.yml)
```

Keep these on the legacy `claude plugin install <name>@<marketplace>` path. State in `~/.claude/plugins/installed_plugins.json` is per-machine and untracked by chezmoi. Document the exception explicitly in `CLAUDE.md` so future maintainers don't try to re-add them to apm.yml.

### 3. Delete marketplace registration entirely

With canonical paths, `apm install -g` resolves dependencies directly from GitHub. `apm marketplace add` only matters for the `apm install <plugin>@<marketplace>` CLI shorthand -- it does not gate canonical-path resolution. Final script (`.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl`):

```bash
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# apm.yml hash: {{ include "dot_apm/apm.yml" | sha256sum }}

if ! command -v apm >/dev/null 2>&1; then
  echo "apm not found, skipping (re-run chezmoi apply after brew install completes)"
  exit 0
fi

APM_HOME="{{ .chezmoi.homeDir }}/.apm"

if [ ! -d "$APM_HOME" ]; then
  echo "ERROR: $APM_HOME not found — chezmoi did not deploy dot_apm/." >&2
  exit 1
fi

cd "$APM_HOME"
apm install -g
{{ end -}}
```

Delete `dot_apm/marketplaces.txt` and the marketplace-registration loop.

## Why This Works

- **apm uses git-native dependency resolution.** Canonical `owner/repo[/subpath]` is a git URL with a subdirectory selector. apm clones (or sparse-checks-out) the repo and looks for `plugin.json` / `SKILL.md` / `apm.yml` at that path. No marketplace lookup is in the resolution path.
- **`marketplace.json` is a Claude-Code-flavored discovery layer.** apm understands a *subset* of marketplace.json (`name`, `plugins[].name`, `plugins[].source`) for `apm marketplace add` discovery, but ignores Claude Code-specific extensions like `lspServers`. When migrating, treat `marketplace.json` as a **map of canonical paths to feed into `apm.yml`**, not a source of truth apm can natively consume.
- **`apm install --dry-run` is the manifest-validation primitive.** It parses the full manifest, surfaces every dependency-form error at once, and does not fetch -- fast iteration:

  ```bash
  mkdir /tmp/manifest-check && cd /tmp/manifest-check
  cp ~/.local/share/chezmoi/dot_apm/apm.yml .
  apm install --dry-run
  ```

## Prevention

### 1. Cross-tool semantics: assume nothing about package equivalence

apm and Claude Code share filesystem layout but have different package model semantics. When migrating between such tools:

- Read each tool's package-format spec (apm: `apm.yml` / `SKILL.md` / `plugin.json`; Claude Code: `marketplace.json` + `plugin.json`).
- Identify fields one tool understands that the other doesn't (here: `lspServers`).
- Verify resolution paths **empirically** -- inspect actual subdir contents on GitHub via `gh api`.

### 2. Cross-tool ID confusion: don't trust shape similarity

Claude Code's plugin IDs (`name@marketplace`) and apm's CLI shorthand (`name@marketplace`) look identical, but neither is the canonical manifest form. Always check three layers:

- **Manifest grammar** (apm.yml: `owner/repo[/subpath]` or git URL)
- **CLI input** (apm install accepts many forms, normalizes internally)
- **Persistent state** (apm.lock.yaml: canonical with commit SHAs)

### 3. Use `--dry-run` aggressively for manifest validation

Run `apm install --dry-run` in a `/tmp` directory after every dependency-form change before committing. Fast, side-effect-free, full-manifest parse.

### 4. Don't carry legacy assumptions across migrations

Auto memory `claude_code_plugin_lifecycle.md` (auto memory [claude]) documents Claude Code's 3-layer plugin model (marketplace registration → plugin install → enabledPlugins toggle). The temptation when migrating is to preserve all three layers in the new system. With canonical paths in apm, **the marketplace-registration layer is dead infrastructure for declarative sync**. Question every layer of the legacy model against the migration target.

### 5. `marketplace.json` `name` is the alias, not a derivable repo segment

apm's marketplace alias resolution prefers the declared `name` field over any heuristic. Verify directly:

```bash
gh api repos/<owner>/<repo>/contents/.claude-plugin/marketplace.json \
  --jq '.content' | base64 -d | jq '.name'
```

This is independent of Claude Code's alias derivation (Claude Code uses `<owner>-<repo>` for shorthand registrations; apm uses the declared `name`). Apparent "inconsistencies" in alias form between entries are usually load-bearing -- verify before normalizing.

### 6. Read error messages literally before reaching for force-flags

Failure 2's error explicitly listed what apm looks for (`apm.yml`, `SKILL.md`, hooks, plugin structure). The diagnostic was a one-line `gh api` call. `--force` would not have helped because the package genuinely does not exist. **Match the error's precondition to a diagnostic, not to a workaround flag.**

### 7. User feedback as redundancy detector

Failure 3 was not produced by a tool -- it was produced by a user asking why a file existed. After mechanical fixes, ask: **what infrastructure is now dead?** Marketplace registration was load-bearing under the legacy 3-layer model and dead under canonical paths. Migrations frequently leave behind such residue; review the diff against the new resolution model.

## Related Issues

- GitHub issue [#178](https://github.com/tanimon/dotfiles/issues/178) -- "Plugins 管理を apm へ移行" (tracking issue)
- PR [#191](https://github.com/tanimon/dotfiles/pull/191) -- this migration; commits `1f5c0ef` (canonical paths), `e2bb653` (LSP exclusion), `9bbf7db` (marketplace removal)
- Plan: [docs/plans/2026-05-01-001-feat-migrate-plugins-to-apm-plan.md](../../plans/2026-05-01-001-feat-migrate-plugins-to-apm-plan.md)
- Predecessor pattern: [chezmoi-declarative-marketplace-sync-over-bidirectional.md](chezmoi-declarative-marketplace-sync-over-bidirectional.md) (superseded for plugin management; meta-rules remain valid)
- Three-layer plugin lifecycle reference: [ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md](ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md) (explains why apm-installed plugins don't appear in `/plugin list`)
- Historical chain: [chezmoi-apply-overwrites-runtime-plugin-changes.md](chezmoi-apply-overwrites-runtime-plugin-changes.md) (bidirectional sync → marketplaces.txt → apm)
- Parallel pattern still in use: [chezmoi-gh-extension-declarative-management-gotchas.md](chezmoi-gh-extension-declarative-management-gotchas.md)
