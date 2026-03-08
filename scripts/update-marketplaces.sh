#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${REPO_ROOT}/dot_claude/plugins/marketplaces.txt"

if ! command -v claude &>/dev/null; then
  echo "error: claude CLI not found" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "error: jq not found" >&2
  exit 1
fi

claude plugin marketplace list --json \
  | jq -r '.[] | if .source == "github" then .repo else .url end' \
  | sort \
  > "$TARGET"

echo "Updated ${TARGET} ($(wc -l < "$TARGET" | tr -d ' ') marketplaces)"
