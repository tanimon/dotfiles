---
title: "feat: Manage MCP servers via chezmoi modify_ script"
type: feat
date: 2026-03-06
---

# feat: Manage MCP servers via chezmoi modify_ script

## Overview

Claude Code の user-scope MCP サーバー設定を chezmoi で宣言的に管理する。`~/.claude.json` の `mcpServers` キーのみを `modify_` スクリプトで完全置換し、他のキー（セッション履歴、UI状態等）は一切触らない。

## Problem Statement

- Claude Code は MCP サーバーを `~/.claude.json` の `mcpServers` から読むが、現在 `~/.claude/settings.json` の `mcpServers` に定義しており無視されている
- `~/.claude.json` は動的な状態データが大量にあるため、ファイル全体のテンプレート管理は不可能
- 新しいマシンや環境でMCPサーバーを手動設定する必要がある

## Proposed Solution

3つのファイル変更で実現する:

1. **`dot_claude/mcp-servers.json`** (新規) — MCP サーバー定義の source of truth
2. **`modify_dot_claude.json`** (新規) — `~/.claude.json` の `mcpServers` のみを置換する modify_ スクリプト
3. **`dot_claude/settings.json.tmpl`** (変更) — `mcpServers` キーを削除

## Acceptance Criteria

- [ ] `chezmoi apply` で `~/.claude.json` の `mcpServers` が `mcp-servers.json` の内容に置換される
- [ ] `~/.claude.json` の他のキーが一切変更されない
- [ ] `~/.claude.json` が存在しない場合（初回セットアップ）でも正常動作する
- [ ] `~/.claude.json` が壊れている場合、元の内容をそのまま出力する（安全側に倒す）
- [ ] `jq` が未インストールの場合、元の内容をそのまま出力し警告を出す
- [ ] `claude mcp list` で定義したサーバーが表示される
- [ ] `settings.json` から `mcpServers` が削除されている

## MVP

### 1. dot_claude/mcp-servers.json

MCP サーバー定義の source of truth。現在 `settings.json.tmpl` にある定義を移動する。

```json
{
  "context7": {
    "type": "http",
    "url": "https://mcp.context7.com/mcp"
  },
  "notion": {
    "command": "npx",
    "args": ["-y", "mcp-remote", "https://mcp.notion.com/sse"]
  },
  "codex": {
    "type": "stdio",
    "command": "codex",
    "args": ["-m", "gpt-5.2-codex", "mcp-server"]
  },
  "newrelic": {
    "type": "http",
    "url": "https://mcp.newrelic.com/mcp/"
  },
  "figma": {
    "type": "http",
    "url": "https://mcp.figma.com/mcp"
  },
  "deepwiki": {
    "type": "http",
    "url": "https://mcp.deepwiki.com/mcp"
  }
}
```

### 2. modify_dot_claude.json

chezmoi source root に配置。`~/.claude.json` の `mcpServers` を完全置換する modify_ スクリプト。

**配置場所**: `$HOME/.local/share/chezmoi/modify_dot_claude.json` (source root)

```bash
#!/bin/bash
set -euo pipefail

# MCP servers source file
MCP_SOURCE="${CHEZMOI_SOURCE_DIR}/dot_claude/mcp-servers.json"

# Read current file from stdin
CURRENT="$(cat)"

# Guard: jq not installed
if ! command -v jq >/dev/null 2>&1; then
  echo "WARNING: jq not found, skipping MCP server merge" >&2
  printf '%s' "${CURRENT}"
  exit 0
fi

# Guard: source file missing
if [ ! -f "${MCP_SOURCE}" ]; then
  echo "WARNING: ${MCP_SOURCE} not found, skipping MCP server merge" >&2
  printf '%s' "${CURRENT}"
  exit 0
fi

# Guard: empty stdin (file doesn't exist yet)
if [ -z "${CURRENT}" ]; then
  jq -n --slurpfile servers "${MCP_SOURCE}" '{ mcpServers: $servers[0] }'
  exit 0
fi

# Guard: invalid JSON in current file
if ! echo "${CURRENT}" | jq empty 2>/dev/null; then
  echo "WARNING: ~/.claude.json contains invalid JSON, skipping merge" >&2
  printf '%s' "${CURRENT}"
  exit 0
fi

# Merge: replace mcpServers key, preserve everything else
echo "${CURRENT}" | jq --slurpfile servers "${MCP_SOURCE}" '.mcpServers = $servers[0]'
```

**エラーハンドリング方針**: すべてのエラーケースで元のファイル内容をそのまま出力し、データ破壊を防ぐ。

### 3. dot_claude/settings.json.tmpl の変更

`mcpServers` キー（221-247行目）を削除する。

変更前:
```json
  "mcpServers": {
    "context7": { ... },
    ...
  }
```

変更後: キーごと削除。

## Implementation Steps

1. `dot_claude/mcp-servers.json` を作成（settings.json.tmpl の mcpServers から内容を移動）
2. `modify_dot_claude.json` を source root に作成（実行権限付き）
3. `dot_claude/settings.json.tmpl` から `mcpServers` キーを削除
4. `chezmoi diff` で変更内容を確認
5. `chezmoi apply` を実行
6. `claude mcp list` で MCP サーバーが読み込まれていることを確認

**注意**: 3つの変更は同一コミットで行う（MCP設定が消えるウィンドウを作らない）。

## Edge Cases

| ケース | 動作 |
|--------|------|
| `~/.claude.json` が存在しない | `{ "mcpServers": {...} }` を新規生成 |
| `~/.claude.json` が壊れている | 元の内容をそのまま出力、警告を stderr へ |
| `jq` 未インストール | 元の内容をそのまま出力、警告を stderr へ |
| `mcp-servers.json` が見つからない | 元の内容をそのまま出力、警告を stderr へ |
| Claude Code が同時に書き込み中 | chezmoi の書き込みは一瞬。実用上のリスクは低い |
| `chezmoi diff` 実行時 | modify_ が実行され差分表示。期待通り |

## References

- Brainstorm: `docs/brainstorms/2026-03-06-chezmoi-mcp-servers-brainstorm.md`
- 現在の settings.json.tmpl: `dot_claude/settings.json.tmpl:221-247`
- 既存 run_onchange_ パターン: `.chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl`
- chezmoi modify_ docs: https://www.chezmoi.io/reference/source-state-attributes/#modify_
