---
title: "nono は存在しないパスの grant を評価せず、grant を足しても path_not_granted のまま"
date: 2026-10-16
category: docs/solutions/integration-issues
module: nono sandbox
problem_type: integration_issue
component: tooling
symptoms:
  - "claude-seal.json の filesystem.read に $XDG_CONFIG_HOME/web-verify を足しても、`nono why --path ~/.config/web-verify/config.json --op read` が DENIED / path_not_granted のまま"
  - "$TMPDIR に一時ディレクトリを作って grant を検証すると、grant を外した版でも ALLOWED になり対照にならない"
root_cause: config_error
resolution_type: test_fix
severity: low
related_components:
  - dot_config/nono/profiles/claude-seal.json
  - test/nono-profile.bats
  - dot_claude/skills/web-verify
---

# nono は存在しないパスの grant を評価しない

## 症状

web-verify の個人設定 `~/.config/web-verify/config.json` を nono の内側から読めるよう、
`claude-seal.json` の `filesystem.read` に `$XDG_CONFIG_HOME/web-verify` を足した。
このマシンには `~/.config/web-verify` がまだ無く、`nono why` は grant を足した後も
`DENIED / path_not_granted` を返した。

## 原因

nono は grant のパスが存在しない間、その grant を評価しない。対比で確かめた(nono 0.79 系):

| パス | grant | 結果 |
|---|---|---|
| `~/.config/herdr`(存在する) | なし | DENIED / path_not_granted |
| `~/.config/herdr`(存在する) | あり | ALLOWED / granted_path |
| `~/.config/web-verify`(存在しない) | あり | DENIED / path_not_granted |

ユーザーが後から作る設定ディレクトリの grant は、ディレクトリを作った後に起動した
nono セッションでだけ効く。

## 解決

- grant はそのまま入れる。読み取りが拒否されたときの skill の扱い(「設定なし」とは扱わない)は
  web-verify の SKILL.md の「保存場所の決め方」にある
- 回帰テスト(`test/nono-profile.bats` の `web_verify_why`)は、`XDG_CONFIG_HOME` を一時ディレクトリに
  差し替え、その中に `web-verify/config.json` を作ってから判定する。nono は pack を
  `$XDG_CONFIG_HOME/nono` から解決するので、実物への symlink を置く
- 一時ディレクトリは `$HOME` 直下に作る。`$TMPDIR`(`/var/folders`)は pack が許可しているので、
  そこに置くと grant を外した版でも ALLOWED になり、対照ペアが成立しない
- このテストは `$HOME` に書くので、Claude Code の Bash サンドボックスの内側では動かない。素のターミナルで実行する
