---
title: chezmoi .tmpl ファイルと shellcheck/shfmt の非互換性
category: integration-issues
date: 2026-03-20
tags: [chezmoi, shellcheck, shfmt, pre-commit, linting, template]
modules: [pre-commit-hooks, chezmoiscripts]
---

# chezmoi `.tmpl` ファイルと shellcheck/shfmt の非互換性

## Problem

chezmoi の `.tmpl` ファイル（Go テンプレート構文 `{{ }}` を含むシェルスクリプト）を shellcheck や shfmt で lint すると、テンプレート構文がパースエラー（SC1054, SC1056, SC1072, SC1073）を引き起こす。

```
In .chezmoiscripts/run_onchange_darwin-install-packages.sh.tmpl line 1:
{{ if eq .chezmoi.os "darwin" -}}
 ^-- SC1054 (error): You need a space after the '{'.
```

## Root Cause

shellcheck はシェルスクリプトのパーサーであり、Go テンプレート構文 `{{ }}` をシェル構文として解釈しようとする。これらはパースエラー（構文解析の失敗）であり、`# shellcheck disable=SC1054` ディレクティブでは抑制できない。パース段階でファイル全体の解析が失敗するため、テンプレート以外の部分も検査されない。

## Solution

`.pre-commit-config.yaml` で `.tmpl` ファイルを shellcheck/shfmt の対象から除外する:

```yaml
- id: shellcheck
  name: shellcheck
  entry: bash -c 'if command -v shellcheck &>/dev/null; then shellcheck "$@"; else echo "shellcheck not found, skipping"; fi' --
  language: system
  files: '(\.sh$|\.bash$|\.chezmoiscripts/|executable_)'
  exclude: '\.tmpl$'    # chezmoi テンプレートは shell parser と非互換
  types: [file]
- id: shfmt
  name: shfmt
  entry: bash -c 'if command -v shfmt &>/dev/null; then shfmt -d -i 4 "$@"; else echo "shfmt not found, skipping"; fi' --
  language: system
  files: '(\.sh$|\.bash$|\.chezmoiscripts/|executable_)'
  exclude: '\.tmpl$'    # chezmoi テンプレートは shell parser と非互換
  types: [file]
```

## Alternatives Considered

| アプローチ | 評価 |
|-----------|------|
| `# shellcheck disable=` ディレクティブ | 不可。パースエラーはディレクティブで抑制できない |
| `chezmoi execute-template` で前処理後に lint | 可能だが、chezmoi のインストールとデータが必要。CI で動かすにはセットアップが複雑 |
| `sed` でテンプレート構文を除去してから lint | 脆弱。inline テンプレート（`{{ joinPath ... }}`）の適切なプレースホルダー置換が困難 |
| `.tmpl` ファイルを完全除外 | 最もシンプルで確実。テンプレート以外の shell コードが lint されないデメリットはあるが、chezmoi の `run_onchange_` スクリプトは通常数行程度で影響は限定的 |

## Prevention

- chezmoi リポジトリで shellcheck/shfmt を pre-commit フックに追加する際は、最初から `.tmpl` ファイルを除外する
- `.tmpl` ではないシェルスクリプト（`defaults.sh` 等）は引き続き lint 対象となる
