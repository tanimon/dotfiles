---
title: Replace Bidirectional Plugin Sync with Declarative Marketplace Registration
date: 2026-03-08
category: integration-issues
tags:
  - chezmoi
  - plugin-management
  - sync-pattern
  - declarative-config
severity: medium
component: Claude Code Plugin Management
---

# Replace Bidirectional Plugin Sync with Declarative Marketplace Registration

## Problem Symptom

A chezmoi dotfiles repo accumulated a complex 3-layer bidirectional sync system (6 files, ~190 LOC) for Claude Code plugin files (`known_marketplaces.json`, `installed_plugins.json`):

1. `modify_` scripts — seed on new machines, merge/passthrough on existing
2. `.data` shadow files — canonical copies with `{{ .chezmoi.homeDir }}` template substitution
3. `run_after_` scripts — reverse-sync live files back to `.data` via `cp` + `sed`

**Symptoms:**
- Template escaping complexity (`{{ "{{ .chezmoi.homeDir }}" }}`)
- JSON merge conflicts across machines when `.data` files diverge
- Additive-only merge (marketplace deletions don't propagate)
- Maintenance burden from interdependent scripts and shadow files

## Investigation Steps

1. **Explored `chezmoi merge`** — interactive-only, designed for conflict resolution, not automated sync
2. **Explored `chezmoi re-add`** — cannot run inside `run_after_` scripts (DB lock via bbolt), skips templates
3. **Explored `chezmoi merge-all`** — batch version of `merge`, same limitations
4. **Checked for new source attributes** — no `merge_`, `sync_`, or `plugin_` attribute exists; proposed and declined by maintainer (GitHub discussion #3550)
5. **Explored symlinks** — eliminates all layers but loses template portability and requires testing Claude Code symlink handling
6. **Key realization** — narrowing the requirement to "sync marketplace registrations only" (not full plugin state) eliminates the need for bidirectional sync entirely
7. **Discovered** `claude plugin marketplace add` is idempotent and `claude plugin marketplace list --json` provides machine-readable output

## Root Cause

**Over-engineering from unexamined requirements.** The system synced entire runtime JSON files bidirectionally when the actual need was only sharing marketplace registrations across machines. Plugin install/enable state is machine-specific and doesn't need syncing.

**Anti-pattern:** Bidirectional sync between chezmoi source and runtime-mutable files. chezmoi is designed for unidirectional flow (source → target). Forcing reverse sync creates complexity, race conditions, and multiple sources of truth.

## Solution

Replace with a unidirectional declarative approach (3 files, ~40 LOC):

### 1. `dot_claude/plugins/marketplaces.txt` — declarative list

```text
affaan-m/everything-claude-code
anthropics/claude-plugins-official
anthropics/skills
EveryInc/compound-engineering-plugin
jarrodwatts/claude-delegator
OthmanAdi/planning-with-files
```

### 2. `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` — hash-tracked sync

```bash
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# marketplaces.txt hash: {{ include "dot_claude/plugins/marketplaces.txt" | sha256sum }}

if ! command -v claude &>/dev/null; then
  echo "claude CLI not found, skipping marketplace registration"
  exit 0
fi

while IFS= read -r source || [ -n "$source" ]; do
  [[ -z "$source" || "$source" == \#* ]] && continue
  echo "Ensuring marketplace: ${source}"
  claude plugin marketplace add "$source" || true
done < "{{ .chezmoi.sourceDir }}/dot_claude/plugins/marketplaces.txt"
{{ end -}}
```

### 3. `scripts/update-marketplaces.sh` — list generator

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${REPO_ROOT}/dot_claude/plugins/marketplaces.txt"

claude plugin marketplace list --json \
  | jq -r '.[] | if .source == "github" then .repo else .url end' \
  | sort \
  > "$TARGET"

echo "Updated ${TARGET} ($(wc -l < "$TARGET" | tr -d ' ') marketplaces)"
```

### 4. Cleanup

- Removed: `modify_known_marketplaces.json.tmpl`, `modify_private_installed_plugins.json.tmpl`, `.known_marketplaces.json.data`, `.installed_plugins.json.data`, `run_after_10-ensure-marketplaces.sh.tmpl`, `run_after_20-sync-plugins.sh.tmpl`
- Added to `.chezmoiignore`: `installed_plugins.json`, `known_marketplaces.json`, `marketplaces.txt`

### Workflow

```bash
claude plugin marketplace add <source>   # Add locally
scripts/update-marketplaces.sh           # Regenerate list
git commit && git push                   # Share
chezmoi apply                            # Other machines (run_onchange_ adds marketplaces)
```

## Gotcha

`*.txt` in `.chezmoiignore` only matches root-level files — chezmoi uses `filepath.Match`, not recursive glob. Nested paths like `.claude/plugins/marketplaces.txt` require an explicit entry.

## Prevention Strategies

### Decision tree for chezmoi sync patterns

```
"Do I need to share this data across machines?"
  ├─ NO → .chezmoiignore (exclude entirely)
  └─ YES → "Is it user-defined config or tool-generated state?"
      ├─ USER-DEFINED → regular .tmpl file
      └─ TOOL-GENERATED → "Does the tool have idempotent CLI?"
          ├─ YES → Pattern A: declarative list + run_onchange_ + CLI
          ├─ PARTIAL → Pattern C: modify_ for user-owned keys only
          └─ NO → Reconsider if syncing is truly needed
```

### Rules

1. **Unidirectional only.** chezmoi source → target. Never reverse-sync.
2. **Single source of truth.** One file owns the data, not three.
3. **Minimize what's managed.** Exclude runtime files with `.chezmoiignore`.
4. **Prefer idempotent CLIs.** If a tool has `add`/`init` commands, use them instead of managing state files.
5. **Question requirements first.** "Sync plugin state" vs. "share marketplace registrations" — narrowing scope enables radical simplification.

### Code review checklist for chezmoi patterns

- [ ] Is this sync actually necessary?
- [ ] Are we syncing entire files when we should sync just one key?
- [ ] Is data flowing in two directions? (red flag)
- [ ] Could we use `run_onchange_` + CLI instead of `modify_`?
- [ ] Is there a single source of truth?

## Related

- PR #10: `refactor: replace bidirectional plugin sync with declarative marketplace list`
- PR #8: `fix: prevent chezmoi apply from overwriting runtime plugin changes` (introduced the old pattern)
- Brainstorm: `docs/brainstorms/2026-03-08-marketplace-sync-brainstorm.md`
- Plan: `docs/plans/2026-03-08-refactor-declarative-marketplace-sync-plan.md`
- chezmoi GitHub discussion #3550: `plugin_` attribute proposal (declined)
- chezmoi GitHub issue #1625: DB lock when running chezmoi commands inside scripts
