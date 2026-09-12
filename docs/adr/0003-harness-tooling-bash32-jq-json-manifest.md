---
status: accepted
date: 2026-09-11
---

# harness ツールは bash 3.2 互換のシェル + jq で書き、Harness Manifest は JSON にする

harness の同期・検証ツール(`harness/`)は、このリポジトリに既にある lint / テスト基盤(shellcheck・shfmt・bats・`just lint`・pre-commit)にそのまま載せるため bash で書く。macOS 標準の `/bin/bash` は 3.2 なので、`mapfile` や連想配列を使わず 3.2 互換を保つ。Harness Manifest は YAML ではなく **JSON** で、パーサは `jq` 1 つに限定する。

## Considered Options

- **TypeScript / Node で書く** — 却下。リポジトリに TS は少量あるが、`chezmoi apply` から呼ばれる経路(#324)では Node の有無・バージョンに依存したくない。bash + jq はどのマシンでも `brew bundle` 直後に揃う。
- **manifest を YAML にする(`apm.yml` と揃える)** — 却下。Brewfile に YAML パーサ(`yq`)が無く、追加すれば依存が 1 つ増える。JSON なら `jq` で検証・問い合わせが完結し、`*.json` は `just oxfmt` が構文検証してくれる。`apm.yml` とフォーマットが揃わない不便は受け入れる。
- **bash 4+ を前提にする(Homebrew bash)** — 却下。`#!/usr/bin/env bash` が解決する bash は PATH 次第で、CI(ubuntu, bash 5)とローカル(3.2)で挙動が割れる。最小公倍数の 3.2 に合わせ、差が出る箇所(空配列の展開、EXIT trap 下での `set -u` の終了コード)は bats で固定する。

## Consequences

- adapter は「実行ファイルなら何でもよい」契約(`<owner>.sh render <staging-file> <target-json>`)なので、個々の Runtime Adapter を別言語で書く余地は残る。制約はコア(`harness/bin`・`harness/lib`)にだけ掛かる。
- bash 3.2 では EXIT trap があると `set -u` 違反の終了コードが 0 に潰れる。オプション値の欠落などは解析側で明示的にガードし、trap に頼らない。
