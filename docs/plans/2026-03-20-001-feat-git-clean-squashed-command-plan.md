---
title: "feat: Add git-clean-squashed command for deleting squash-merged branches"
type: feat
status: completed
date: 2026-03-20
---

# feat: Add git-clean-squashed command

## Overview

GitHub で squash merge された PR に対応するローカルブランチを検出・削除する git サブコマンドを追加する。通常の `git branch -d` は squash merge されたブランチを「未マージ」と判定するため削除できない。tree 比較アルゴリズムで squash merge 済みかどうかを正確に検出する。

## Problem Statement

squash merge 後のワークフロー:
1. GitHub で PR を squash merge → remote ブランチは削除される
2. `git fetch --prune` → remote-tracking ref は消える（`[gone]` になる）
3. `git branch -d feature-x` → **失敗**: コミット履歴が異なるため「未マージ」と判定
4. `git branch -D feature-x` を手動で実行する必要がある → 面倒かつ安全確認なし

既存の `clean_gone` スキルは `[gone]` ブランチの削除を行うが、squash merge の検出ロジックは持たない。

## Proposed Solution

`~/.local/bin/git-clean-squashed` スクリプトを chezmoi で管理し、`git clean-squashed` サブコマンドとして利用可能にする。

### Detection Algorithm

Dan Fabulich 方式（`git-delete-squashed` で実績あり）:

```bash
for branch in $(git for-each-ref refs/heads/ --format='%(refname:short)'); do
  merge_base=$(git merge-base origin/main $branch)
  # ブランチの tree を merge-base の上に squash commit として作成
  squash_commit=$(git commit-tree "$branch^{tree}" -p "$merge_base" -m _)
  # git cherry でその squash が main に既に含まれているか確認
  if [ "$(git cherry origin/main "$squash_commit")" = "- $squash_commit" ]; then
    echo "$branch is squash-merged"
  fi
done
```

仕組み:
- `git commit-tree` でブランチの最終 tree 状態を表す仮の squash commit を作成
- `git cherry` は patch-id ベースで同等のコミットが main に存在するか判定
- GitHub の squash merge コミットと patch-id が一致すれば「マージ済み」と検出

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Base ref | `origin/main`（auto-fetch付き） | ローカル main が stale な場合の誤検出を防ぐ |
| Confirmation | ブランチ一覧表示 + 一括 y/N | シンプルで安全。`--force` で skip 可能 |
| Current branch | スキップ + 警告 | `git branch -D` が現在のブランチで失敗するため |
| Worktree branches | スキップ + 警告 | 他の worktree で checkout 中のブランチは削除不可 |
| Base branch override | `--base <branch>` フラグ | `develop` 等への squash merge にも対応 |
| Protected branches | `main`, `master`, `develop` を除外 | 誤削除防止 |

## Technical Considerations

### chezmoi Source Structure

`dot_local/` ディレクトリは現在存在しないため新規作成:

```
dot_local/
  private_bin/
    executable_git-clean-squashed
```

- `private_bin/` → `~/.local/bin/` (0700 permissions)
- `executable_` prefix → 実行権限付与
- テンプレート不要（ハードコードされたパスや変数なし）
- `~/.local/bin` は既に PATH に含まれている（`dot_config/zsh/path.zsh`）

### CLI Interface

```
Usage: git clean-squashed [options]

Options:
  --base <branch>    Base branch to compare against (default: main)
  --force            Skip confirmation prompt
  --dry-run          List branches without deleting
  --no-fetch         Skip auto-fetch before scanning
  --help             Show this help message
```

### Edge Cases

- **現在のブランチが候補**: スキップ + 警告メッセージ
- **worktree で checkout 中**: スキップ + 警告メッセージ
- **merge-base が見つからない**: スキップ（main と無関係なブランチ）
- **Git バージョン**: `git commit-tree` と `git cherry` は古い Git でも利用可能（バージョン制約なし）
- **main ブランチ不在**: `master` へのフォールバック、それもなければエラー
- **候補なし**: "No squash-merged branches found." を表示して正常終了

