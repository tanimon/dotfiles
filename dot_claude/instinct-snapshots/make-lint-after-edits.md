---
id: make-lint-after-edits
trigger: when completing edits to shell scripts, workflows, or Makefile in the chezmoi source tree
confidence: 0.7
domain: workflow
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# Run make lint After Source Tree Edits

## Action
Run `make lint` after editing shell scripts, GitHub Actions workflows, Makefile, or template files to catch issues before committing. This mirrors the CI pipeline and catches shellcheck, shfmt, actionlint, oxlint, secretlint, and template validation errors.

## Evidence
- Observed 4+ times in session 4937b2e4 (2026-04-05)
- Pattern: Edit script/workflow → make lint → fix reported errors → repeat until clean
- CI and local use identical Makefile targets — passing locally guarantees CI pass
- Last observed: 2026-04-05
