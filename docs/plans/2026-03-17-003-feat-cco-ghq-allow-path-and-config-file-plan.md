---
title: "feat: Add ghq root to cco allow path with chezmoi-managed config"
type: feat
status: completed
date: 2026-03-17
---

# feat: Add ghq root to cco allow path with chezmoi-managed config

## Overview

ユーザーは ghq 管理下のディレクトリを cco の allow path に追加し、cco の設定を別ファイルに切り出して chezmoi で管理したいと考えている。

## Critical Constraint: CCO_SANDBOX_ARGS_FILE の制限

ソースコード調査により、`CCO_SANDBOX_ARGS_FILE` は **backend passthrough args** （sandbox-exec/bwrap への直接引数）としてのみ機能することが判明:

```
# cco:1650 - ファイルから読み込んだ引数は sandbox_extra_args に格納
sandbox_extra_args+=("$line")

# cco:907-908 - native sandbox では -- マーカー間に挿入 → sandbox script の backend_extra_args へ
cmd+=("--" "${sandbox_extra_args[@]}" "--")
```

つまり `--add-dir`、`--deny-path`、`--safe` 等の **cco レベルフラグ** はこのファイルに書いても処理されない。これらは CLI 引数としてのみ機能する。

## Proposed Solution

`alias` を **shell function** に変更し、chezmoi 管理の設定ファイルから allow paths を読み込んで `--add-dir` 引数を動的に構築する。

### Phase 1: Shell function + 設定ファイル

**File**: `dot_zshrc` — alias を function に置換

```zsh
claude() {
  local -a cco_args=(--safe)
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/cco/allow-paths"
  if [[ -f "$config" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      cco_args+=(--add-dir "$line")
    done < "$config"
  fi
  command cco "${cco_args[@]}" "$@"
}
```

**File**: `dot_config/cco/allow-paths.tmpl` — chezmoi テンプレートで allow paths を管理

```
# ghq managed repositories
{{ .chezmoi.homeDir }}/ghq
```

### Design Decisions

**Why shell function over alias:**
- alias では動的なファイル読み込みができない
- function なら設定ファイルからパスを読み、`--add-dir` 引数を構築できる
- `command cco` で無限再帰を防止
- 引数はすべて透過的にパススルー (`"$@"`)

**Why allow-paths file (not CCO_SANDBOX_ARGS_FILE):**
- `CCO_SANDBOX_ARGS_FILE` は backend passthrough 用で `--add-dir` を処理しない
- 独自のシンプルなフォーマット（1行1パス、# コメント対応）
- chezmoi テンプレートで `{{ .chezmoi.homeDir }}` が使えてポータブル

**Why `--add-dir` (not `--allow-readonly`):**
- ghq 配下のリポジトリでは読み書き両方が必要（Claude Code がコード編集するため）
- `--add-dir` のデフォルトモードは `:rw`

**Why `--safe` is kept:**
- ghq root を allow しても `$HOME` 全体は隠れたまま
- 必要なパスだけ穴を開けるallowlist方式を維持

## Acceptance Criteria

- [x] `claude "hello"` が cco --safe 経由で実行される
- [ ] ghq 管理下のリポジトリ内でファイル読み書きが可能 — verify post-apply
- [x] `~/.config/cco/allow-paths` が chezmoi apply で配置される（テンプレート展開確認済み）
- [x] allow-paths ファイルにパス追加で cco のアクセス範囲を拡張可能
- [x] `command claude` で生の claude にアクセス可能
- [x] `chezmoi apply --dry-run` で想定外の変更なし

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `dot_zshrc` | Modify | alias → function に変更 |
| `dot_config/cco/allow-paths.tmpl` | Create | allow paths 設定（chezmoi テンプレート） |

## Dependencies & Risks

- **Low risk**: alias を function に変更（同等の機能 + 設定ファイル読み込み）
- **Reversibility**: function 削除 + allow-paths 削除で完全リバート
- **Performance**: 設定ファイル読み込みは数行なので起動時間への影響は無視可能
- **Bypass**: `command claude` で unsandboxed 実行可能（function ではなく直接 claude バイナリ）
