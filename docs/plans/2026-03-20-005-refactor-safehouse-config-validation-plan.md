---
title: "refactor: Validate and refine safehouse config structure"
type: refactor
status: completed
date: 2026-03-20
---

# refactor: Validate and refine safehouse config structure

## Overview

PR #38 で導入した safehouse の設定ファイル (`dot_config/safehouse/config.tmpl`) の構成が適切か検証し、必要な改善を行う。

## Analysis: 現在のアプローチは適切か？

### safehouse の CLI フラグ処理（調査結果）

- `--add-dirs=PATH`: ディレクトリなら `(allow file-read* file-write* (subpath ...))`, ファイルなら `(allow file-read* file-write* (literal ...))` — **自動判定**
- `--add-dirs-ro=PATH`: 同上、ただし `file-read*` のみ
- 両方とも **ancestor literal を自動生成** (`emit_path_ancestor_literals()`)
- CLI フラグは assembly Phase 4（built-in profiles の後、`--append-profile` の前）に配置
- `--append-profile` は最終レイヤー（deny ルールのオーバーライドに使用）

### 結論

**現在の CLI フラグベースのアプローチは構造的に正しい。** safehouse 公式ドキュメントの「カスタム .sb + ラッパー」アプローチは safehouse を使わない場合の構成。safehouse を使う場合は CLI フラグで十分。

### 改善点

1. **`--append-profile` の活用**: 明示的な deny ルール（SSH 秘密鍵、ブラウザデータ等）を追加するカスタム .sb ファイルが有用
2. **不足パスの追加**: 検出された Rust toolchain (`~/.cargo`, `~/.rustup`) が未カバー
3. **`.npmrc` の追加**: 検出されたが config に含まれていない

## Implementation

### Phase 1: カスタム .sb プロファイルの追加

`dot_config/safehouse/local-overrides.sb.tmpl` を作成し、`--append-profile` で読み込む。
- 明示的な deny ルール（browser data, shell history 等）
- safehouse の built-in profiles でカバーされない追加パス

### Phase 2: config.tmpl の更新

- `--append-profile` を追加
- 不足パス（`.npmrc`, `.cargo`, `.rustup`）を追加
- 不要パスがあれば削除

## Acceptance Criteria

- [ ] config.tmpl に `--append-profile` が追加される
- [ ] カスタム .sb に明示的 deny ルールが含まれる
- [ ] 検出された toolchain パスがカバーされる
- [ ] `chezmoi apply --dry-run` でエラーなし
