---
date: 2026-10-31
trigger: "3 本の Command Guard が起動部を写して持ち、ログの扱い・JSON の出し方・lib の検査が guard ごとにずれていた"
paths:
  - "dot_claude/scripts/lib/command-guard.bash"
  - "dot_claude/scripts/executable_git-push-guard.sh"
  - "dot_claude/scripts/executable_curl-localhost-guard.sh"
  - "dot_claude/scripts/executable_issue-linkage-guard.sh"
  - "test/guard-contract.bats"
---

**Command Guard の起動部** — PreToolUse の Command Guard(GLOSSARY。git-push-guard・curl-localhost-guard・
issue-linkage-guard)は、起動部を `dot_claude/scripts/lib/command-guard.bash` に持たせ、各 guard は宣言(動詞・
Failure Direction・ログ名・使う lib と求める関数)と判定だけを書く。interface と、起動の手順がその形である理由の
正本は module のヘッダ。起動時の振る舞いの正本は `test/guard-contract.bats`(`just test-guard-contract`)。

- **各 guard に残す自前の部分は削らない。** stdin の読み取り → 生の stdin の動詞の照合 → 起動 module の
  `-r` / `"$BASH" -n` / `source` / `declare -F` → 読めなければ固定文の ask(Failure Direction が pass の guard は exit 0)。
  起動 module が無い・空・構文エラーのときも ADR 0009 の約束(読めなければ ask)を守るのはこの部分だけで、
  module の中には置けない。stdin は module を読む前に読む。そうしないと module が読めないときに動詞で判定できない。
  ADR 0009 が受け入れた残存はフックの未配置とクラッシュだけで、起動 module の故障を無出力で通すとこれを後退させる。
- **判定は `command_guard_emit deny|ask` だけで出す。** 自前で JSON を組み立てない(`allow` を返さない約束を
  module が守る)。判定中の理由の文は guard 固有のまま、起動の失敗の理由は module の共通の固定文にする。
- **source する lib はトップレベルで `declare` / `typeset` を使わない。** module が関数の中で source するので、
  その変数は start から戻ると消える(bash 3.2 には `declare -g` が無い)。
- **配線の契約: フックの `command` はスクリプトのパスそのものにする。** `settings.json` 側で
  `mkdir -p … && script 2>>log` と書くと、ログディレクトリを作れないときに**リダイレクトの失敗でスクリプトごと
  走らない** = 判定なし = フェイルオープンになる(`;` に変えても直らない。リダイレクトの失敗はそのコマンドを
  放棄させる)。ログの出力先の決定は module が持ち、開けたときだけ繋ぐ。`test/settings-hooks.bats` が描画した
  `settings.json` でこの形(`.exact`)を固定している。すべての guard を 1 本の dispatcher にまとめて policy を引数で
  選ぶ形は、この契約を壊すので採らない。
- **ログ**は `~/.claude/logs/<name>-errors.log`。起動 module 自体が壊れたときの診断だけは、ログを開く前なので
  フックの stderr に出る(判定は ask のまま)。
- **4 本目の Command Guard を足すとき**は、既存の guard の自前の部分を写して動詞と固定文の名前を変え、
  `command_guard_start` に宣言を渡し、`test/guard-contract.bats` の `guard`(読めなければ ask)か
  `fail_open_guard`(読めなければ無出力)の一覧に 1 行足す。配線した guard が一覧に無いと、同じファイルの最後の
  test が落ちる。
