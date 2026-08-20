#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATTERNS_FILE="${SENSITIVE_PATTERNS:-${SCRIPT_DIR}/sensitive-patterns.txt}"
ALLOWLIST_FILE="${SENSITIVE_ALLOWLIST:-${SCRIPT_DIR}/sensitive-allowlist.txt}"
LOCAL_PATTERNS_FILE="${SENSITIVE_PATTERNS_LOCAL:-${SCRIPT_DIR}/sensitive-patterns.local.txt}"

if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "error: patterns file not found: ${PATTERNS_FILE}" >&2
    exit 1
fi

# Read non-comment, non-blank lines from a patterns or allowlist file.
# A missing file yields nothing: both the allowlist and the local patterns
# file are optional.
read_entries() {
    local file=$1 line
    [[ -f $file ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*# ]] && continue
        [[ -z ${line//[[:space:]]/} ]] && continue
        printf '%s\n' "$line"
    done <"$file"
}

# Escape everything that is not alphanumeric/underscore/hyphen so a literal
# identity string is safe to hand to `grep -E`.
regex_escape() {
    printf '%s' "$1" | sed 's/[^A-Za-z0-9_-]/\\&/g'
}

# Identity strings (the work GitHub org, the local account name) are deliberately
# NOT stored in this repo: they identify the user and their employer, and this
# repo is public. They are resolved from the machine at scan time instead, so the
# guard needs nothing committed.
#
# Each resolver honours an override that, when *set* — even to empty — wins
# verbatim. Set-but-empty means "skip this one", which is how CI runs and how the
# tests stay hermetic; unset falls through to the machine lookup.
#
# Resolvers report through two globals rather than stdout, because a `$(...)`
# capture would run them in a subshell and lose the note.
resolved_value=""
resolved_note=""

# Account names that belong to a CI runner or container image rather than a
# person. Each is also an ordinary English word that appears legitimately all
# over this repo ("runner" in .github/ and docs/, "node" in .node-version and
# every pnpm discussion), so treating one as an identity to hunt for turns the
# scan red for a bogus reason. Only the auto-resolved path is filtered — an
# explicit SENSITIVE_LOCAL_USER always wins, so this cannot mask a real name
# someone deliberately asked to guard.
GENERIC_ACCOUNT_NAMES="runner runneradmin root ubuntu debian admin administrator user node vscode builder build jenkins circleci codespace nobody"

# From `chezmoi data`'s .ghOrg, which every machine that ran `chezmoi init`
# already answered.
resolve_work_org() {
    resolved_value=""
    resolved_note="SENSITIVE_WORK_ORG / chezmoi .ghOrg"
    if [[ -n ${SENSITIVE_WORK_ORG+set} ]]; then
        resolved_value=$SENSITIVE_WORK_ORG
        return 0
    fi
    command -v chezmoi >/dev/null 2>&1 || return 0
    command -v jq >/dev/null 2>&1 || return 0
    resolved_value=$(chezmoi data 2>/dev/null | jq -r '.ghOrg // empty' 2>/dev/null || true)
}

# From `id -un`. Catches the account name in forms the path-shaped patterns
# cannot see — most notably Claude Code's project slug, where `/Users/<user>/`
# is flattened to `-Users-<user>-` and so never matches `/Users/...`.
#
# Only the *current* account name is derivable. A previous account name (after a
# macOS rename) or a real name the system does not store has no machine source
# and must go in the gitignored scripts/sensitive-patterns.local.txt.
resolve_local_user() {
    resolved_value=""
    resolved_note="SENSITIVE_LOCAL_USER / id -un"
    if [[ -n ${SENSITIVE_LOCAL_USER+set} ]]; then
        resolved_value=$SENSITIVE_LOCAL_USER
        return 0
    fi
    local name lower
    name=$(id -un 2>/dev/null || true)
    lower=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
    case " ${GENERIC_ACCOUNT_NAMES} " in
    *" ${lower} "*)
        resolved_note="id -un returned the generic account name of a CI runner or container, ignored"
        return 0
        ;;
    esac
    resolved_value=$name
}

# Patterns come in two report modes.
#
#   show   — the matching line is printed. Correct when the pattern describes a
#            *shape* (an absolute path, a key header): seeing the offending text
#            is what makes the finding actionable, and printing it reveals
#            nothing the file did not already contain.
#   redact — only `file:line` is printed. Required when the matched text IS the
#            secret: this scanner runs in CI on a public repo, so a `show`-mode
#            report would copy the guarded string straight into a public Actions
#            log — the guard leaking exactly what it guards. Also matched
#            case-insensitively.
#
# Redaction applies to the matched *content*; whether the *pattern* can be
# labelled is a separate question. A `@redact ` pattern from the committed
# sensitive-patterns.txt is already public, so it is named in the report — that
# is what distinguishes its findings from the ones whose pattern is itself a
# secret (the work org name, the local patterns file), which report an opaque
# label. Without that distinction two guards firing on one line look like one
# duplicated finding.
show_patterns=()
redact_patterns=()
redact_labels=()
while IFS= read -r entry; do
    if [[ $entry == '@redact '* ]]; then
        redact_patterns+=("${entry#@redact }")
        redact_labels+=("${entry#@redact } (match redacted)")
    else
        show_patterns+=("$entry")
    fi
done < <(read_entries "$PATTERNS_FILE")

if [[ $((${#show_patterns[@]} + ${#redact_patterns[@]})) -eq 0 ]]; then
    echo "error: no patterns found in ${PATTERNS_FILE}" >&2
    exit 1
fi

# The optional local patterns file holds strings that are themselves secrets,
# so its entries are always redact mode and stay unnamed.
while IFS= read -r entry; do
    redact_patterns+=("$entry")
    redact_labels+=('<redacted: local pattern>')
done < <(read_entries "$LOCAL_PATTERNS_FILE")

# Bare name, anywhere: a prose mention ("<org> の worktree では…", "<user> の
# メモリ") has no shape for a path-style pattern to latch onto.
#
# skipped_resolvers is named, not counted: with more than one resolver a single
# "something was skipped" message would misdescribe a run where one resolved and
# the other did not.
skipped_resolvers=""

add_identity_pattern() {
    local literal=$1 label=$2 name=$3
    if [[ -z $literal ]]; then
        skipped_resolvers="${skipped_resolvers:+${skipped_resolvers}, }${name}"
        return 0
    fi
    redact_patterns+=("$(regex_escape "$literal")")
    redact_labels+=("$label")
}

resolve_work_org
add_identity_pattern "$resolved_value" '<redacted: work org name>' "work org (${resolved_note})"

resolve_local_user
add_identity_pattern "$resolved_value" '<redacted: local username>' "local username (${resolved_note})"

# Allowlist entries are `<path-suffix or *>:<extended regex>`, split on the
# FIRST colon. A match is suppressed when the scanned path ends with the path
# part (or the part is `*`) and the matching line satisfies the regex.
allow_paths=()
allow_regexes=()
while IFS= read -r entry; do
    allow_paths+=("${entry%%:*}")
    allow_regexes+=("${entry#*:}")
done < <(read_entries "$ALLOWLIST_FILE")

is_allowed() {
    local file=$1 content=$2 i
    [[ ${#allow_paths[@]} -eq 0 ]] && return 1
    for i in "${!allow_paths[@]}"; do
        [[ ${allow_paths[$i]} == '*' || $file == *"${allow_paths[$i]}" ]] || continue
        printf '%s' "$content" | grep -qE -e "${allow_regexes[$i]}" && return 0
    done
    return 1
}

# Collect files to scan: either from arguments or every file in the repo.
# Scanning is repo-wide rather than *.md-only because the highest-risk places
# for a hardcoded org path are templates and configs (settings.json.tmpl,
# nono profiles, gitconfig), not prose.
files=()
if [[ $# -gt 0 ]]; then
    files=("$@")
else
    # Pruned by name with no -type test: in a git worktree `.git` is a *file*
    # holding an absolute gitdir path, so a `-type d`-guarded prune would miss
    # it and the scanner would flag git's own plumbing.
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$REPO_ROOT" \
        \( -name node_modules -o -name .git -o -name .pnpm-store -o -name .superpowers \) -prune -o \
        -type f -print0 2>/dev/null)
fi

# The pattern and allowlist files hold guarded-looking text by construction,
# and pnpm-lock.yaml is generated noise. Matched by basename, so a document
# that happens to share one of these names is skipped too — acceptable for
# names this specific.
scannable=()
for f in "${files[@]:-}"; do
    [[ -n $f ]] || continue
    case "${f##*/}" in
    sensitive-patterns.txt | sensitive-patterns.local.txt | sensitive-allowlist.txt) continue ;;
    pnpm-lock.yaml) continue ;;
    esac
    scannable+=("$f")
done

if [[ ${#scannable[@]} -eq 0 ]]; then
    echo "No files to scan"
    exit 0
fi

found=0
header_printed=0

report_header() {
    if [[ $header_printed -eq 0 ]]; then
        echo "=== Sensitive information detected ===" >&2
        header_printed=1
    fi
}

# $1 = pattern, $2 = "show" (print the matching line) or "redact" (file:line
# only), $3 = label to print as the finding's heading
scan_pattern() {
    local pattern=$1 mode=$2 label=$3
    local -a gflags=(-I -E)
    if [[ $mode == redact ]]; then
        gflags+=(-i)
    fi

    # Two passes so the per-file pass never has to parse a filename out of
    # grep -H output (paths may contain colons; line content certainly does).
    local -a hits=()
    local f
    while IFS= read -r f; do
        hits+=("$f")
    done < <(grep -l "${gflags[@]}" -e "$pattern" -- "${scannable[@]}" 2>/dev/null || true)
    [[ ${#hits[@]} -eq 0 ]] && return 0

    local pattern_printed=0 match lineno content rel
    for f in "${hits[@]}"; do
        while IFS= read -r match; do
            lineno=${match%%:*}
            content=${match#*:}
            is_allowed "$f" "$content" && continue
            rel=${f#"$REPO_ROOT"/}
            report_header
            if [[ $pattern_printed -eq 0 ]]; then
                printf '\nPattern: %s\n' "$label" >&2
                pattern_printed=1
            fi
            if [[ $mode == redact ]]; then
                printf '%s:%s\n' "$rel" "$lineno" >&2
            else
                printf '%s:%s:%s\n' "$rel" "$lineno" "$content" >&2
            fi
            found=1
        done < <(grep -n "${gflags[@]}" -e "$pattern" -- "$f" 2>/dev/null || true)
    done
}

for pattern in "${show_patterns[@]:-}"; do
    [[ -n $pattern ]] || continue
    scan_pattern "$pattern" show "$pattern"
done

if [[ ${#redact_patterns[@]} -gt 0 ]]; then
    for i in "${!redact_patterns[@]}"; do
        scan_pattern "${redact_patterns[$i]}" redact "${redact_labels[$i]}"
    done
fi

# Say it out loud rather than passing vacuously: an unresolved identity means
# that guard did not run at all, and a silent exit 0 would read as "clean"
# instead of "part of the check was skipped". Expected in CI, which has no
# chezmoi config; the enforcement point for these patterns is the local
# pre-commit hook and `just lint`.
if [[ -n $skipped_resolvers ]]; then
    echo "NOTE: identity pattern(s) skipped, unresolved: ${skipped_resolvers}" >&2
fi

if [[ $found -eq 1 ]]; then
    echo "" >&2
    echo "Fix: replace real usernames/paths with placeholders (\$HOME, ~, <username>);" >&2
    echo "     for org paths use the chezmoi template variable instead of a literal" >&2
    echo "     (see dot_claude/settings.json.tmpl for the intended form);" >&2
    echo "     if the match is intentionally public, add it to scripts/sensitive-allowlist.txt" >&2
    exit 1
fi

echo "No sensitive information found in ${#scannable[@]} file(s)"
exit 0