## Acceptance Criteria

- [ ] `git clean-squashed` で squash merge 済みブランチを検出・一覧表示できる
- [ ] `--dry-run` で削除せずに一覧のみ表示できる
- [ ] 確認プロンプトで y/N を選択できる（`--force` でスキップ可能）
- [ ] 現在のブランチと protected branches はスキップされる
- [ ] `--base <branch>` で比較先ブランチを変更できる
- [ ] `--no-fetch` で auto-fetch をスキップできる
- [ ] chezmoi apply で `~/.local/bin/git-clean-squashed` にデプロイされる
- [ ] `set -euo pipefail` でエラーハンドリング

## MVP

### `dot_local/private_bin/executable_git-clean-squashed`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Defaults
BASE_BRANCH="main"
FORCE=false
DRY_RUN=false
NO_FETCH=false
PROTECTED_BRANCHES="main master develop"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-fetch) NO_FETCH=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate git repo
git rev-parse --is-inside-work-tree &>/dev/null || { echo "Error: Not a git repository" >&2; exit 1; }

# Determine base ref
if git rev-parse --verify "origin/$BASE_BRANCH" &>/dev/null; then
  BASE_REF="origin/$BASE_BRANCH"
elif git rev-parse --verify "$BASE_BRANCH" &>/dev/null; then
  BASE_REF="$BASE_BRANCH"
else
  echo "Error: Base branch '$BASE_BRANCH' not found" >&2; exit 1
fi

# Auto-fetch
if [[ "$NO_FETCH" == false ]]; then
  echo "Fetching from remote..."
  git fetch --prune --quiet
fi

# Get current branch and worktree branches
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
WORKTREE_BRANCHES=$(git worktree list --porcelain | grep '^branch ' | sed 's|^branch refs/heads/||')

# Scan for squash-merged branches
CANDIDATES=()
for branch in $(git for-each-ref refs/heads/ --format='%(refname:short)'); do
  # Skip protected branches
  if echo "$PROTECTED_BRANCHES" | grep -qw "$branch"; then continue; fi
  # Skip current branch
  if [[ "$branch" == "$CURRENT_BRANCH" ]]; then
    echo "Skipping '$branch' (currently checked out)"
    continue
  fi
  # Skip worktree branches
  if echo "$WORKTREE_BRANCHES" | grep -qx "$branch"; then
    echo "Skipping '$branch' (checked out in another worktree)"
    continue
  fi

  merge_base=$(git merge-base "$BASE_REF" "$branch" 2>/dev/null) || continue
  squash_commit=$(git commit-tree "${branch}^{tree}" -p "$merge_base" -m _)
  cherry_result=$(git cherry "$BASE_REF" "$squash_commit" 2>/dev/null) || continue

  if [[ "$cherry_result" == "- $squash_commit" ]]; then
    CANDIDATES+=("$branch")
  fi
done

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  echo "No squash-merged branches found."
  exit 0
fi

# Display candidates
echo ""
echo "Squash-merged branches:"
for branch in "${CANDIDATES[@]}"; do
  last_commit=$(git log -1 --format='%ar' "$branch")
  echo "  - $branch ($last_commit)"
done
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo "(dry-run: no branches deleted)"
  exit 0
fi

# Confirm deletion
if [[ "$FORCE" == false ]]; then
  read -rp "Delete ${#CANDIDATES[@]} branch(es)? [y/N] " confirm
  if [[ "$confirm" != [yY] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Delete branches
for branch in "${CANDIDATES[@]}"; do
  git branch -D "$branch"
done

echo "Done. Deleted ${#CANDIDATES[@]} branch(es)."
echo "Tip: Branches can be recovered via 'git reflog' within 30 days."
```

## Sources

- Dan Fabulich's `git-delete-squashed` algorithm: tree comparison via `git commit-tree` + `git cherry`
- chezmoi naming: `executable_` prefix for deploy with +x, `private_` for restricted parent dirs
- Existing patterns: `scripts/update-gh-extensions.sh`, `dot_claude/scripts/executable_statusline-wrapper.sh`
