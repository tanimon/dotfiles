---
title: "feat: Add shellcheck and shfmt to pre-commit hooks"
type: feat
status: active
date: 2026-03-19
---

# feat: Add shellcheck and shfmt to pre-commit hooks

## Overview

`.pre-commit-config.yaml` に shellcheck と shfmt のフックを追加し、コミット時にシェルスクリプトの静的解析とフォーマットチェックを自動実行する。

## Proposed Solution

既存の prek + `.pre-commit-config.yaml` の仕組みに shellcheck と shfmt を local hook として追加。

## Acceptance Criteria

- [ ] `git commit` 時に `.sh` および `executable_*` ファイルに対して shellcheck が実行される
- [ ] `git commit` 時にシェルスクリプトに対して shfmt がフォーマットチェックを実行する
- [ ] 既存の secretlint フックが引き続き動作する

## MVP

### .pre-commit-config.yaml

```yaml
repos:
  - repo: local
    hooks:
      - id: secretlint
        name: secretlint
        entry: pnpm exec secretlint
        language: system
        types: [text]
      - id: shellcheck
        name: shellcheck
        entry: shellcheck
        language: system
        types: [bash]
      - id: shfmt
        name: shfmt
        entry: shfmt -d
        language: system
        types: [bash]
```
