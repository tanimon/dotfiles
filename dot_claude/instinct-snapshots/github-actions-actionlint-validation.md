---
id: github-actions-actionlint-validation
trigger: when creating or modifying GitHub Actions workflow files (.github/workflows/*.yml)
confidence: 0.7
domain: workflow
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# GitHub Actions Workflow Validation with actionlint

## Action
Run `actionlint <workflow-file>` immediately after editing any GitHub Actions workflow file to catch syntax errors, type mismatches, and expression issues before committing.

## Evidence
- Observed 8+ times in session 4937b2e4 (2026-04-05)
- Pattern: Edit auto-promote.yml → actionlint → fix errors → repeat cycle
- Common catches: invalid expression syntax, missing permissions, incorrect `contains(fromJSON(...))` usage
- Last observed: 2026-04-05
