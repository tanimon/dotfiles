#!/bin/bash
# Wrapper for statusline-command.ts that works inside cco Seatbelt sandbox.
#
# Problem: Node.js realpathSync calls lstat($HOME) during module loading,
# which fails under Seatbelt's (deny file-read* (subpath "$HOME")) rule.
#
# Solution: Cache a copy of the .ts file in /tmp (outside $HOME).
# - /tmp is not under $HOME, so Node's realpathSync won't lstat $HOME.
# - The .ts extension is preserved, so --experimental-strip-types works.
# - cat uses kernel open() (not realpathSync), so it reads the file via
#   Seatbelt's allow rule for ~/.claude.
# - stdin (JSON from Claude Code) flows through to node unchanged.
#
# Why not process substitution <(cat ...)?
#   /dev/fd/N has no .ts extension — Node doesn't strip TypeScript types,
#   causing SyntaxError.

src="$HOME/.claude/statusline-command.ts"
cached="/tmp/claude-statusline-${UID}.ts"

# Refresh cached copy only when source is newer or missing
if [[ ! -f "$cached" ]] || [[ "$src" -nt "$cached" ]]; then
    cat "$src" >"$cached" 2>/dev/null || {
        echo "🤖 Claude"
        exit 0
    }
fi

exec node --experimental-strip-types "$cached"
