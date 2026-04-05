#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${REPO_ROOT}/darwin/Brewfile"

if ! command -v brew &>/dev/null; then
    echo "error: brew not found" >&2
    exit 1
fi

brew bundle dump --force --no-vscode --no-go --file="$TARGET"

echo "Updated ${TARGET} ($(wc -l <"$TARGET" | tr -d ' ') entries)"
