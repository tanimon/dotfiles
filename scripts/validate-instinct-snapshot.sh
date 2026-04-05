#!/usr/bin/env bash
set -euo pipefail

# Validate an instinct snapshot before CI promotion.
# Checks: metadata.json presence, freshness (14 days), count >= 5, frontmatter fields.
# Outputs JSON to stdout: {"status": "ok"|"failed", ...}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_DIR="${REPO_ROOT}/dot_claude/instinct-snapshots"
MAX_AGE_DAYS=14
MIN_COUNT=5

fail() {
    printf '{"status":"failed","reason":"%s"}\n' "$1"
    exit 1
}

# --- Check metadata.json ---

METADATA="${SNAPSHOT_DIR}/metadata.json"

if [[ ! -f "$METADATA" ]]; then
    fail "no metadata.json"
fi

if ! command -v jq >/dev/null 2>&1; then
    fail "jq not available"
fi

timestamp="$(jq -r '.timestamp // empty' "$METADATA")"
if [[ -z "$timestamp" ]]; then
    fail "metadata.json missing timestamp field"
fi

meta_count="$(jq -r '.instinct_count // 0' "$METADATA")"

# --- Check freshness ---

if date -d "2000-01-01" >/dev/null 2>&1; then
    # GNU date
    snapshot_epoch="$(date -d "$timestamp" +%s 2>/dev/null || echo 0)"
else
    # macOS date
    snapshot_epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo 0)"
fi

now_epoch="$(date +%s)"
age_days=$(((now_epoch - snapshot_epoch) / 86400))

if [[ $age_days -gt $MAX_AGE_DAYS ]]; then
    fail "snapshot stale (${age_days} days old, max ${MAX_AGE_DAYS})"
fi

# --- Count actual instinct files ---

actual_count=0
if [[ -d "$SNAPSHOT_DIR" ]]; then
    while IFS= read -r -d '' _; do
        actual_count=$((actual_count + 1))
    done < <(find "$SNAPSHOT_DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null)
fi

if [[ "$meta_count" -ne "$actual_count" ]]; then
    fail "count mismatch (metadata says ${meta_count}, found ${actual_count})"
fi

if [[ $actual_count -lt $MIN_COUNT ]]; then
    fail "insufficient instincts (${actual_count} < ${MIN_COUNT})"
fi

# --- Validate frontmatter fields ---

invalid_files=()
for instinct_file in "$SNAPSHOT_DIR"/*.md; do
    [[ -f "$instinct_file" ]] || continue

    in_frontmatter=false
    has_id=false
    has_trigger=false
    has_confidence=false
    has_domain=false

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
    done <"$instinct_file"

    if ! ($has_id && $has_trigger && $has_confidence && $has_domain); then
        invalid_files+=("$(basename "$instinct_file")")
    fi
done

if [[ ${#invalid_files[@]} -gt 0 ]]; then
    invalid_list="$(printf '%s, ' "${invalid_files[@]}")"
    invalid_list="${invalid_list%, }"
    fail "invalid frontmatter in: ${invalid_list}"
fi

# --- Success ---

printf '{"status":"ok","instinct_count":%d,"snapshot_age_days":%d}\n' "$actual_count" "$age_days"
exit 0
