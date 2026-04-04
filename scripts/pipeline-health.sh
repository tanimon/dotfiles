#!/usr/bin/env bash
set -euo pipefail

# ECC continuous learning pipeline health monitor.
# Checks three stages: observation capture, observer analysis, instinct creation.
# Outputs human-readable summary (default) or JSON (--json).

HOMUNCULUS_DIR="${HOME}/.claude/homunculus"
STALENESS_DAYS=14
OUTPUT_FORMAT="human"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Check ECC continuous learning pipeline health.

Options:
  --json    Output machine-readable JSON to stdout
  --help    Show this help message
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
    --json)
        OUTPUT_FORMAT="json"
        shift
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

# --- Project discovery ---

discover_project_dir() {
    # Method 1: compute from git remote
    local remote_url
    remote_url="$(git remote get-url origin 2>/dev/null || true)"
    if [[ -n "$remote_url" ]]; then
        # Strip credentials from URL
        remote_url="$(printf '%s' "$remote_url" | sed -E 's|://[^@]+@|://|')"
        local project_id
        if command -v shasum >/dev/null 2>&1; then
            project_id="$(printf '%s' "$remote_url" | shasum -a 256 | cut -c1-12)"
        elif command -v sha256sum >/dev/null 2>&1; then
            project_id="$(printf '%s' "$remote_url" | sha256sum | cut -c1-12)"
        else
            project_id=""
        fi

        if [[ -n "$project_id" ]]; then
            local candidate="${HOMUNCULUS_DIR}/projects/${project_id}"
            if [[ -d "$candidate" ]]; then
                printf '%s' "$candidate"
                return 0
            fi
        fi
    fi

    # Method 2: glob fallback (use first project found)
    local first_project
    first_project="$(find "${HOMUNCULUS_DIR}/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
    if [[ -n "$first_project" ]]; then
        printf '%s' "$first_project"
        return 0
    fi

    return 1
}

# --- Stage checks ---

check_observation_capture() {
    local project_dir="$1"
    local obs_file="${project_dir}/observations.jsonl"

    if [[ ! -f "$obs_file" ]]; then
        echo "broken"
        return
    fi

    # Check file age
    local now
    now="$(date +%s)"
    local mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        mtime="$(stat -f '%m' "$obs_file" 2>/dev/null || echo "0")"
    else
        mtime="$(stat -c '%Y' "$obs_file" 2>/dev/null || echo "0")"
    fi

    local age_days=$(((now - mtime) / 86400))
    if [[ $age_days -ge $STALENESS_DAYS ]]; then
        echo "broken"
        return
    fi

    echo "ok"
}

get_observation_count() {
    local project_dir="$1"
    local obs_file="${project_dir}/observations.jsonl"
    if [[ -f "$obs_file" ]]; then
        wc -l <"$obs_file" | tr -d ' '
    else
        echo "0"
    fi
}

get_observation_age_days() {
    local project_dir="$1"
    local obs_file="${project_dir}/observations.jsonl"
    if [[ ! -f "$obs_file" ]]; then
        echo "-1"
        return
    fi
    local now
    now="$(date +%s)"
    local mtime
    if [[ "$(uname)" == "Darwin" ]]; then
        mtime="$(stat -f '%m' "$obs_file" 2>/dev/null || echo "0")"
    else
        mtime="$(stat -c '%Y' "$obs_file" 2>/dev/null || echo "0")"
    fi
    echo $(((now - mtime) / 86400))
}

