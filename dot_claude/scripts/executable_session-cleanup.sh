#!/usr/bin/env bash
# SessionStart hook: Clean up stale session flag files from /tmp.
# Deletes flag files older than 1 day for both current and legacy patterns.

find /tmp -maxdepth 1 \( -name "claude-learning-briefing-*" -o -name "claude-harness-checked-*" \) -mtime +0 -delete 2>/dev/null
true
