---
title: "fix: plugin files overwritten on chezmoi apply"
type: fix
date: 2026-03-07
---

# fix: plugin files overwritten on chezmoi apply

## Overview

`chezmoi apply` すると、ランタイムで追加された新しいプラグインが削除されてしまうバグを修正する。

## Problem Statement

### 現在のフロー（壊れている）

```
1. ユーザーが Claude Code でプラグインをインストール
   → ~/.claude/plugins/installed_plugins.json が更新される（target）

2. chezmoi apply を実行

3. chezmoi が source テンプレートを target に適用
   → target が古い source の内容で上書きされる（新プラグインが消える！）

4. run_after_sync-plugins.sh が実行
   → 既に上書きされた target を source にコピー（手遅れ）
```

### 根本原因

`installed_plugins.json` と `known_marketplaces.json` が通常のテンプレートファイル（`.tmpl`）として管理されているため、`chezmoi apply` が常に source → target の一方向で上書きする。`run_after_` スクリプトは apply 完了後に実行されるため、target の変更を救うことができない。

## Proposed Solution

chezmoi の `modify_` スクリプトパターンを使用する。

`modify_` スクリプトは:
- 現在の target 内容を **stdin** で受け取る
- **stdout** に出力した内容が新しい target になる
- stdin が空（target 未存在）なら、デフォルトデータで初期化
- stdin に内容があれば、そのまま pass-through（ランタイム変更を保持）

### 修正後のフロー

```
1. ユーザーが Claude Code でプラグインをインストール
   → ~/.claude/plugins/installed_plugins.json が更新される

2. chezmoi apply を実行

3. modify_ スクリプトが実行される
   → stdin に現在の target 内容（新プラグイン含む）が渡される
   → そのまま stdout に出力 → target は変更されない ✓

4. run_after_sync-plugins.sh が実行
   → 新プラグインを含む target を source にコピー
   → source が最新状態に更新される ✓

5. 新マシンの場合（target 未存在）
   → stdin が空 → デフォルトデータを stdout に出力
   → target が初期化される ✓
```

## Implementation

### Phase 1: デフォルトデータファイルの作成

現在のテンプレートファイルをデフォルトデータとして保存する。ドットプレフィックスを付けて chezmoi の管理対象外にする。

| 操作 | ファイル |
|------|---------|
| リネーム | `dot_claude/plugins/private_installed_plugins.json.tmpl` → `dot_claude/plugins/.installed_plugins.json.data` |
| リネーム | `dot_claude/plugins/known_marketplaces.json.tmpl` → `dot_claude/plugins/.known_marketplaces.json.data` |

### Phase 2: modify_ スクリプトの作成

#### `dot_claude/plugins/modify_private_installed_plugins.json`

```bash
#!/bin/bash
# If target exists (stdin has content), preserve it (runtime-managed by Claude Code).
# If target doesn't exist (empty stdin), seed from default data.
INPUT=$(cat)
if [ -n "$INPUT" ]; then
    printf '%s' "$INPUT"
else
    cat "{{ .chezmoi.sourceDir }}/dot_claude/plugins/.installed_plugins.json.data"
fi
```

注意: このスクリプト自体を `.tmpl` にして `{{ .chezmoi.sourceDir }}` を解決させる必要がある。
→ ファイル名: `modify_private_installed_plugins.json.tmpl`

同様に `modify_known_marketplaces.json.tmpl` も作成。

#### テンプレート変数の処理

`.data` ファイルには `{{ .chezmoi.homeDir }}` テンプレート変数が含まれている。`modify_` スクリプトが `.data` ファイルを読む際は `sed` で実際のパスに置換する必要がある。

```bash
#!/bin/bash
INPUT=$(cat)
if [ -n "$INPUT" ]; then
    printf '%s' "$INPUT"
else
    sed "s|{{ "{{ .chezmoi.homeDir }}" }}|{{ .chezmoi.homeDir }}|g" \
        "{{ .chezmoi.sourceDir }}/dot_claude/plugins/.installed_plugins.json.data"
fi
```

### Phase 3: run_after_ スクリプトの更新

`run_after_sync-plugins.sh.tmpl` の出力先を `.tmpl` → `.data` に変更。

```diff
- "${PLUGINS_SRC}/private_installed_plugins.json.tmpl"
+ "${PLUGINS_SRC}/.installed_plugins.json.data"

- "${PLUGINS_SRC}/known_marketplaces.json.tmpl"
+ "${PLUGINS_SRC}/.known_marketplaces.json.data"
```

### Phase 4: 動作確認

- [ ] `chezmoi apply --dry-run` で差分確認
- [ ] `chezmoi apply` 実行後、`~/.claude/plugins/installed_plugins.json` が変更されていないことを確認
- [ ] 新しいプラグインを追加 → `chezmoi apply` → プラグインが残っていることを確認
- [ ] `chezmoi apply` 後に source `.data` ファイルが更新されていることを確認
- [ ] `chezmoi managed` で `installed_plugins.json` と `known_marketplaces.json` が引き続き管理対象であることを確認

## File Changes Summary

| 操作 | ファイルパス |
|------|------------|
| git mv (リネーム) | `dot_claude/plugins/private_installed_plugins.json.tmpl` → `dot_claude/plugins/.installed_plugins.json.data` |
| git mv (リネーム) | `dot_claude/plugins/known_marketplaces.json.tmpl` → `dot_claude/plugins/.known_marketplaces.json.data` |
| 新規作成 | `dot_claude/plugins/modify_private_installed_plugins.json.tmpl` |
| 新規作成 | `dot_claude/plugins/modify_known_marketplaces.json.tmpl` |
| 編集 | `.chezmoiscripts/run_after_sync-plugins.sh.tmpl` |

## Risks & Edge Cases

- **chezmoi の `include` vs ファイル読み込み**: modify_ スクリプトでは Go テンプレートの `include` は使えない（スクリプト実行時は bash）。代わりに `cat` + `sed` でファイルを読む。
- **既存の target 状態**: 初回の `chezmoi apply` 時、既存の target ファイルが正しい状態であれば pass-through で問題なし。
- **空ファイル vs 存在しないファイル**: `modify_` スクリプトでは、target が存在しない場合 stdin は空になる。`[ -n "$INPUT" ]` で判定可能。
