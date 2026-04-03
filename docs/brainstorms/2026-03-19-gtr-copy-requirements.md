---
date: 2026-03-19
topic: gtr-copy
---

# gtr-copy: Worktree間ファイルコピーツール

## Problem Frame

git-worktree-runner (gtr) で作成した project 内で生成したファイル（特に `docs/` 配下）を、親リポジトリや他の project にコピーしたい場面が頻繁にある。現状は手動で `cp` とパスを組み立てる必要があり、worktree のパスが長く煩雑。

## Requirements

- R1. カレントworktree内のファイルをfzfで複数選択できる（`--multi`）
- R2. コピー先worktreeをfzfで選択できる（`git worktree list` から現在のworktreeを除外した一覧）
- R3. 親リポジトリ（main worktree）も他のgtr projectも、コピー先として等しく選択可能
- R4. 選択したファイルのディレクトリ構造を保持してコピーする（例: `docs/plan.md` → `<dest>/docs/plan.md`）
- R5. chezmoi管理のシェルスクリプトとして `~/.local/bin/gtr-copy` に配置（chezmoi apply で配布）
- R6. コマンド名は `gtr-copy`

## Success Criteria

- worktree間のファイルコピーが、パスを手打ちせず2ステップ（ファイル選択→先選択）で完了する
- 日常的に `docs/` 配下のファイルコピーに使えるシンプルさ

## Scope Boundaries

- 双方向同期ではない（一方向コピーのみ）
- コピー先での上書き確認は行わない（既存ファイルは上書き）
- gtr 自体の機能拡張ではなく、独立したコンパニオンスクリプト
- worktree 以外の任意ディレクトリへのコピーは対象外

## Key Decisions

- **chezmoi管理スクリプト**: dotfilesリポジトリで一元管理し、全マシンに自動同期
- **fzfでファイル選択**: glob指定やディレクトリ一括より柔軟で、プレビュー付きの直感的なUX
- **コピー先は全worktree**: 親リポジトリもgtr projectも区別せず、現在のworktreeのみ除外

## Dependencies / Assumptions

- `gtr` (git-worktree-runner) がインストール済み（Brewfile管理）
- `fzf` がインストール済み（Brewfile管理）
- `git worktree list` で全worktreeを列挙可能

## Outstanding Questions

### Deferred to Planning

- [Affects R1][Technical] fzfのプレビューウィンドウでファイル内容を表示するか、ファイル名一覧のみか
- [Affects R4][Technical] コピーにrsyncを使うか `cp` + `mkdir -p` で十分か
- [Affects R1][Needs research] fzfの初期ディレクトリフィルタ（例: デフォルトで `docs/` を優先表示）が有用か

## Next Steps

→ `/ce:plan` for structured implementation planning
