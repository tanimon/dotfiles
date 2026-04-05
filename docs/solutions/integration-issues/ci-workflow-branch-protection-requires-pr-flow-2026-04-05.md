---
title: CI workflows must use PR flow when branch protection prevents direct pushes to main
date: 2026-04-05
category: integration-issues
module: harness
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - CI workflow creates or modifies code and needs to push changes
  - Repository has GitHub ruleset or branch protection preventing direct pushes to main
  - Workflow uses claude-code-action or similar automation to generate commits
tags:
  - github-actions
  - branch-protection
  - ci-workflow
  - auto-promote
  - harness-engineering
---

# CI workflows must use PR flow when branch protection prevents direct pushes to main

## Context

When designing GitHub Actions workflows that create or promote code (instinct promotion, dependency updates, automated fixes), there are two common approaches: direct push to main, or branch + PR creation. Most repositories with security guardrails enforce branch protection rules that prohibit direct pushes to main — even from workflows with `contents: write` permission.

The auto-promote instinct workflow (`auto-promote.yml`) was initially designed with two paths: low-risk promotions push directly to main (`git push origin main`), high-risk create PRs. After implementation was complete (6 units done, PR created, code review completed), the user pointed out the repository has a GitHub ruleset preventing direct pushes to main. The workflow would have failed silently at the push step for low-risk candidates.

This was preventable — branch protection settings should have been checked during the planning phase.

## Guidance

**Never design workflows with `git push origin main`. Always create a branch and PR.**

1. **Always create a feature branch** for workflow-generated changes:
   ```bash
   BRANCH="chore/auto-promote-${GITHUB_RUN_ID}"
   git checkout -b "$BRANCH"
   git add .
   git commit -m "chore: auto-promote instinct X"
   git push -u origin "$BRANCH"
   ```

2. **Always open a PR** via `gh pr create`:
   ```bash
   gh pr create \
     --title "chore: auto-promote instinct X" \
     --body "Automated promotion..." \
     --base main
   ```

3. **Use risk tiers to differentiate review requirements, not push targets.** Low-risk changes get "auto-merge eligible" PRs; high-risk changes get PRs requiring human review. Both go through the PR gate.

4. **Add an explicit "never push to main" rule** in claude-code-action prompts:
   ```
   - NEVER push directly to main — main branch is protected. Always create a feature branch and PR.
   ```

## Why This Matters

- **Security by default** — Branch protection rules are security controls. Workflows bypassing them create audit gaps.
- **Consistency** — If some changes go through PRs and others bypass protection, reviewers lose visibility on what was actually deployed.
- **Future-proof** — A repository may gain stricter protection rules later (require approvals, specific reviewers). Branch+PR workflows adapt automatically; direct-push workflows break.
- **Silent failure risk** — `git push origin main` with branch protection doesn't error loudly in all contexts. The push step may fail but the workflow may continue or report ambiguous status.

## When to Apply

- Any GitHub Actions workflow that creates, modifies, or promotes code
- Instinct/rule promotion pipelines
- Dependency update automation (Renovate already uses PRs)
- Automated fixes from claude-code-action (harness-auto-remediate, auto-promote)
- Code generation or migration workflows

**Exception:** Read-only workflows (queries, analysis, reporting) that don't create commits don't need this.

## Examples

**Before (fails on branch protection):**
```yaml
# In claude-code-action prompt:
git checkout main
git commit -am "chore: promote instinct"
git push origin main  # BLOCKED by branch protection
```

**After (works with branch protection):**
```yaml
# In claude-code-action prompt:
git checkout -b chore/auto-promote-<id>
git commit -am "chore: promote instinct"
git push -u origin HEAD
gh pr create --title "chore: auto-promote instinct" --base main
```

## Prevention

- **Planning checklist item:** When designing CI workflows that push commits, check the target repository's branch protection rules (`gh api repos/{owner}/{repo}/rulesets` or Settings → Rules → Rulesets).
- **Default to PR flow:** Treat branch+PR as the default pattern for all CI-generated changes. Only consider direct push as an optimization after confirming no protection rules exist — and even then, PR flow is safer.
- **Prompt hardening:** Include explicit "never push to main" instructions in any claude-code-action prompt that has write access.

## Related

- `docs/solutions/integration-issues/github-actions-security-alert-workflow-pitfalls-2026-04-02.md` — Related CI workflow design patterns
- `docs/solutions/integration-issues/github-actions-workflow-consolidation-and-fork-guards-2026-03-31.md` — Workflow guard patterns
- `docs/solutions/integration-issues/claude-code-review-workflow-tool-permissions-2026-03-29.md` — Two-layer permission model
- `.github/workflows/auto-promote.yml` — The workflow that prompted this learning
- `docs/plans/2026-04-05-001-feat-closed-loop-rule-auto-promote-plan.md` — Plan document (R6 updated)
