---
date: 2026-03-06
topic: chezmoi-mcp-servers
---

# User-scope MCP サーバー設定の chezmoi 管理

## What We're Building

Claude Code の user-scope MCP サーバー設定を chezmoi で宣言的に管理する仕組み。

**背景**: Claude Code は MCP サーバー設定を `~/.claude/settings.json` の `mcpServers` からは読まず、`~/.claude.json`（トップレベル）の `mcpServers` キーから読み込む。現在 `settings.json.tmpl` に記述している MCP サーバー定義は無視されている。

**仕組み**:
- 専用ファイル `dot_claude/mcp-servers.json` に MCP サーバー定義を記述
- `run_onchange_` スクリプトで `~/.claude.json` の `mcpServers` キーに jq マージ
- `settings.json.tmpl` からは `mcpServers` キーを削除

## Why This Approach

3つのアプローチを検討した:

### Approach A: jq マージ（採用）

`run_onchange_` スクリプトで `~/.claude.json` に対し `mcpServers` キーのみをマージする。

**Pros:**
- `~/.claude.json` の他のキー（セッション履歴、UI状態等）を壊さない
- MCP サーバー定義が専用ファイルで見通しが良い
- chezmoi の標準的なパターンに沿っている

**Cons:**
- jq への依存が増える（ただし chezmoi 環境では一般的）
- `~/.claude.json` が存在しない場合の初期化が必要

### Approach B: `claude mcp add` コマンド実行

`run_` スクリプトから `claude mcp add -s user` を繰り返し実行する。

**Pros:** Claude Code の公式 CLI を使うため、内部形式の変更に強い
**Cons:** 冪等性の担保が面倒。既存サーバーの削除・更新の管理が複雑

### Approach C: `~/.claude.json` 全体をテンプレート管理

**Pros:** 完全な宣言的管理
**Cons:** 動的に変わるキーが非常に多く、chezmoi apply のたびにセッション履歴等が上書きされるリスクが高い。非現実的。

## Key Decisions

- **MCP 定義ソース**: `dot_claude/mcp-servers.json` に専用ファイルとして配置
- **マージ方式**: jq の `*` 演算子で `~/.claude.json` の `.mcpServers` を上書きマージ
- **実行タイミング**: `run_onchange_` で mcp-servers.json のハッシュ変更時のみ
- **settings.json 整理**: `settings.json.tmpl` から `mcpServers` キーを削除

## Open Questions

- `~/.claude.json` が存在しない（初回セットアップ時）場合、空の `{}` で初期化するか、`claude mcp add` で最初の1つを追加して scaffold させるか
- `run_onchange_` スクリプトの実行順序: `settings.json` の apply より後に実行する必要があるか（依存関係）
- MCP サーバーの `env` 変数（API キーなど）を chezmoi のシークレット管理と統合するか

## Next Steps

-> `/workflows:plan` for implementation details
