---
title: "chezmoi の source の写しを並行して作ると、まれに tar: Write error で失敗する"
date: 2026-10-18
category: integration-issues
problem_type: integration_issue
component: tooling
module: scripts/chezmoi-source-snapshot.sh
severity: low
symptoms:
  - "写しの作成が `tar: Write error` で失敗する(16 並行で 320 回中 2 回)"
  - "失敗したのに、写しのファイルは揃っている"
root_cause: async_timing
resolution_type: code_fix
tags: [chezmoi, tar, bats, flaky]
---

# chezmoi の source の写しを並行して作ると、まれに tar: Write error で失敗する

## 問題

`scripts/chezmoi-source-snapshot.sh` は、追跡しているファイルを `tar -c` で固め、パイプで `tar -x` に渡して写しを作っていた。展開する側の `tar -x` はアーカイブの終端を読んだところで抜ける。作る側の `tar -c` がその後で末尾の埋め草を書くと、閉じたパイプへの書き込みになり失敗する。パイプライン全体が失敗扱いになり、写しの作成が失敗する。

`bats --jobs` の suite が `test/helpers/render.bash` を同時に読み込むと、写しが並行して作られ、この順序が起きうる。

## 症状

- 手元(macOS の bsdtar)で、写しのスクリプトだけを 16 本同時に作ると、320 回中 2 回失敗した。並行しなければ 300 回で 0 回だった。
- 失敗したときのパイプの各段の終了コードは `0 0 1 0` だった(`git ls-files`・削除済みを除く `while`・作る側の `tar -c`・展開する側の `tar -x`)。
- 展開する側は正常に終わっていて、写しのファイルは揃っていた。

## 解決

アーカイブをパイプで渡さず、`mktemp` で作った一時ファイルに書いてから展開する。一時ファイルは `trap … EXIT` で消す。直した後は同じ条件で 960 回作って 0 回だった。

## なぜ効くか

作る側は一時ファイルに書き終えてから閉じ、展開する側はその後でファイルを読む。展開する側がいつ抜けても、作る側の書き込みが閉じた先に向かうことがない。tar の実装(bsdtar・GNU tar)によらない。

## 再発防止

`test/chezmoi-source-snapshot.bats` に、`render.bash` を並行して読み込んでも写しが 1 つだけで、中に余計な項目が入らないことを確かめるケースがある。写しの作成が失敗すると、このケースが落ちる(直す前は約 3% で落ちた)。

## 関連

- [chezmoi-source-walk-races-parallel-recipes.md](chezmoi-source-walk-races-parallel-recipes.md)(写しを使う理由になった競合)
- `scripts/chezmoi-source-snapshot.sh`、`test/helpers/render.bash`
