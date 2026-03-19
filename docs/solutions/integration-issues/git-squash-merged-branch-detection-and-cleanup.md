---
title: git-clean-squashed script for deleting squash-merged local branches
category: integration-issues
date: 2026-03-20
tags: [git, squash-merge, branch-cleanup, bash, chezmoi, git-subcommand, dan-fabulich-algorithm]
severity: low
modules: [dot_local/bin/git-clean-squashed, chezmoi]
symptoms:
  - "git branch -d fails with 'not fully merged' error for squash-merged branches"
  - "stale local branches accumulate after GitHub squash merges"
  - "git cannot detect squash-merged branches natively due to different commit history"
---

# git-clean-squashed: Detecting and Deleting Squash-Merged Branches

## Problem

After squash-merging PRs on GitHub, local branches cannot be deleted with `git branch -d` because git's merge detection relies on commit history, which differs after squash merge. Users must manually run `git branch -D` for each branch without safety checks, leading to stale branch accumulation.

## Root Cause

`git branch -d` checks if a branch's commits are reachable from HEAD. With squash merge, the original commits are replaced by a single squash commit with a different SHA, so git considers the branch unmerged even though its content is fully integrated into main.

## Solution

A `git-clean-squashed` bash script using the Dan Fabulich algorithm (`git commit-tree` + `git cherry`):

1. For each local branch, find the merge-base with `origin/main`
2. Create a temporary squash commit via `git commit-tree` using the branch's tree on top of the merge-base
3. Use `git cherry` to check if this squash commit's patch-id already exists in `origin/main`
4. If `git cherry` returns `- <hash>` (prefix `-`), the branch content is already in main

```bash
# Core detection algorithm (per branch)
merge_base=$(git merge-base "$BASE_REF" "$branch" 2>/dev/null) || continue
squash_commit=$(git commit-tree "${branch}^{tree}" -p "$merge_base" -m _)
cherry_result=$(git cherry "$BASE_REF" "$squash_commit" 2>/dev/null) || continue

if [[ "$cherry_result" == "- $squash_commit" ]]; then
  # Branch content is fully integrated — safe to delete
  CANDIDATES+=("$branch")
fi
```

### Deployment via chezmoi

The script is deployed as `dot_local/bin/executable_git-clean-squashed` → `~/.local/bin/git-clean-squashed`. The `executable_` prefix ensures chezmoi sets +x on the deployed file. Since `~/.local/bin` is on PATH (via `dot_config/zsh/path.zsh`), git auto-discovers it as the `git clean-squashed` subcommand.

### Usage

```bash
git clean-squashed              # Scan, confirm, delete
git clean-squashed --dry-run    # Preview only
git clean-squashed --force      # Skip confirmation
git clean-squashed --base develop  # Compare against different base
git clean-squashed --no-fetch   # Skip auto-fetch
```

## Key Implementation Details

- **Auto-fetch**: Runs `git fetch --prune --quiet` before scanning to ensure `origin/main` is current. Disable with `--no-fetch`.
- **Fully-qualified refs**: Uses `refs/remotes/origin/` and `refs/heads/` to prevent option injection via malicious branch names.
- **Fixed-string matching**: Uses `grep -qxF` instead of `grep -qx` for branch name matching to avoid regex metacharacter issues (e.g., branch names containing `.` or `+`).
- **Safety guards**: Skips current branch (would fail with `git branch -D`), worktree-checked-out branches (git refuses deletion), and the base branch itself.
- **No git version constraint**: Uses `git commit-tree` and `git cherry` which are available in all modern git versions (unlike `git merge-tree --write-tree` which requires 2.38+).

## Verification

```bash
# Dry run to verify detection accuracy
git clean-squashed --dry-run --no-fetch

# Manual verification for a specific branch
merge_base=$(git merge-base origin/main feature-branch)
squash=$(git commit-tree "feature-branch^{tree}" -p "$merge_base" -m _)
git cherry origin/main "$squash"
# Output "- <sha>" = integrated; "+ <sha>" = NOT integrated
```

## Prevention Tips

- Run `git clean-squashed` after confirming PRs are merged, not days later.
- Enable GitHub's "Automatically delete head branches" repo setting.
- Create a shell alias like `gpm='git checkout main && git pull && git clean-squashed --force'` for one-step cleanup.
- Keep local branch count under 5-10 — high counts indicate staleness.

## Related

- [`chezmoi-external-script-repo-with-renovate-sha-pinning.md`](chezmoi-external-script-repo-with-renovate-sha-pinning.md) — alternative pattern for deploying scripts via `.chezmoiexternal.toml` + symlink
- [`cco-safe-mode-claude-not-found-in-path.md`](../runtime-errors/cco-safe-mode-claude-not-found-in-path.md) — `~/.local/bin` PATH and sandbox considerations
- `dot_config/zsh/path.zsh` — PATH setup that makes `~/.local/bin` discoverable by git
- [Dan Fabulich's `git-delete-squashed`](https://github.com/not-an-aardvark/git-delete-squashed) — original algorithm reference
