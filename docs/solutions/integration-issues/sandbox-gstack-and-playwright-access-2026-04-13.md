---
title: Sandbox missing ~/.gstack and Playwright Chromium cache for gstack /browse skill
date: 2026-04-13
category: integration-issues
module: sandbox
problem_type: integration_issue
component: tooling
symptoms:
  - "gstack /browse skill fails with permission errors inside safehouse sandbox"
  - "Chromium binary at ~/Library/Caches/ms-playwright/ inaccessible from sandboxed Claude Code"
root_cause: incomplete_setup
resolution_type: config_change
severity: medium
related_components:
  - development_workflow
tags:
  - sandbox
  - safehouse
  - cco
  - seatbelt
  - gstack
  - playwright
  - chromium
  - harness-engineering
---

# Sandbox missing ~/.gstack and Playwright Chromium cache for gstack /browse skill

## Problem

After introducing gstack Claude Code skills (PR #162), the `/browse` skill could not function inside the macOS Seatbelt sandbox. Two distinct access gaps existed: the gstack runtime state directory (`~/.gstack/`) was missing from both sandbox configs (safehouse and cco), and the Playwright Chromium binary cache (`~/Library/Caches/ms-playwright/`) was inaccessible due to the deny-all safehouse policy.

## Symptoms

- gstack `/browse` skill fails with EPERM when trying to write browser state, session artifacts, or caches to `~/.gstack/`
- Chromium cannot launch because the binary at `~/Library/Caches/ms-playwright/chromium-<version>/` is blocked by the sandbox
- Even with `~/.gstack/` allowed, Chromium process IPC and GPU helpers fail without the `chromium-full`/`chromium-headless` sub-profiles

## What Didn't Work

- Adding only `~/.gstack/` to the sandbox configs resolves the state directory access but does not fix Chromium launch. The Playwright binary cache is a separate path (`~/Library/Caches/ms-playwright/`) not covered by any existing safehouse built-in profile.
- Manually adding `~/Library/Caches/ms-playwright` as a path entry would grant file access but miss the Chromium process launch capabilities (`chromium-full`, `chromium-headless`) needed for IPC rendezvous sockets and GPU helpers.

## Solution

Four changes across two sandbox config files:

**`dot_config/safehouse/config.tmpl`** (primary sandbox):
```
# Working directories (read-write)
--add-dirs={{ .chezmoi.homeDir }}/.gstack

# Integrations
--enable=playwright-chrome
```

**`dot_config/cco/allow-paths.tmpl`** (fallback sandbox):
```
# gstack runtime state (browser data, caches, session artifacts)
{{ .chezmoi.homeDir }}/.gstack
# Playwright Chromium binary cache (needed for gstack /browse skill)
{{ .chezmoi.homeDir }}/Library/Caches/ms-playwright:ro
```

The `--enable=playwright-chrome` safehouse module is the key: it covers `~/Library/Caches/ms-playwright` and also implies `chromium-full` and `chromium-headless`, enabling all the Chromium process launch capabilities in a single entry.

## Why This Works

The safehouse sandbox uses a deny-all Seatbelt policy. Any path not explicitly allowed is blocked. `~/.gstack/` needs read-write because gstack writes browser profiles, auth tokens, session queues, and logs there at runtime. The Playwright Chromium binary cache needs read access for the browser executable, plus process-level capabilities (IPC, GPU) that only the safehouse `playwright-chrome` module provides.

For cco (fallback), the Playwright cache is added as `:ro` (read-only) since cco has no equivalent module system for process capabilities. On macOS (where safehouse is primary), the safehouse module handles everything. The cco entry provides path-level parity for Linux fallback, where the Playwright cache path differs (`~/.cache/ms-playwright/`, already covered by the existing `~/.cache` entry).

## Prevention

When adding a new tool to the sandbox, follow this checklist:

1. **Identify the tool's own state directory** (e.g., `~/.gstack/`, `~/.codex/`) and add it to both configs
2. **Trace transitive dependencies** -- does the tool launch sub-processes (browsers, language runtimes, build tools) that have their own cache directories?
3. **Check for safehouse modules** -- run `safehouse --help` and look for a purpose-built module before manually adding paths. Modules bundle path access with process capabilities that manual `--add-dirs` cannot provide
4. **Update both configs in lockstep** -- safehouse (primary) and cco (fallback) must stay in sync

Prior art: The `~/.codex` addition followed the same pattern (see `docs/solutions/runtime-errors/cco-sandbox-codex-mcp-eperm.md`). This class of bug recurs every time a new tool is integrated.

## Related Issues

- `docs/solutions/runtime-errors/cco-sandbox-codex-mcp-eperm.md` -- same class of bug for Codex CLI
- `docs/solutions/integration-issues/migrate-cco-to-agent-safehouse.md` -- safehouse architecture and migration
- `docs/solutions/integration-issues/safehouse-cli-flag-internals-and-config-patterns.md` -- `--add-dirs` and `--enable` internals
- `docs/solutions/integration-issues/chezmoi-external-skill-collection-patterns-2026-04-13.md` -- gstack integration pattern
- PR #162 -- gstack introduction
- PR #165 -- this fix
