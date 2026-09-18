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
# Nothing here changes the worktree, the index, HEAD, or branch state, and no
# `gh` subcommand mutates a PR — so it is safe to run at any point. It is not
# literally side-effect free: `git fetch` updates remote-tracking refs and
# FETCH_HEAD under .git. Keep that boundary when adding to this script; a
# command that writes to the worktree does not belong here.
#
# Usage:
#   bash scripts/pr-context.sh [<base-ref>]     # default: origin/main
#
# Environment:
#   PR_CONTEXT_BASE=<ref>     same as the positional argument
#   PR_CONTEXT_SKIP_FETCH=1   do not contact the remote (offline / sandboxed runs).
#                             Set at all wins, value ignored — `=0` also skips.
#                             Same convention as scripts/scan-sensitive-info.sh.

BASE="${1:-${PR_CONTEXT_BASE:-origin/main}}"

# The exit code alone is not the answer: inside a bare repository or inside a
# `.git` directory, `git rev-parse --is-inside-work-tree` prints "false" and
# exits 0. Checking only the status lets both through, and the run then dies at
# `git status` with a raw "fatal: this operation must be run in a work tree"
# under an already-printed section heading — the unexplained abort this script
# exists to avoid. Assigned first so a non-zero git exit is not hidden.
inside_work_tree=$(git rev-parse --is-inside-work-tree 2>/dev/null) || inside_work_tree=false
if [[ $inside_work_tree != true ]]; then
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
remote="${BASE%%/*}"
branch="${BASE#*/}"
if [[ -n ${PR_CONTEXT_SKIP_FETCH+set} ]]; then
    echo "skipped: PR_CONTEXT_SKIP_FETCH is set"
elif [[ $BASE != */* ]] || ! git remote | grep -qxF "$remote"; then
    # Matched against the real remote list, not just against the presence of a
    # slash: a local branch named `feature/foo` splits into a plausible-looking
    # remote/branch pair, and fetching it would fail for a misleading reason.
    echo "skipped: base ref '${BASE}' names no remote"
else
    # A fetch failure must not abort the run: offline and sandboxed sessions
    # still want the local half of the context. Report it with git's own
    # message — "could not fetch" alone does not say whether the remote is
    # unreachable, the credentials are gone, or the branch was deleted.
    if fetch_error=$(git fetch -q "$remote" "$branch" 2>&1); then
        echo "fetched ${remote} ${branch}"
    else
        echo "WARNING: could not fetch ${remote} ${branch} — local refs may be stale" >&2
        echo "fetch failed; continuing with local refs:"
        printf '%s\n' "$fetch_error"
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
# `git merge-base` prints nothing and exits 1 when the two have no common
# ancestor (an orphan branch, unrelated histories). Left bare, `set -e` aborts
# here under an empty section heading that reads as "the tool found nothing".
if ! merge_base=$(git merge-base "$BASE" HEAD); then
    echo "error: no common ancestor between ${BASE} and HEAD" >&2
    exit 1
fi
printf '%s\n' "$merge_base"

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

# `gh pr view` exits non-zero for two unrelated reasons: the ordinary state of a
# branch that has no PR yet, and a real failure (not logged in, no network, the
# remote is not GitHub). Neither is worth aborting on, but collapsing both into
# "no pull request for this branch" is exactly the silent-skip shape this script
# exists to avoid — the second would read as the first. Print gh's own message
# instead of classifying it; "no pull requests found" and "gh auth login" tell
# the reader apart on their own.
if ! pr=$(gh pr view --json number,title,state,isDraft,url 2>&1); then
    echo "gh pr view exited non-zero — no PR for this branch, or gh could not reach it:"
    printf '%s\n' "$pr"
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
