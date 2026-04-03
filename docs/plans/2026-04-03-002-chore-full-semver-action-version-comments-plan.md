---
title: "chore: Use full semver in GitHub Actions hash pin comments"
type: chore
status: completed
date: 2026-04-03
---

# chore: Use full semver in GitHub Actions hash pin comments

## Overview

Update all GitHub Actions workflow files to use full semantic version numbers (e.g., `# v1.2.3`) in hash pin comments instead of major-only versions (e.g., `# v1`). This improves traceability — when reviewing workflows, you can immediately see which exact release a pinned SHA corresponds to.

## Problem Frame

Current hash pin comments use only the major version (e.g., `# v6`, `# v1`, `# v5`), making it impossible to determine the exact release without looking up the SHA. Full semver comments (e.g., `# v6.0.2`) provide immediate version visibility and make Renovate update diffs clearer.

## Requirements Trace

- R1. All `uses:` lines with hash pins must have full semver version comments
- R2. Version comments must match the actual tag that resolves to the pinned SHA
- R3. Renovate must continue to detect and update these pins (no format breakage)

## Scope Boundaries

- Only version comment text changes — no SHA changes, no workflow logic changes
- Does not add new actions or modify workflow behavior

## Context & Research

### SHA-to-Version Mapping

| Action | SHA | Current | Correct |
|--------|-----|---------|---------|
| `actions/checkout` | `de0fac2e4500dabe0009e67214ff5f5447ce83dd` | `# v6` | `# v6.0.2` |
| `actions/setup-node` | `53b83947a5a98c8d113130e565377fae1a50d02f` | `# v6` | `# v6.3.0` |
| `pnpm/action-setup` | `fc06bc1257f339d1d5d8b3a19a8cae5388b55320` | `# v5` | `# v5.0.0` |
| `anthropics/claude-code-action` | `58dbe8ed6879f0d3b02ac295b20d5fdfe7733e0c` | `# v1` | `# v1.0.85` |

### Affected Files

- `.github/workflows/lint.yml` (12 occurrences)
- `.github/workflows/security-alerts.yml` (8 occurrences)
- `.github/workflows/claude.yml` (3 occurrences)
- `.github/workflows/harness-auto-remediate.yml` (2 occurrences)
- `.github/workflows/harness-analysis.yml` (2 occurrences)

### Renovate Compatibility

Renovate's `helpers:pinGitHubActionDigests` preset handles the `action@sha # vX.Y.Z` format natively. Full semver comments are the standard format Renovate produces when it updates pins. No configuration changes needed.

## Key Technical Decisions

- **Full semver, not minor-only**: Use `v6.0.2` not `v6.0` — matches exact tag names and is what Renovate produces on updates

## Implementation Units

- [ ] **Unit 1: Update all version comments to full semver**

**Goal:** Replace all major-only version comments with exact semver versions across all workflow files

**Requirements:** R1, R2, R3

**Dependencies:** None

**Files:**
- Modify: `.github/workflows/lint.yml`
- Modify: `.github/workflows/security-alerts.yml`
- Modify: `.github/workflows/claude.yml`
- Modify: `.github/workflows/harness-auto-remediate.yml`
- Modify: `.github/workflows/harness-analysis.yml`

**Approach:**
- Simple find-and-replace of comment text per SHA:
  - `de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6` → `de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2`
  - `53b83947a5a98c8d113130e565377fae1a50d02f # v6` → `53b83947a5a98c8d113130e565377fae1a50d02f # v6.3.0`
  - `fc06bc1257f339d1d5d8b3a19a8cae5388b55320 # v5` → `fc06bc1257f339d1d5d8b3a19a8cae5388b55320 # v5.0.0`
  - `58dbe8ed6879f0d3b02ac295b20d5fdfe7733e0c # v1` → `58dbe8ed6879f0d3b02ac295b20d5fdfe7733e0c # v1.0.85`

**Test expectation:** none — pure comment text changes with no behavioral impact

**Verification:**
- `grep -r '# v[0-9]\b' .github/workflows/` returns no results (all comments now have full semver)
- `make actionlint` passes
- Workflow YAML remains valid

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Version comment format could break Renovate detection | Verified: `# vX.Y.Z` is Renovate's own standard output format |

## Sources & References

- Renovate `helpers:pinGitHubActionDigests` preset documentation
- SHA-to-tag verification via `git ls-remote` and GitHub API
