#!/usr/bin/env bash
# SessionStart hook: seed a linked git worktree with the files its main
# worktree lists in .worktreeinclude.
#
# .worktreeinclude is git-worktree-runner's convention, but only `gtr new`
# acts on it. Worktrees created any other way (orca, plain `git worktree add`)
# start without the gitignored local files a session needs — CLAUDE.local.md,
# .claude/settings.local.json. This hook fills that gap at session start,
# which also heals worktrees that already exist.
#
# Copy-if-absent, never overwrite: SessionStart fires again on every resume and
# /clear, and Claude Code itself writes .claude/settings.local.json inside the
# worktree whenever the user picks "always allow".
#
# Exit code contract: every skip is exit 0 — this hook must never block a
# session from starting. Stdout becomes the session's additional context, so it
# stays empty unless something was actually copied.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

STDIN_JSON=$(cat) || exit 0
CWD=$(printf '%s' "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
[[ -z "$CWD" || ! -d "$CWD" ]] && exit 0

cd "$CWD" 2>/dev/null || exit 0

# A linked worktree has its own .git dir under the main repo's common dir; in
# the main worktree the two paths are identical. --git-common-dir can come back
# relative to the cwd, so resolve both to physical paths before comparing.
WT_GIT_DIR_RAW=$(git rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_RAW=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
WT_GIT_DIR=$(cd "$WT_GIT_DIR_RAW" 2>/dev/null && pwd -P) || exit 0
GIT_COMMON=$(cd "$GIT_COMMON_RAW" 2>/dev/null && pwd -P) || exit 0
[[ "$WT_GIT_DIR" == "$GIT_COMMON" ]] && exit 0

WORKTREE_ROOT_RAW=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
# Resolve physically: MAIN_ROOT below is derived from a `pwd -P` path, and the
# containment checks in the copy loop compare the two, so both sides have to be
# physical or a symlinked repo path would make every comparison meaningless.
WORKTREE_ROOT=$(cd "$WORKTREE_ROOT_RAW" 2>/dev/null && pwd -P) || exit 0
# For a bare main repo dirname() is not a worktree root, so no .worktreeinclude
# is found there and the guard below exits.
MAIN_ROOT=$(dirname "$GIT_COMMON")
INCLUDE_FILE="$MAIN_ROOT/.worktreeinclude"
[[ -f "$INCLUDE_FILE" ]] || exit 0
[[ "$MAIN_ROOT" == "$WORKTREE_ROOT" ]] && exit 0

cd "$MAIN_ROOT" 2>/dev/null || exit 0

# Patterns expand against the main worktree. nullglob keeps a non-matching
# pattern from being copied as a literal name; dotglob lets * reach dotfiles.
shopt -s nullglob dotglob 2>/dev/null || true

# Splitting the pattern on newlines only. The pattern still has to be left
# unquoted so it globs, but with the default IFS a listed name containing a
# space would be torn into two patterns that match nothing — a silent no-copy.
# A .worktreeinclude line can never contain a newline, so this splits nothing
# while the *results* of globbing are never re-split.
IFS=$'\n'

# Print the physical path of the deepest existing ancestor directory of $1.
# Symlinked components are followed, so the answer is the real directory a read
# or write at $1 would touch — which is what the containment checks below need:
# a symlink reaches outside the repo without the pattern ever spelling "..".
physical_ancestor() {
    local dir parent
    dir=$1
    while [[ ! -d "$dir" ]]; do
        parent=$(dirname "$dir")
        [[ "$parent" == "$dir" ]] && return 1
        dir=$parent
    done
    (cd "$dir" 2>/dev/null && pwd -P)
}

# True when the physical directory $2 is $1 or below it.
is_within() {
    [[ "$2" == "$1" || "$2" == "$1"/* ]]
}

COPIED=""
while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    # gtr's .gitignore-style parse: whole-line comments and blank lines only.
    case "$pattern" in
    '#'*) continue ;;
    esac
    # Trailing whitespace is not part of the pattern, as in .gitignore. With the
    # default IFS word-splitting used to strip it; IFS=$'\n' does not, and
    # [[:space:]] also takes the \r off a CRLF checkout.
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [[ -z "$pattern" ]] && continue

    case "$pattern" in
    .. | ../* | */.. | */../*)
        printf 'worktree-include: refusing pattern with a ".." segment: %s\n' \
            "$pattern" >&2
        continue
        ;;
    esac

    # A leading slash means "anchored at the repo root", as in .gitignore.
    # (gtr reads it as an absolute path and drops the line instead.)
    while [[ "$pattern" == /* ]]; do pattern="${pattern#/}"; done
    [[ -z "$pattern" ]] && continue

    # Left unquoted on purpose: the pattern is a glob to expand. IFS is a
    # newline, so this does not split on spaces inside a listed name.
    # shellcheck disable=SC2086
    for src in $pattern; do
        # Directories are out of scope — only regular files are seeded.
        [[ -f "$src" ]] || continue
        # The ".." check above only sees what the pattern spells. A symlink —
        # the leaf itself, or any directory component the glob walked through —
        # reaches outside the main worktree without one, so refuse anything
        # whose real location is not inside MAIN_ROOT.
        src_dir=$(physical_ancestor "$src") || src_dir=""
        if [[ -L "$src" ]] || [[ -z "$src_dir" ]] || ! is_within "$MAIN_ROOT" "$src_dir"; then
            printf 'worktree-include: refusing %s: it resolves outside the main worktree via a symlink\n' \
                "$src" >&2
            continue
        fi
        dest="$WORKTREE_ROOT/$src"
        # -L as well as -e: a dangling symlink in the worktree is not -e, and
        # cp would write straight through it to wherever it points.
        [[ -e "$dest" || -L "$dest" ]] && continue
        # Checked before mkdir -p, which would otherwise happily create the
        # missing directories on the far side of a symlinked component.
        dest_dir=$(physical_ancestor "$dest") || dest_dir=""
        if [[ -z "$dest_dir" ]] || ! is_within "$WORKTREE_ROOT" "$dest_dir"; then
            printf 'worktree-include: refusing %s: its destination resolves outside the worktree\n' \
                "$src" >&2
            continue
        fi
        mkdir -p "$(dirname "$dest")" || continue
        if cp -p "$src" "$dest" 2>/dev/null; then
            COPIED="$COPIED  $src"$'\n'
        else
            printf 'worktree-include: failed to copy %s\n' "$src" >&2
        fi
    done
done <"$INCLUDE_FILE"

[[ -z "$COPIED" ]] && exit 0

printf 'Seeded this worktree from the main worktree'"'"'s .worktreeinclude:\n'
printf '%s' "$COPIED"
exit 0
