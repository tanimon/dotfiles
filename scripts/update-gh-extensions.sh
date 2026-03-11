#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${REPO_ROOT}/dot_config/gh/extensions.txt"

if ! command -v gh &>/dev/null; then
  echo "error: gh CLI not found" >&2
  exit 1
fi

gh extension list \
  | awk -F'\t' '{print $2}' \
  | sort \
  > "$TARGET"

echo "Updated ${TARGET} ($(wc -l < "$TARGET" | tr -d ' ') extensions)"