check_observer_analysis() {
    local project_dir="$1"
    local log_file="${project_dir}/observer.log"

    if [[ ! -f "$log_file" ]]; then
        echo "broken"
        return
    fi

    # Check if any analysis has been attempted
    if ! grep -q "Analyzing" "$log_file" 2>/dev/null; then
        echo "broken"
        return
    fi

    # Get the last result-bearing line (failed, skipped, or success indicators).
    # "Claude analysis failed" and "Observer cycle skipped" are failure/skip markers.
    # A successful cycle ends without either marker after the last "Analyzing" line.
    # Strategy: find the last "Analyzing" line number, then check if any failure/skip
    # marker appears at a higher line number.
    local last_analyzing
    last_analyzing="$(grep -n "Analyzing" "$log_file" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")"

    local last_failure
    last_failure="$(grep -n -E "Claude analysis failed|Observer cycle skipped" "$log_file" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")"

    if [[ "$last_failure" -ge "$last_analyzing" ]]; then
        echo "broken"
        return
    fi

    echo "ok"
}

get_observer_last_result() {
    local project_dir="$1"
    local log_file="${project_dir}/observer.log"

    if [[ ! -f "$log_file" ]]; then
        echo "unknown"
        return
    fi

    local last_analyzing
    last_analyzing="$(grep -n "Analyzing" "$log_file" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")"

    local last_failure
    last_failure="$(grep -n -E "Claude analysis failed|Observer cycle skipped" "$log_file" 2>/dev/null | tail -1 | cut -d: -f1 || echo "0")"

    if [[ "$last_analyzing" == "0" ]]; then
        echo "unknown"
    elif [[ "$last_failure" -ge "$last_analyzing" ]]; then
        echo "failure"
    else
        echo "success"
    fi
}

check_instinct_creation() {
    local project_dir="$1"
    local instinct_dir="${project_dir}/instincts/personal"

    local count=0
    if [[ -d "$instinct_dir" ]]; then
        count="$(find "$instinct_dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | wc -l | tr -d ' ')"
    fi

    if [[ "$count" -eq 0 ]]; then
        # Only broken if observations exist (pipeline has input but no output)
        local obs_file="${project_dir}/observations.jsonl"
        if [[ -f "$obs_file" ]] && [[ "$(wc -l <"$obs_file" | tr -d ' ')" -gt 0 ]]; then
            echo "broken"
            return
        fi
    fi

    echo "ok"
}

get_instinct_count() {
    local project_dir="$1"
    local instinct_dir="${project_dir}/instincts/personal"
    if [[ -d "$instinct_dir" ]]; then
        find "$instinct_dir" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) 2>/dev/null | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

# --- Main ---

main() {
    # Discover project directory
    local project_dir
    if ! project_dir="$(discover_project_dir)"; then
        if [[ "$OUTPUT_FORMAT" == "json" ]]; then
            emit_json "broken" "broken" "broken" "broken" "0" "-1" "unknown" "0" ""
        else
            echo "=== ECC Learning Pipeline Health ==="
            echo ""
            echo "ERROR: No project data found at ${HOMUNCULUS_DIR}/projects/"
            echo "  The ECC observer may not be configured or has never run."
            echo ""
            echo "Overall: BROKEN"
        fi
        return 0
    fi

    local project_id
    project_id="$(basename "$project_dir")"

    # Run checks
    local obs_status obs_count obs_age
    obs_status="$(check_observation_capture "$project_dir")"
    obs_count="$(get_observation_count "$project_dir")"
    obs_age="$(get_observation_age_days "$project_dir")"

    local analysis_status analysis_result
    analysis_status="$(check_observer_analysis "$project_dir")"
    analysis_result="$(get_observer_last_result "$project_dir")"

    local instinct_status instinct_count
    instinct_status="$(check_instinct_creation "$project_dir")"
    instinct_count="$(get_instinct_count "$project_dir")"

    # Compute overall status
    local overall="healthy"
    if [[ "$obs_status" == "broken" ]] || [[ "$analysis_status" == "broken" ]] || [[ "$instinct_status" == "broken" ]]; then
        overall="broken"
    fi

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        emit_json "$overall" "$obs_status" "$analysis_status" "$instinct_status" \
            "$obs_count" "$obs_age" "$analysis_result" "$instinct_count" "$project_id"
    else
        emit_human "$overall" "$obs_status" "$analysis_status" "$instinct_status" \
            "$obs_count" "$obs_age" "$analysis_result" "$instinct_count" "$project_id"
    fi
}

