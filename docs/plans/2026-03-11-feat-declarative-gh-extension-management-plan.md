---
title: "feat: Declarative gh CLI extension management via chezmoi"
type: feat
status: completed
date: 2026-03-11
---

# feat: Declarative gh CLI extension management via chezmoi

gh CLI の拡張機能を chezmoi で宣言的に管理する。既存の Claude マーケットプレイス同期パターン（`marketplaces.txt` + `run_onchange_` + `scripts/update-*.sh`）を踏襲し、3ファイル構成で実装する。

## Acceptance Criteria

- [x] `dot_config/gh/extensions.txt` に拡張リストを1行1エントリ（`owner/repo`）で管理できる
- [x] `chezmoi apply` 時、リスト変更があれば `gh extension install` が自動実行される
- [x] `scripts/update-gh-extensions.sh` で現在インストール済みの拡張からリストを再生成できる
- [x] `gh` 未インストール/未認証時はスキップして `chezmoi apply` が失敗しない
- [x] コメント行（`#`）と空行がサポートされる
- [x] `.chezmoiignore` に `.config/gh/extensions.txt` を追加し、ターゲットへのデプロイを防ぐ

## Context

### 設計判断

- **追加のみ（additive）** — リストから削除してもアンインストールはしない（marketplace パターンと同じ）
- **インストールのみ** — `gh extension upgrade` は含めない。アップグレードは手動
- **バージョンピニング非対応** — `owner/repo` 形式のみ

### 踏襲するパターン

| ファイル | 役割 | 参考元 |
|---------|------|--------|
| `dot_config/gh/extensions.txt` | 拡張リスト（source of truth） | `dot_claude/plugins/marketplaces.txt` |
| `.chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl` | ハッシュ変更時にインストール実行 | `run_onchange_after_add-marketplaces.sh.tmpl` |
| `scripts/update-gh-extensions.sh` | 現在の状態からリスト再生成 | `scripts/update-marketplaces.sh` |

### 注意事項

- `.chezmoiignore` の `*.txt`（line 8）はルートレベルのみ → `dot_config/gh/extensions.txt` には影響しない。実装後 `chezmoi managed | grep extensions` で確認すること
- `extensions.txt` はそのままだと `~/.config/gh/extensions.txt` にデプロイされる → `.chezmoiignore` に `.config/gh/extensions.txt` を追加してデプロイを防ぐ
- `run_onchange_after_` の `after_` はファイルデプロイ後に実行される意味。Brewfile スクリプト（`after_` なし）とはファイル名のレキソグラフィック順で順序が決まる。結果的に Brewfile → gh extensions の順になる
- `gh extension install` は認証が必要 → `gh auth status` チェックを追加

## MVP

### dot_config/gh/extensions.txt

```text
yusukebe/gh-markdown-preview
```

### .chezmoiscripts/run_onchange_after_install-gh-extensions.sh.tmpl

```bash
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# gh extensions hash: {{ include "dot_config/gh/extensions.txt" | sha256sum }}

if ! command -v gh &>/dev/null; then
  echo "gh CLI not found, skipping extension installation"
  exit 0
fi

if ! gh auth status &>/dev/null; then
  echo "gh not authenticated, skipping extension installation"
  exit 0
fi

while IFS= read -r ext || [ -n "$ext" ]; do
  [[ -z "$ext" || "$ext" == \#* ]] && continue
  echo "Ensuring gh extension: ${ext}"
  gh extension install "$ext" || echo "warning: failed to install $ext" >&2
done < "{{ .chezmoi.sourceDir }}/dot_config/gh/extensions.txt"
{{ end -}}
```

### scripts/update-gh-extensions.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="${REPO_ROOT}/dot_config/gh/extensions.txt"

if ! command -v gh &>/dev/null; then
  echo "error: gh CLI not found" >&2
  exit 1
fi

gh extension list \
  | awk -F'\t' '{print $2}' \
  | sort \
  > "$TARGET"

echo "Updated ${TARGET} ($(wc -l < "$TARGET" | tr -d ' ') extensions)"
```

## Sources

- 既存パターン: `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl`
- 既存パターン: `scripts/update-marketplaces.sh`
- 解決策ドキュメント: `docs/solutions/integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md`
