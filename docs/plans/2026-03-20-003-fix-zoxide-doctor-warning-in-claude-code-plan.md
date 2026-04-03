# Fix: zoxide doctor warning in Claude Code

**Type:** Trivial
**Created:** 2026-03-20

## Problem

Claude Code の Bash ツールで `cd` を実行すると以下の警告が表示される：

```
zoxide: detected a possible configuration issue.
Please ensure that zoxide is initialized right at the end of your shell configuration file (usually ~/.zshrc).
```

## Root Cause

Claude Code はシェルスナップショット（`~/.claude/shell-snapshots/`）から環境を復元する。スナップショットは：
- **関数は保存される** — `cd` (= `__zoxide_z`), `__zoxide_doctor`, `__zoxide_hook` 等
- **zsh 配列変数は保存されない** — `chpwd_functions`, `precmd_functions` 等

結果、`cd` → `__zoxide_z` → `__zoxide_doctor` が実行され、`chpwd_functions` に `__zoxide_hook` がないため警告が表示される。これは false positive（zoxide 初期化位置は `.zshrc` 末尾で正しい）。

## Solution

`dot_claude/settings.json.tmpl` の `env` に `_ZO_DOCTOR=0` を追加する。

`_ZO_DOCTOR=0` は zoxide 公式がサポートする環境変数で、doctor チェックを無効化する。Claude Code 固有の問題なので、`.zshrc`（グローバル）ではなく Claude Code の settings.json（スコープ限定）に設定する。

### Changes

| File | Change |
|------|--------|
| `dot_claude/settings.json.tmpl` | `env` に `"_ZO_DOCTOR": "0"` を追加 |

## Risks

- **None** — `_ZO_DOCTOR` は診断メッセージの制御のみ。zoxide のコア機能に影響しない。
- 通常のインタラクティブシェルには影響しない（Claude Code 環境のみ）。

## Verification

```sh
# Claude Code の Bash ツールで cd を実行し、警告が出ないことを確認
cd /tmp
```
