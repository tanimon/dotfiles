#!/usr/bin/env bash
# PostToolUse(Write) フック: 資格情報っぽいパスへの書き込みを secretlint に通す。
#
# 対象パスは stdin の JSON(tool_input.file_path)で受け取る。$CLAUDE_FILE という
# 環境変数は存在しない(Claude Code v2.1.282 のバイナリに文字列が無い)。
# 検出時は exit 2 で stderr をモデルに返す。exit 1 だとユーザーにしか見えない。
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v secretlint >/dev/null 2>&1 || exit 0

FILE=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[[ -z "$FILE" ]] && exit 0

case "$FILE" in
*.env | *.env.* | *credentials* | *secret*) ;;
*) exit 0 ;;
esac

if ! OUTPUT=$(secretlint "$FILE" 2>&1); then
    printf 'secretlint: potential secret detected in %s: %s\n' "$FILE" "$OUTPUT" >&2
    exit 2
fi
