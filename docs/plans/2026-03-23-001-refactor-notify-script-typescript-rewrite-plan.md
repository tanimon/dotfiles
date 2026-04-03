---
title: "refactor: Rewrite notify hook script in TypeScript"
type: refactor
status: completed
date: 2026-03-23
---

# refactor: Rewrite notify hook script in TypeScript

## Overview

`dot_claude/scripts/executable_notify.mjs` を TypeScript に書き換える。Node.js v24 の `--experimental-strip-types` を活用し、ビルドステップなしで `.ts` ファイルを直接実行する。

## Problem Statement / Motivation

現在の notify スクリプトは素の JavaScript (ESM) で書かれており、型安全性がない。TypeScript 化することで：
- transcript JSONL のパース部分に型を付けて安全性を向上
- 他のスクリプト（statusline-command.ts）と一貫したスタック

## Proposed Solution

1. `executable_notify.mjs` → `executable_notify.ts` にリネーム・書き換え
2. Hook コマンドを `node --experimental-strip-types` に更新
3. Seatbelt サンドボックス対策として wrapper スクリプトパターンを検討

## Technical Considerations

### Seatbelt サンドボックスとの互換性

`executable_statusline-wrapper.sh` が示す既知の問題：
- Node.js の `realpathSync` が `$HOME` に対して `lstat` を呼ぶ
- Seatbelt の `(deny file-read* (subpath "$HOME"))` ルールでブロックされる
- **対策**: `/tmp` にキャッシュコピーして実行するラッパーパターン

現在の `.mjs` は `--experimental-strip-types` を使わないため問題なし。`.ts` に変更すると同じ問題が発生する可能性がある。

**方針**: statusline と同じラッパーパターンを適用する。`executable_notify-wrapper.sh` を作成し、hook コマンドはラッパーを呼ぶようにする。

### chezmoi ファイル名マッピング

| Source | Target |
|--------|--------|
| `executable_notify.mjs` (現在) | `~/.claude/scripts/notify.mjs` |
| `executable_notify.ts` (新規) | `~/.claude/scripts/notify.ts` |
| `executable_notify-wrapper.sh` (新規) | `~/.claude/scripts/notify-wrapper.sh` |

### Hook コマンド変更

```
# Before
node "$HOME/.claude/scripts/notify.mjs"

# After
"$HOME/.claude/scripts/notify-wrapper.sh"
```

## Acceptance Criteria

- [ ] `executable_notify.mjs` を `executable_notify.ts` に書き換え（型注釈付き）
- [ ] `executable_notify-wrapper.sh` を作成（statusline-wrapper.sh と同パターン）
- [ ] `settings.json.tmpl` の Notification/Stop hook コマンドを更新
- [ ] `.mjs` ファイルを削除
- [ ] `chezmoi apply --dry-run` でエラーがないことを確認
- [ ] 手動テスト: hook 経由で通知が表示されること

## Implementation Phases

### Phase 1: TypeScript 書き換え

`executable_notify.ts` を作成。変更点：
- 型定義の追加（transcript entry, input payload）
- `import type` の活用
- ロジックは既存を維持（動作変更なし）

### Phase 2: ラッパースクリプト

`executable_notify-wrapper.sh` を作成：
- `/tmp/claude-notify-${UID}.ts` にキャッシュ
- ソース更新時のみコピー
- `exec node --experimental-strip-types "$cached"` で実行
- stdin (JSON) をそのまま node に流す

### Phase 3: Hook 設定更新

`dot_claude/settings.json.tmpl` を更新：
- Notification hook: ラッパーに変更
- Stop hook: ラッパーに変更

### Phase 4: クリーンアップ

- `executable_notify.mjs` を削除
- `settings.local.json` の allow リスト内の `.mjs` 参照を確認（ユーザーローカルなので直接変更はしない）

## Sources & References

- 既存パターン: `dot_claude/scripts/executable_statusline-wrapper.sh` — サンドボックス対応ラッパー
- Node.js `--experimental-strip-types`: v22.6.0+ で利用可能、v24.13.0 で確認済み
- Hook 定義: `dot_claude/settings.json.tmpl:148-181`
