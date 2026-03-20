---
title: "Claude Code Bash tool triggers false-positive zoxide doctor warning"
category: integration-issues
date: 2026-03-20
tags: [claude-code, zoxide, shell-snapshot, zsh, chezmoi]
components: [dot_claude/settings.json.tmpl, dot_zshrc]
---

## Problem

Claude Code の Bash ツールで `cd` を実行すると、毎回以下の警告が stderr に出力される：

```
zoxide: detected a possible configuration issue.
Please ensure that zoxide is initialized right at the end of your shell configuration file (usually ~/.zshrc).
```

zoxide の初期化位置は `.zshrc` 末尾で正しく、これは false positive。

## Root Cause

Claude Code はシェルスナップショット（`~/.claude/shell-snapshots/snapshot-zsh-*.sh`）から Bash ツールの環境を復元する。スナップショットは：

- **関数を保存する** — `cd`（= `__zoxide_z`）、`__zoxide_doctor`、`__zoxide_hook` 等
- **zsh 配列変数を保存しない** — `chpwd_functions`、`precmd_functions` 等

`__zoxide_doctor` は `chpwd_functions` 配列に `__zoxide_hook` が含まれているかチェックする。スナップショット環境では配列が空のため、チェックが常に失敗し警告が表示される。

```zsh
# zoxide init が生成する doctor 関数
function __zoxide_doctor() {
    [[ ${_ZO_DOCTOR:-1} -ne 0 ]] || return 0
    [[ ${chpwd_functions[(Ie)__zoxide_hook]:-} -eq 0 ]] || return 0
    # ↑ chpwd_functions が空なので常に 0 → 警告表示
    ...
}
```

## Solution

`dot_claude/settings.json.tmpl` の `env` に `_ZO_DOCTOR=0` を追加。Claude Code 環境のみに影響をスコープする。

```json
"env": {
    "_ZO_DOCTOR": "0"
}
```

Go テンプレートコメントで意図を記録：

```
{{/* _ZO_DOCTOR: Shell snapshot preserves zoxide cd function but not zsh chpwd_functions array, causing false-positive doctor warnings. */ -}}
"_ZO_DOCTOR": "0"
```

### なぜ `.zshrc` ではなく `settings.json.tmpl` か

- 問題は Claude Code のスナップショット機構に起因し、通常のインタラクティブシェルでは発生しない
- `.zshrc` に設定すると、将来実際の設定問題があった場合の警告も抑制してしまう
- `settings.json.tmpl` の `env` は Claude Code プロセスにのみ環境変数を注入する

## Prevention

- Claude Code のシェルスナップショットは関数をキャプチャするが zsh 特有の配列変数は保持しない。スナップショット環境で zsh 配列に依存する診断機能は false positive を出す可能性がある
- 同様の問題が他のツール（starship の `precmd_functions` 依存等）で発生した場合、同じパターン（Claude Code の `env` で診断を無効化）が適用できる
