---
id: instinct-snapshot-before-push
trigger: when preparing to push changes that involve the auto-promote CI workflow
confidence: 0.7
domain: workflow
source: session-observation
scope: project
project_id: 23e6ae2f0a00
project_name: chezmoi
---

# Snapshot Instincts Before Push for CI

## Action
Run `scripts/snapshot-instincts.sh` before pushing to ensure the auto-promote CI workflow has fresh instinct data to process. The snapshot copies instinct files from `~/.claude/homunculus/` to `dot_claude/instinct-snapshots/` in the source tree. CI validates snapshot freshness (14-day max age).

## Evidence
- Observed 3+ times in session 4937b2e4 (2026-04-05)
- Pattern: Snapshot script developed and tested as part of auto-promote workflow
- validate-instinct-snapshot.sh enforces freshness, count (>= 5), and format
- Last observed: 2026-04-05