emit_human() {
    local overall="$1" obs_status="$2" analysis_status="$3" instinct_status="$4"
    local obs_count="$5" obs_age="$6" analysis_result="$7" instinct_count="$8" project_id="$9"

    local status_icon
    if [[ "$overall" == "healthy" ]]; then
        status_icon="HEALTHY"
    else
        status_icon="BROKEN"
    fi

    echo "=== ECC Learning Pipeline Health ==="
    echo "Project: ${project_id}"
    echo ""

    # Stage 1: Observation capture
    local obs_display
    if [[ "$obs_status" == "ok" ]]; then
        obs_display="OK"
    else
        obs_display="BROKEN"
    fi
    echo "1. Observation Capture: ${obs_display}"
    echo "   Observations: ${obs_count}, age: ${obs_age} days"
    if [[ "$obs_status" == "broken" ]]; then
        if [[ "$obs_age" == "-1" ]]; then
            echo "   -> observations.jsonl not found. Is the ECC observer configured?"
        else
            echo "   -> No new observations in ${obs_age} days (threshold: ${STALENESS_DAYS})."
            echo "   -> Run a Claude Code session to generate new observations."
        fi
    fi
    echo ""

    # Stage 2: Observer analysis
    local analysis_display
    if [[ "$analysis_status" == "ok" ]]; then
        analysis_display="OK"
    else
        analysis_display="BROKEN"
    fi
    echo "2. Observer Analysis: ${analysis_display}"
    echo "   Last result: ${analysis_result}"
    if [[ "$analysis_status" == "broken" ]]; then
        echo "   -> Observer analysis is failing. Check observer.log for errors."
        echo "   -> Common cause: ECC observer-loop.sh bug (prompt file deleted before use)."
    fi
    echo ""

    # Stage 3: Instinct creation
    local instinct_display
    if [[ "$instinct_status" == "ok" ]]; then
        instinct_display="OK"
    else
        instinct_display="BROKEN"
    fi
    echo "3. Instinct Creation: ${instinct_display}"
    echo "   Instincts: ${instinct_count}"
    if [[ "$instinct_status" == "broken" ]]; then
        echo "   -> No instincts created despite ${obs_count} observations."
        echo "   -> This is likely caused by upstream observer analysis failures."
    fi
    echo ""

    echo "Overall: ${status_icon}"
}

emit_json() {
    local overall="$1" obs_status="$2" analysis_status="$3" instinct_status="$4"
    local obs_count="$5" obs_age="$6" analysis_result="$7" instinct_count="$8" project_id="$9"

    if ! command -v jq >/dev/null 2>&1; then
        echo '{"error": "jq not found — required for --json output"}' >&2
        exit 1
    fi

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n \
        --arg overall "$overall" \
        --arg project_id "$project_id" \
        --arg timestamp "$timestamp" \
        --arg obs_status "$obs_status" \
        --argjson obs_count "${obs_count}" \
        --argjson obs_age "${obs_age}" \
        --arg analysis_status "$analysis_status" \
        --arg analysis_result "$analysis_result" \
        --arg instinct_status "$instinct_status" \
        --argjson instinct_count "${instinct_count}" \
        '{
            overall_status: $overall,
            project_id: $project_id,
            snapshot_timestamp: $timestamp,
            stages: {
                observation_capture: {
                    status: $obs_status,
                    observation_count: $obs_count,
                    last_write_age_days: $obs_age
                },
                observer_analysis: {
                    status: $analysis_status,
                    last_result: $analysis_result
                },
                instinct_creation: {
                    status: $instinct_status,
                    instinct_count: $instinct_count
                }
            }
        }'
}

main
