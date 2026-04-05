---
id: pr-workflow-for-all-changes
trigger: when pushing changes to the repository, including automated CI workflows
confidence: 0.85
domain: git
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# All Changes Must Go Through PR Workflow

## Action
Never push directly to main branch. Always create a feature branch and open a PR, even for automated changes from CI workflows (auto-promote, harness-remediate). Main branch has protection rules requiring PR review.

## Evidence
- Observed 4+ times in session 4937b2e4 (2026-04-05)
- Pattern: auto-promote workflow initially designed to push directly to main, had to be redesigned to create PRs instead
- User explicitly stated: main branch には直接 push することを禁止する ruleset を設定している
- Solution documented in docs/solutions/integration-issues/ci-workflow-branch-protection-requires-pr-flow-2026-04-05.md
- Last observed: 2026-04-05
