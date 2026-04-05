#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATTERNS_FILE="${SCRIPT_DIR}/sensitive-patterns.txt"

if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "error: patterns file not found: ${PATTERNS_FILE}" >&2
    exit 1
fi

# Collect files to scan: either from arguments or default to docs/ directory
files=()
if [[ $# -gt 0 ]]; then
    files=("$@")
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$REPO_ROOT" -type f -name '*.md' -not -path '*/node_modules/*' -not -path '*/.git/*' -print0 2>/dev/null)
fi

if [[ ${#files[@]} -eq 0 ]]; then
    echo "No files to scan"
    exit 0
fi

# Read patterns from file, skipping comments and blank lines
patterns=()
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    patterns+=("$line")
done <"$PATTERNS_FILE"

if [[ ${#patterns[@]} -eq 0 ]]; then
    echo "error: no patterns found in ${PATTERNS_FILE}" >&2
    exit 1
fi

found=0

for pattern in "${patterns[@]}"; do
    # grep -E for extended regex, -n for line numbers, -H for filename
    # Use || true to prevent set -e from exiting on no-match
    matches=$(grep -EnH "$pattern" "${files[@]}" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
        if [[ $found -eq 0 ]]; then
            echo "=== Sensitive information detected ===" >&2
        fi
        echo "" >&2
        echo "Pattern: $pattern" >&2
        echo "$matches" >&2
        found=1
    fi
done

if [[ $found -eq 1 ]]; then
    echo "" >&2
    echo "Fix: replace real usernames/paths with placeholders (\$HOME, ~, <username>)" >&2
    exit 1
fi

echo "No sensitive information found in ${#files[@]} file(s)"
exit 0
