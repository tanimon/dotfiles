#!/usr/bin/env bash
set -euo pipefail

# Gather the read-only context needed to reason about the current branch or its
# pull request, in one command instead of the five-call chain that 43 of 189
# recorded sessions in this repo re-typed by hand:
#
#   git fetch -q origin main; git rev-parse --abbrev-ref HEAD; git status --short;
#   git merge-base origin/main HEAD; git diff --no-ext-diff --stat origin/main...HEAD
#
# Two details are easy to get wrong when re-typing it, and both are baked in here:
#
#   * `--no-ext-diff` is carried even on `--stat`. This repo sets
#     `diff.external = difft` globally, and a bare `git diff` then emits
#     difftastic's rendering with no `+`/`-` prefixes — any check that greps for
#     them matches nothing and *looks like it passed* (the CLAUDE.md pitfall of
#     the same name). `--stat` does not invoke the external driver today, so the
#     flag is currently redundant; it is here so that widening this to patch
#     output later cannot silently reintroduce the pitfall.
#   * `origin/main...HEAD` (three dots) diffs against the merge base, not
#     against whatever main has drifted to since the branch was cut.
#
# Everything this script runs is read-only: no fetch writes to the worktree, no
# `gh` subcommand here mutates a PR. It is safe to run at any point.
#
# Usage:
#   bash scripts/pr-context.sh [<base-ref>]     # default: origin/main
#
# Environment:
#   PR_CONTEXT_BASE=<ref>     same as the positional argument
#   PR_CONTEXT_SKIP_FETCH=1   do not contact the remote (offline / sandboxed runs)

BASE="${1:-${PR_CONTEXT_BASE:-origin/main}}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: not inside a git worktree" >&2
    exit 1
fi

# Every skip below is announced by name. A silent skip reads as "clean" and is
# the failure mode this repo keeps re-learning: a check that resolves something
# other than what it appears to still reports green.
section() {
    printf '\n===== %s\n' "$1"
}

section "fetch"
if [[ -n ${PR_CONTEXT_SKIP_FETCH:-} ]]; then
    echo "skipped: PR_CONTEXT_SKIP_FETCH is set"
elif [[ $BASE != */* ]]; then
    echo "skipped: base ref '${BASE}' names no remote"
else
    remote="${BASE%%/*}"
    branch="${BASE#*/}"
    # A fetch failure must not abort the run: offline and sandboxed sessions
    # still want the local half of the context. It is reported, not swallowed.
    if git fetch -q "$remote" "$branch" 2>/dev/null; then
        echo "fetched ${remote} ${branch}"
    else
        echo "WARNING: could not fetch ${remote} ${branch} — local refs may be stale" >&2
        echo "fetch failed (see stderr); continuing with local refs"
    fi
fi

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    echo "error: base ref not found locally: ${BASE}" >&2
    exit 1
fi

section "branch"
git rev-parse --abbrev-ref HEAD

section "worktree status"
# Assigned first, not inlined into a command substitution: `foo "$(git …)"`
# hides a non-zero git exit behind foo's success even under `set -e`.
status=$(git status --short)
if [[ -z $status ]]; then
    echo "clean"
else
    printf '%s\n' "$status"
fi

section "merge-base with ${BASE}"
git merge-base "$BASE" HEAD

section "changed files vs ${BASE}"
stat=$(git diff --no-ext-diff --stat "${BASE}...HEAD")
if [[ -z $stat ]]; then
    echo "no changes"
else
    printf '%s\n' "$stat"
fi

section "pull request"
if ! command -v gh >/dev/null 2>&1; then
    echo "skipped: gh not on PATH"
    exit 0
fi

# `gh pr view` exits non-zero when the branch has no PR, which is an ordinary
# state (a branch before its PR exists), not an error worth aborting on.
if ! pr=$(gh pr view --json number,title,state,isDraft,url 2>/dev/null); then
    echo "no pull request for this branch"
    exit 0
fi
printf '%s\n' "$pr"

section "pull request checks"
if ! checks=$(gh pr checks 2>&1); then
    # `gh pr checks` also exits non-zero when checks are merely failing or still
    # pending, so its output is the answer either way — print it, do not discard it.
    printf '%s\n' "$checks"
    exit 0
fi
printf '%s\n' "$checks"
