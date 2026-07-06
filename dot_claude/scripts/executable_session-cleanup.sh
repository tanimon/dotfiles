#!/usr/bin/env bash
# SessionStart hook: Clean up stale session flag files from /tmp.
# Deletes flag files older than 1 day for both current and legacy patterns.
set -euo pipefail

# Cleanup is best-effort: find may hit permission errors on other users' /tmp
# files, which must not fail the hook (exit code contract: exit 0 on skip).
find /tmp -maxdepth 1 \( -name "claude-learning-briefing-*" -o -name "claude-harness-checked-*" \) -mtime +0 -delete 2>/dev/null || true
