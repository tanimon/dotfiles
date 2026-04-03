---
title: "agent-safehouse CLI flag internals and config patterns"
category: integration-issues
date: 2026-03-20
severity: low
tags: [agent-safehouse, seatbelt, sandbox, macos, cli-flags, configuration]
related:
  - migrate-cco-to-agent-safehouse.md
---

# agent-safehouse CLI flag internals and config patterns

## Problem

safehouse の設定ファイル構成が適切か不明。公式ドキュメントに「カスタム .sb プロファイル + ラッパースクリプト」を生成する手順があり、CLI フラグベースのアプローチと混同しやすい。

## Root Cause

公式ドキュメントの「カスタム .sb 生成」手順は **safehouse を使わずに** standalone sandbox を作るためのもの。safehouse を使う場合は CLI フラグ (`--add-dirs`, `--add-dirs-ro`, `--enable`, `--append-profile`) が正しいアプローチ。

## Solution: CLI フラグの内部動作

### ファイル vs ディレクトリの自動判別

`--add-dirs-ro=PATH` はフラグ名に "dirs" とあるが、**ファイルにも対応する**。`render.sh` の `policy_render_emit_extra_access_rules()` で `-d` チェックにより自動判別:

- **ディレクトリ** → `(allow file-read* (subpath "/path/to/dir"))`
- **ファイル** → `(allow file-read* (literal "/path/to/file"))`

`--add-dirs` (rw) も同様に `file-read* file-write*` で判別される。

### ancestor literal の自動生成

`--add-dirs` / `--add-dirs-ro` は `policy_render_emit_path_ancestor_literals()` を自動呼出し。各祖先パスに `(allow file-read* (literal ...))` を生成する。手動で .sb ファイルに書く必要はない。

注: ancestor は `file-read*` (not `file-read-metadata`) の `literal` を使用。`readdir()` が必要なため metadata だけでは不足（PATH blanking が発生する）。

### ポリシー assembly 順序

| Phase | 内容 |
|-------|------|
| 1 | 00-base.sb, 10-system-runtime.sb, 20-network.sb, 30-toolchains/*, 40-shared/* |
| 2 | 50-integrations-core/*, 55-integrations-optional/* (selected) |
| 3 | 60-agents/* (auto-matched), 65-apps/* |
| 4 | **CLI flags** (`--add-dirs-ro`, `--add-dirs`, workdir), **`--append-profile`** (last) |

CLI フラグは Phase 4 で適用。`--append-profile` が最終レイヤーのため、deny ルールでの上書きが可能。

### built-in プロファイルのカバレッジ

重複追加を避けるために知っておくべきパス:

| Profile | Auto-covers |
|---------|-------------|
| `claude-code.sb` | `~/.claude` (rw), `~/.claude.json` (rw), `~/.local/share/claude` |
| `keychain.sb` (auto-required) | `~/Library/Keychains` |
| `git.sb` | `~/.gitconfig`, `~/.gitignore`, `~/.config/git`, `~/.ssh/config` |
| `scm-clis.sb` | `~/.config/gh` (rw) |
| `runtime-managers.sb` | `~/.local/share/mise`, `~/.config/mise` (rw) |
| `node.sb` | `~/.npm`, `~/.npmrc` |
| `rust.sb` | `~/.cargo`, `~/.rustup` |

### 推奨 config パターン

設定ファイルは safehouse CLI フラグを 1 行 1 引数で記述し、shell wrapper で読み込む:

```
# ~/.config/safehouse/config
--enable=ssh
--enable=1password
--add-dirs=$HOME/ghq
--add-dirs-ro=$HOME/.local/bin
```

`--append-profile` は deny オーバーライドが必要な場合のみ追加。

## Prevention

- safehouse を使う場合はカスタム .sb プロファイルを自作しない — CLI フラグで十分
- 新しいパスを追加する前に `safehouse --explain --stdout` で built-in カバレッジを確認
- `--add-dirs-ro` はファイルにも使える（フラグ名に惑わされない）
