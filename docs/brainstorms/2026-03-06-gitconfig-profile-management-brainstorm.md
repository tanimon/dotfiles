# Brainstorm: dot_gitconfig の会社用設定を chezmoi プロファイルで管理

**Date:** 2026-03-06
**Status:** Decided

## What We're Building

`dot_gitconfig` を chezmoi テンプレート化し、`profile` 変数 (work/personal) に基づいて会社用設定を条件分岐で出力する。

## Why This Approach

**アプローチ A: テンプレート化** を採用。

- 1ファイルで完結し、シンプル
- chezmoi のネイティブ機能（`{{ if eq .profile "work" }}`）を活用
- 既に `.chezmoi.toml.tmpl` で `profile` 変数が定義済みだが未活用 → これを活かす

却下したアプローチ:
- **B. includeIf + 別ファイル**: ファイルが分散し、今の規模では過剰
- **C. テンプレート + 外部ファイル生成**: YAGNI

## Key Decisions

1. **ファイル変換**: `dot_gitconfig` → `dot_gitconfig.tmpl` にリネーム
2. **共通設定** (全プロファイル): 基本的な git 設定全般 + コミット署名 (gpgsign, gpg, gpg "ssh", 1Password)
3. **work のみの設定**: `{{ if eq .profile "work" }}` で囲む
   - `[url "git@github.com:"]` — HTTPS → SSH 書き換え
   - `[gtr "copy"]` / `[gtr "editor"]` — 会社プロジェクト用
   - `[credential]` — Azure DevOps 資格情報ヘルパー
4. **chezmoi 管理外ファイル**: `docs/` を `.chezmoiignore` に追加（ホームに展開させない）

## Open Questions

なし。

## Next Steps

`/workflows:plan` でこのブレインストームを基に実装計画を作成する。
