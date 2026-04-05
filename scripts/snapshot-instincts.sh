#!/usr/bin/env bash
set -euo pipefail

# Snapshot ECC instinct files from ~/.claude/homunculus/ to the chezmoi source tree.
# CI workflows read the snapshot (not the live directory) for instinct promotion.
# Run this locally before pushing to keep the snapshot fresh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_DIR="${REPO_ROOT}/dot_claude/instinct-snapshots"
HOMUNCULUS_DIR="${HOME}/.claude/homunculus"

# --- Tool guards ---

if ! command -v jq >/dev/null 2>&1; then
    echo "WARNING: jq not found, skipping" >&2
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    echo "WARNING: git not found, skipping" >&2
    exit 0
fi

# --- Project discovery (mirrors pipeline-health.sh) ---

discover_project_id() {
    local remote_url
    remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$remote_url" ]]; then
        remote_url="$(printf '%s' "$remote_url" | sed -E 's|://[^@]+@|://|')"
        if command -v shasum >/dev/null 2>&1; then
            printf '%s' "$remote_url" | shasum -a 256 | cut -c1-12
            return 0
        elif command -v sha256sum >/dev/null 2>&1; then
            printf '%s' "$remote_url" | sha256sum | cut -c1-12
            return 0
        fi
    fi

    local repo_root
    repo_root="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$repo_root" ]]; then
        if command -v shasum >/dev/null 2>&1; then
            printf '%s' "$repo_root" | shasum -a 256 | cut -c1-12
            return 0
        elif command -v sha256sum >/dev/null 2>&1; then
            printf '%s' "$repo_root" | sha256sum | cut -c1-12
            return 0
        fi
    fi

    return 1
}

# --- Discover project ---

project_id="$(discover_project_id)" || {
    echo "WARNING: could not determine project ID, skipping" >&2
    exit 0
}

instinct_source="${HOMUNCULUS_DIR}/projects/${project_id}/instincts/personal"

if [[ ! -d "$instinct_source" ]]; then
    echo "WARNING: no instinct directory at ${instinct_source}" >&2
    exit 0
fi

# --- Validate frontmatter fields ---

has_required_frontmatter() {
    local file="$1"
    # Check for required fields in YAML frontmatter: id, trigger, confidence, domain
    local in_frontmatter=false
    local has_id=false has_trigger=false has_confidence=false has_domain=false

    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then
                break
            else
                in_frontmatter=true
                continue
            fi
        fi
        if $in_frontmatter; then
            [[ "$line" =~ ^id: ]] && has_id=true
            [[ "$line" =~ ^trigger: ]] && has_trigger=true
            [[ "$line" =~ ^confidence: ]] && has_confidence=true
            [[ "$line" =~ ^domain: ]] && has_domain=true
        fi
    done <"$file"

    $has_id && $has_trigger && $has_confidence && $has_domain
}

# --- Snapshot ---

mkdir -p "$SNAPSHOT_DIR"
# Clean previous snapshot
find "$SNAPSHOT_DIR" -name '*.md' -delete 2>/dev/null || true
rm -f "${SNAPSHOT_DIR}/metadata.json"

copied=0
skipped=0

for instinct_file in "$instinct_source"/*.md; do
    [[ -f "$instinct_file" ]] || continue

    if has_required_frontmatter "$instinct_file"; then
        cp "$instinct_file" "$SNAPSHOT_DIR/"
        copied=$((copied + 1))
    else
        echo "WARNING: skipping $(basename "$instinct_file") (missing required frontmatter)" >&2
        skipped=$((skipped + 1))
    fi
done

if [[ $copied -eq 0 ]]; then
    echo "WARNING: no valid instinct files found in ${instinct_source}" >&2
fi

# --- Derive project name ---

project_name="$(basename "$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "unknown")")"

# --- Write metadata ---

jq -n \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project_id "$project_id" \
    --arg project_name "$project_name" \
    --argjson instinct_count "$copied" \
    '{timestamp: $timestamp, project_id: $project_id, project_name: $project_name, instinct_count: $instinct_count}' \
    >"${SNAPSHOT_DIR}/metadata.json"

echo "Snapshot complete: ${copied} instincts copied, ${skipped} skipped"
echo "  Location: ${SNAPSHOT_DIR}"
echo "  Metadata: ${SNAPSHOT_DIR}/metadata.json"
