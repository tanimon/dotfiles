#!/bin/bash
# Wrapper for notify.mts that works inside cco Seatbelt sandbox.
#
# Same pattern as statusline-wrapper.sh:
# Node.js realpathSync calls lstat($HOME) during module loading with
# --experimental-strip-types, which fails under Seatbelt's deny rule.
# Caching to /tmp avoids the issue since /tmp is outside $HOME.
#
# stdin (JSON from Claude Code hooks) flows through to node unchanged.

src="$HOME/.claude/scripts/notify.mts"
cached="/tmp/claude-notify-${UID}.mts"

# Refresh cached copy only when source is newer or missing
if [[ ! -f "$cached" ]] || [[ "$src" -nt "$cached" ]]; then
    cat "$src" >"$cached" 2>/dev/null || exit 0
fi

exec node --experimental-strip-types "$cached"
