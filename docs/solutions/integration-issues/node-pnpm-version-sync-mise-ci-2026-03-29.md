---
title: Synchronizing node/pnpm versions between mise and GitHub Actions CI
date: 2026-03-29
category: integration-issues
module: ci-local-version-sync
problem_type: integration_issue
component: development_workflow
symptoms:
  - "pnpm version drift between local mise config (latest) and CI (pinned v10)"
  - "Node version maintained in two separate places (mise config.toml and CI workflow)"
  - "New CI jobs (oxlint/oxfmt) introduced with same unsynchronized hardcoded versions"
root_cause: config_error
resolution_type: config_change
severity: medium
tags:
  - mise
  - pnpm
  - node-version
  - github-actions
  - version-pinning
  - chezmoi
  - ci-local-parity
---

# Synchronizing node/pnpm versions between mise and GitHub Actions CI

## Problem

Node.js and pnpm versions were maintained independently in local development (mise `config.toml`) and CI (GitHub Actions `lint.yml`), with `pnpm = "latest"` guaranteeing drift on the next pnpm major release.

## Symptoms

- `pnpm = "latest"` in mise config vs `version: 10` in CI -- pnpm 11 release would break `pnpm install --frozen-lockfile` in CI due to lockfileVersion incompatibility
- Node `"24"` hardcoded in both `config.toml` and `lint.yml` -- two places to update on every major bump
- No `packageManager` field in `package.json` -- the standard mechanism for pnpm version pinning was absent

## What Didn't Work

- **corepack**: Rejected because it activates globally and would affect all Node projects on the machine. Blast radius too large for a dotfiles repo.
- **mise reading `packageManager` from `package.json`**: Not supported. mise has no built-in mechanism to extract the pnpm version from the `packageManager` field, so two-source pnpm management is unavoidable with current tooling.
- **True single-source pnpm**: Impossible today. The best achievable state is exact-version pinning in both locations with Renovate updating at least the CI side automatically.

## Solution

Five changes, plus one discovered during rebase:

1. **Created `.node-version`** containing `24`. Both mise (via `idiomatic_version_file_enable_tools`) and `actions/setup-node` (via `node-version-file` input) read this file natively.

2. **Added `"packageManager": "pnpm@10.28.0"` to `package.json`**. `pnpm/action-setup` v5 reads this field automatically when its `version` input is omitted. Renovate's `npm` manager auto-updates it.

3. **Changed `pnpm = "latest"` to `pnpm = "10.28.0"` in mise `config.toml`**. Eliminates guaranteed drift -- local and CI now start from the same exact version.

4. **Updated `lint.yml`**: removed `version: 10` from `pnpm/action-setup`, changed `node-version: "24"` to `node-version-file: '.node-version'` in `actions/setup-node`.

5. **Added `.node-version` to `.chezmoiignore`**. Repo-only file that should not be deployed to `~/` by `chezmoi apply`.

6. **During rebase, new oxlint/oxfmt CI jobs** were discovered with hardcoded versions. These received the same treatment.

## Why This Works

- **Node**: `.node-version` is the single source of truth. mise reads it locally via idiomatic version file support. CI reads it via `node-version-file`. One file, zero duplication.
- **pnpm**: `packageManager` in `package.json` controls CI (Renovate auto-updates it). `config.toml` controls local. Two sources remain, but both are pinned to exact versions -- no more `"latest"` introducing uncontrolled drift.
- **Exact pinning** (`10.28.0` instead of `"latest"` or `10`) means drift only happens when one side is explicitly updated, not on every upstream release.

## Prevention

- **New CI jobs using pnpm/node** must use `node-version-file: '.node-version'` and omit the `version` input from `pnpm/action-setup` -- never hardcode versions in workflow YAML.
- **Never use `"latest"` in mise config** for tools that need CI parity. Always pin to an exact version.
- **Repo-only files in chezmoi repos** (like `.node-version`) need `.chezmoiignore` entries to prevent deployment to `~/`.
- **oxfmt may reorder JSON keys** -- after editing `package.json`, run `make lint` to catch formatting changes before committing.
- **When rebasing across CI changes**, check whether new workflow jobs introduced hardcoded versions that need the same single-source treatment.

## Related Issues

- `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md` -- documents the same CI infrastructure (lint.yml, Makefile, pnpm)
- `docs/solutions/developer-experience/chezmoi-oxlint-oxfmt-lint-pipeline-gotchas-2026-03-29.md` -- pnpm tool resolution patterns relevant to version management
- `docs/solutions/integration-issues/renovate-managerfilepatterns-regex-delimiter.md` -- Renovate config for mise/npm dependency management
