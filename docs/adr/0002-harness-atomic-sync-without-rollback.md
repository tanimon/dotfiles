---
status: accepted
date: 2026-09-11
---

# harness の Target 置換は「全件 staging → 全体検証 → 同ディレクトリ rename」とし、置換途中の失敗はロールバックせず報告する

`harness sync` は全 Target を一時ディレクトリに render し、全件が揃ったことを検証してから、各 Target と同じディレクトリに書いた一時ファイルを `mv` で置き換える(Atomic Sync)。render が 1 つでも失敗すれば既存 Target には一切触れない — 「1 製品だけ新しいポリシー版に進む」状態を作らないため(#308)。同一内容の Target は `mv` せず mtime も変えないので、2 回目の `sync` は何も変更しない。

## Considered Options

- **Target ごとに render して即座に書く** — 却下。2 件目の adapter が失敗した時点で 1 件目だけ新版になり、製品間の意図が食い違う。
- **置換フェーズの失敗もスナップショットから巻き戻す** — #309 では採らない。rename 自体は原子的で、失敗しうるのは disk full・権限などの環境要因に限られる。巻き戻しには Target 群のスナップショットが必要で、それは runtime-mixed ファイル(`~/.claude.json` 等)の部分更新を扱う後続チケットの機構と同じものになるため、そこで一度に設計する。それまでは失敗した Target を `FAIL` で報告し exit 1 で止め、「どこまで適用されたか」は出力から読めるようにする。
- **`--runtime` で一部だけ同期する** — 却下(`sync --runtime` は使い方エラー)。部分同期は上と同じ理由で製品間の版ずれを生む。`check --runtime` の単一 runtime 診断だけを許す。

## Consequences

- live Target が symlink の場合、rename は symlink 自体を通常ファイルに置き換えてしまう(このリポジトリが `~/.claude.json` で踏んだ事故)。#309 では置換前に検出して全体を `FAIL` で止め、symlink Target の扱いは後続チケットに委ねる。
- 一時ファイルは `mktemp` で作るため、置換後のモードは既存 Target のものを引き継ぎ、新規作成は 0644。adapter は Target のモードを指定できない。
- 祖先が通常ファイルで親ディレクトリを作れない Target も、manifest と live の形だけで事前に決まるので、symlink・directory と同じく置換前に検出して全体を `FAIL` で止める。置換フェーズで残る失敗は権限・disk full などの環境要因だけになる。
- staging は `$TMPDIR` 配下で、親シェルが `mktemp -d` してから `main` を subshell で実行し、成功・失敗のどちらでも親が削除する。EXIT trap で削除しないのは、bash 3.2 では EXIT trap があると `set -u` 違反の終了コードが 0 に潰れるため(ADR 0003)。
