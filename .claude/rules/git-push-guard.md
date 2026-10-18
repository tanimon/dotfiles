---
date: 2026-10-18
trigger: "常時ではないが dot_claude/scripts/ の下を触るたびに読み込まれる dot_claude/scripts/CLAUDE.md が、週次ジョブの作業とは関係ない guard の実装の詳細で約 60 KB になっていた"
paths:
  - "dot_claude/scripts/executable_git-push-guard.sh"
  - "test/git-push-guard.bats"
  - "dot_claude/scripts/lib/shell-reader.bash"
  - "test/shell-reader.bats"
---

**git push guard hook** — `dot_claude/scripts/executable_git-push-guard.sh` は `PreToolUse`
(`matcher: "Bash"`)で走る**許可判定フック**。他の2つのフック(notify / worktree-include)と違い、
これは副作用のための hook ではなく `hookSpecificOutput.permissionDecision` を返して**ツール呼び出しを
止める**ためのもの。存在理由は `permissions` のプレフィックス照合の限界で、`Bash(git push --force:*)`
は `git push origin main --force` に当たらない — write intent がフラグ位置に移動できるため、
`Bash(git push:*)` を `ask` に置く以外に塞ぐ手が無く、その結果として日常の push まで毎回プロンプトに
なっていた。フックはコマンド文字列**全体**を受け取るので、引数位置に依存しない判定が書ける。

判定は3値。`deny` は `--force` / `--force-with-lease[=…]` / `--force-if-includes` / `--delete` /
`--mirror` / `--prune`、`f` か `d` を含む束ねた短オプション、`+` 始まりの refspec、`:` 始まり
(src が空 = リモート ref 削除)の refspec。`ask` は**読み切れなかったとき**の fail-closed 値で、
push セグメント内の変数・コマンド置換、`push` または `mirror` に言及する `-c` 上書き
(`-c remote.origin.push=+refs/…` は引数走査では見えず、`-c remote.origin.mirror=true` は
フラグを 1 つも書かずに `--mirror` 相当にする。`mirror` は `push` を部分文字列に持たないので
別パターンが要る。git の設定キーは大文字小文字を区別しないので、`remote.origin.MIRROR` も同じに扱う)、
同じ設定を環境変数で運ぶ `GIT_CONFIG*` で始まる token(前置きの代入でも `export` でも)、
および**コマンド位置を確定できないセグメント**(下記)。それ以外は**無出力 exit 0** で
`defaultMode: auto` のクラシファイア判定に落ちる。`ask` は auto mode でもプロンプトを出す
(公式ドキュメントの PreToolUse 契約)ので、フェイルクローズが実際に閉じる。

実装上の要点:

- **読み取り(セグメント分割・引用符の解釈・区切りの正規化)は共有 reader が行う**
  (`dot_claude/scripts/lib/shell-reader.bash`、テストは `test/shell-reader.bats`、概要は
  `.claude/rules/shell-reader.md`)。引用符の中の区切り(`git commit -m "a; b"`)で `deny` しないのは、
  reader が引用符を解釈するため。
- **`$`/バッククォートの検査は push セグメントに限定する。** コマンド全体に広げると
  `git commit -m "$(date)" && git push origin x` まで `ask` になり、承認疲れの解消という目的を
  自分で潰す。一方 `F=--force; git push $F` は push セグメント側に `$` が出るので捕まる。
- **長オプションは前方一致で見る(部分一致ではない)。** git は長オプションの一意な前方一致を
  受け付ける(`--dele` は `--delete`、`--force-w` は `--force-with-lease`。実 git で `--dele` が
  リモートブランチを消すことを確認済み)ので、`=` より前が危険なオプションの前方一致なら `deny`。
  曖昧な前方一致(`--d` は `--dry-run` とも一致)は git 自身がエラーにするので、`deny` にしても
  失うものは無い。部分一致にすると `--no-force-with-lease` を force として誤検出する。
- **番兵の byte・プロセス置換・ブレース展開・パス名展開は `ask`。** reader の segment 区切りの番兵
  (`\x01`)が入力にあると、redirect 先を `\x01` にした force push(bash には普通の文字なので `--force` は
  git の引数に残る)が reader には `--force` だけの別 segment に見えて無出力になっていた。`push` を含む
  コマンドで `SHELL_READER_SEP_IN_INPUT` か `PROCESS_SUBSTITUTION` が立てば `ask` にする。ただし
  segment の走査は続け、読み切れた別の segment に危険な綴りがあれば `deny` が勝つ
  (`git push origin main --force; cat <(true)` を `ask` に格下げしない)。segment にブレース展開
  (reader の `SHELL_READER_BRACE_INDEXES`)かパス名展開(`GLOB_INDEXES`。引用符の外の `*` `?` `[`)が
  あるときも `ask` — `{main,--force}` や `-{f..f}`、cwd に `-f` を置いた `-?` は展開の結果としてだけ
  危険な綴りを作り、token には現れない。binary やサブコマンドそのものを展開で作る綴り
  (`git {push,origin,main,--force}`、bash の `{git,push,…}`、`env {git,push,…}`、`/usr/bin/gi? push …`)は
  `git` と `push` が別の token として現れないので、コマンドの位置の token に印があり segment に `push` を
  含む token があるとき、またはサブコマンドの token に印があり `push` を含むときも `ask` にする。
  コマンドの位置とサブコマンドに限るのは、`grep -n push *.sh` のような引数の glob を巻き込まないため
  (`xargs /usr/bin/gi? push …` のように前置詞の後ろで git を展開で作る綴りは残存)。
  後ろが空白の `{` はグループ(`{ git push origin main; }`)なので reader が記録せず、無出力のまま。
  コマンドの位置の token が置換か変数(`$G push …`、`` `which git` push … ``、`"$(command -v git)" push …`、
  引用符の外の `${G} push …`。最後のものは reader が `{` で切るので、後ろの token にブレースの印がある
  単独の `$` として読む)のときも、同じく segment に `push` を含む token があれば `ask`。引用符の外の
  `$(which git) push …` は reader が `)` で segment を切り、push の segment が `push` そのものか git の
  全体オプション・リダイレクト(`-C . push …`、`2>/dev/null push …`)から始まるので、その segment が
  引用符の外の `$(`(`$` で終わる token の直後の区切り)より後ろにあり、先頭がそれらのときも `ask` に
  する。コマンド全体の `$` では
  なく `$(` の位置で絞るのは、heredoc 本文の行頭の `push` と別の行の `$HOME` を組み合わせないため。
- **zsh の綴りも読む。** Bash ツールは利用者のシェル(このマシンでは zsh)で動くので、`=git`(EQUALS。
  PATH 上の git に展開される)の語頭の `=` を外して binary を読み、`=(…)`(zsh のプロセス置換)を
  reader が `PROCESS_SUBSTITUTION` として返す。`=git push origin main --force` はこれが無いと無出力で、
  `deny` ルールのプレフィックス照合にも当たらなかった。
- **`--attr-source <tree>` は値を別の token に取る。** `-C` / `--git-dir` などと同じく 2 つ進める。
  並べないと値(`HEAD`)がサブコマンドに見え、`git --attr-source HEAD push … --force` が無出力だった。
- **引用符は reader が外した token を読む。** `git push origin "+main"` の token は `+main` になる
  ので `+` 始まり判定が効く(この処理自体は上の共有 reader の性質)。
- **`git` がトークン0に無いセグメントを素通りさせない。** 正規化で潰した3経路
  (グルーピング記号・リダイレクト・継続行)に加えて、**普通のトークンとして binary の前に立つもの**
  が4つ目の経路だった。先頭の変数代入(`VAR=v git push …`)と、シェルキーワード・コマンド前置詞
  (`if` / `then` / `elif` / `else` / `fi` / `while` / `until` / `do` / `done` / `!` / `time` /
  `nohup` / `command` / `env` / `sudo` / `nice` / `exec`)を読み飛ばしてから binary を読む。
  1行の `for r in …; do git push $r --force; done` や `if true; then git push --force; fi` は
  エージェントが普通に書く綴りで、修正前はいずれも**無出力**だった。読み飛ばしは配列を
  スライスせずインデックスを進める形で書く — bash 3.2 は `set -u` 下で空配列の展開を拒否する。
- **認識に失敗したセグメントにも床を張る(コマンド位置の床)。** 上のリストに無い前置詞(`xargs -n1 git push …`)では
  コマンド位置を確定できない。そこで、セグメント内に reader の token として `git`(basename が
  `git`)と読めるものがあれば、そこから同じ走査をやり直し、危険な綴りが見つかったら `deny` ではなく
  **`ask`** にする。deny にしない理由は、`gh pr create --body "$(cat <<EOF … )"` の中の
  `- git push --force を deny する` のような**散文が同じ形にトークナイズされる**ため。
  `echo "git push --force"` が無出力のままなのは、引用符の中が reader の token 1 つ
  (`git push --force` 全体)になり、`git` と読める token が無いため(`echo "git" push … --force` は
  reader が引用符を外して `git` の token になるので `ask`)。
  ただし**バッククォートだけは剥がす** — `` `git push …` `` は実行されるので、
  引用符とは違いテキストではない。この床のおかげで `$(git push … --force)` と
  `` `git push … --force` `` のどちらも `ask` に落ちる。token の途中のバッククォートも実行されるので、
  最後のバッククォートより後ろを見る: 引用符の外の `` x=`git push origin main --force` `` は reader が
  空白で割って代入の token が `` x=`git `` になり、前置の読み飛ばしで command_start の手前に来るので、
  この床の走査は先頭の token から始める(手前にあるのは代入とキーワード・前置詞だけ)。
  この床では、危険な綴りに加えて **push の引数の `$` / バッククォート**でも `ask` にする
  (`` x=`git push origin $r` `` や `` echo `git push origin $r` `` は、変数が `--force` を運んでも
  無出力だった)。コマンド位置の push と違って見るのは push の引数だけで、git を包む置換を閉じる
  末尾のバッククォート 1 つは数えない(`` x=`git push origin main` `` は無出力のまま)。`-c` の検査は
  push を壊す値(`remote.*.push` / `remote.*.mirror` / `include*`)に絞って使い、`GIT_CONFIG*` の token も見る。
  `nice -n 0` / `timeout 60` / `sudo -n` の後ろの git はこの床に来るので、見ないと
  `timeout 60 git -c remote.origin.mirror=true push origin` が無出力だった(実 git でリモートのブランチが消える)。
  `-c push.autoSetupRemote=true` のような無害な設定は巻き込まない。どれが立っても `deny` にはしない。
  初版はこの床が無く、しかも `$`/バッククォートの fail-closed 判定が「binary が git だった」
  分岐の**内側**にあったため、認識器が外れた瞬間に fail-closed 自体が無効化されていた。
- **字面の床(行単位のテキスト走査)。** 上の床でも、構文として読み切れない入力(閉じない引用符、
  `$(…)` / バッククォートの内側)は取りこぼす。そこで行ごとに、`$` かバッククォートを含む token、
  **改行を含む token**、`UNCLOSED_QUOTE` のときの最後の token を対象に、`git … push` と危険な綴りが
  同じ行にあれば `ask` にする。改行を含む token を見るのは、reader が heredoc とコメントを知らないため:
  本文やコメントの中の引用符 1 つ(`it"s`、`# "`)で走査だけが引用符の中に入り、次の同じ引用符までの行
  (bash が実行する force push を含む)が 1 token に飲み込まれる。閉じる引用符もそろうと
  `UNCLOSED_QUOTE` は立たないので、この条件が無いと無出力で通っていた。
  加えて、`$(` / `${` / バッククォートを含む最初の token から後ろはすべて対象にする。reader は引用符の
  中の置換の入れ子の引用符を知らないので、`echo "$(echo "a it's")" ; git push origin main --force ; echo ' x'`
  では入れ子の `"` で引用符が閉じたと読み、bash が実行する push が改行も `$` も無い 1 token に飲み込まれる
  (閉じない引用符の最後の token も空になる)。ずれは置換より後ろでしか起きない。
  危険な綴りは token の判定と同じく、長オプションの前方一致(`--forc`)と `-c` の push / mirror の設定も含む。
  `deny` が既に決まっていれば走らせない。散文が同じ形になりうる(PR 本文など)ので `deny` にはせず、
  同じ行に「git … push」と `-f` や `:x` を含む散文が `ask` になる誤 ask は受容している。
  短フラグ(`-f` など)も対象で、token の判定と同じく数字を含む束(`-4f` は `--ipv4` + `--force`)も一致させる
  (`test/git-push-guard.bats` が「token の判定で deny する束は床でも ask」を対で固定している)。長さ超過の入力では、同じ床を生のコマンド全体に当てる(下の上限)。
  行の分割と照合は共有 reader の `shell_reader_any_line_matches` が行う(curl-guard の床と共用)。
  照合の前に行継続(`\` + 改行)をつなぎ、引用符と backslash を外す — シェルはこれらを外してから
  語を読むので、生の字面では `"$(git'' push … --force)"` や、長さ超過の `'git' push … --force` /
  `git push … \⏎--force` が一致しなかった。つなぐときは何も足さず(空白を足すと `--\⏎force` が
  `-- force` になる)、つなぐ前の各行も残す。行末の `\` は行継続とは限らず(`echo a\\` の `\\` は
  シェルには `\` 1 文字で、次の行は別のコマンド)、つないだ行だけだと `echo agit push … --force` に
  なって語頭の `git` に一致しない。reader は二重引用符の中で `\\` を `\` 1 つにするので、`\` の
  個数では区別できない。正規化は `awk` と `tr` を 1 回通す(bash 3.2 の `${s//…}` は
  8 KB で 3 秒かかる)。引用符も backslash も無ければ fork しない。行の分割は改行での単語分割
  (`set -f` の下)で行う。here-string は一時ファイルを使うので `$TMPDIR` に書けないと黙って
  「一致なし」になり、`${s%%$'\n'*}` / `${s#*$'\n'}` の行ループは毎行残りをコピーして二乗になる
  (179 KB で 2.3 秒。単語分割は 0.02 秒)。
- **起動時の約束(lib・jq・stdin・`HOME`)の正本は `test/guard-contract.bats`(`just test-guard-contract`)。**
  lib が無い / 空 / 構文エラーなら `ask`(`[[ -r ]]`・フック自身の `"$BASH" -n`・`declare -F` で確かめてから使う。
  素の `source` ではそれぞれ exit 1 / exit 2 = 理由なしのブロック / exit 127 = フェイルオープンになる)。
  jq が無い・stdin が JSON でないときは、生の入力に `push` があれば `ask`、無ければ無出力(無関係な
  コマンドまで `ask` にしても承認を惰性にするだけ)。「生の入力」は command だけでなく stdin の JSON 全体
  (`cwd`・`transcript_path`・`description` を含む)なので、jq が無い間は cwd などに `push` を含む場所では
  無関係なコマンドも `ask` になる(curl-localhost-guard の `curl` も同じ)。jq が無い状況自体がまれなので受容している。新しい PreToolUse guard はこのテストの一覧に 1 行足す。
- **上限は 8192 byte。** `LC_ALL=C` で数え、超えたら reader は token を作らず `TOO_LONG` を返す。
  git-push-guard はこのとき上の字面の床を生のコマンドに当て、一致すれば `ask`(`deny` ではない)、
  しなければ何も返さない(classifier に任せる)。長い PR 本文の散文が `ask` になるのは受容している。
  床に一致しない形(危険な綴りが別の行にあるなど)を守るのは、`settings.json.tmpl` の先頭フラグ形
  `deny` 3 行だけになる。
- **`-c alias.<name>=…` に push を含むものは、サブコマンドに関係なく `ask`。**
  `git -c alias.p='push --force' p origin main` はサブコマンドが `p` なので、`push` と分かった後にだけ
  立てていた `-c` の検査に届かなかった。alias の展開先は読まないので `deny` ではなく `ask`。
  git の設定キーは大文字小文字を区別しないので `ALIAS.p=…` も同じに扱う。
  `--config-env alias.<name>=VAR` は `=` の後ろが環境変数の名前で展開先が読めないので、値に関係なく `ask`
  (`A='push --force' git --config-env=alias.p=A p origin main` が無出力だった)。push の segment の
  `-c include.path=…` / `includeIf.*` も、読めないファイルの設定を取り込むので `ask`。
- **heredoc の本文とコメントの中の危険な綴りは `ask` 止まり。** reader は heredoc もコメントも知らないので、
  `git commit -F - <<'EOF'` の本文の行 `git push --force を deny する` や、`git push origin main # do not --force`
  の `--force` が `deny` になっていた。`deny` は承認しても通せないので、このフックについてのコミットメッセージを
  heredoc で書けなかった。heredoc 演算子(reader の `SHELL_READER_HEREDOC_INDEXES`)より後ろの
  segment と、push の引数の語頭の `#` より後ろでは、危険な綴りを `ask` にする。受容した格下げ: heredoc の後ろに
  実際に書かれた force push と、引用された `'#x'` の後ろの `--force` も `ask` になる(どちらも確認は出る)。
  heredoc かどうかを token 列から判定してはいけない: `<<`・here-string の `<<<`・`< <(…)` はどれも `<`, `<` の
  演算子 token になり、初版は本文を持たない `cat <<< x; git push origin main --force` まで `ask` に下げていた。
  reader が走査の時点で「前後に `<` が続かない引用符の外の `<<`」だけを記録する。
- **コマンド全体を見る検査は 1 回だけ走らせる。** `GIT_CONFIG*` の token の検査を push の segment ごとに
  コマンド全体へ当てていたため segment 数 × token 数の二乗になり、8 KB 近い
  `git push origin main --force;git push;…` が 5 秒(フックの timeout)を越えて判定なし = フェイルオープンに
  なっていた。segment の走査の前に 1 回だけ数える(`test/git-push-guard.bats` に時間の上限つきのケースがある)。
  展開の印(`BRACE_INDEXES` / `GLOB_INDEXES`)も同じ形で二乗になっていた: `{` は 1 byte ごとに同じ index の印を
  足し、` *` は 2 byte ごとに印を足すので、push の segment ごとに印の全件を走査すると 8 KB で 8 秒かかった。
  reader は同じ index の印を 1 回だけ残し、フックは印の全件ではなく segment の token ごとに引く。
- **残存(受容): 大文字小文字。** 大文字小文字を区別しない APFS では `GIT push --delete …` も git を
  実行するが、早期終了と basename の比較が大文字小文字を区別するので無出力になる(ADR 0009)。
- **残存(受容): 早期終了は引用符除去より前。** コマンドに `push` の部分文字列が無ければ reader を
  呼ばずに終わるので、`git pu""sh origin main --force` は何も返さない(ADR 0009)。展開で `push` を
  作る `git {pu,}sh …` も同じ。
- **残存(受容): 永続した設定。** 同じコマンドや前の呼び出しの `git config remote.origin.mirror true`
  (や `remote.<name>.push=+…`)の後の素の push は無出力。読むのはコマンド文字列だけで、リポジトリの
  設定は読まない。
- **残存(受容): `$(…)` の後ろの危険な綴りは `ask` 止まり。** reader は `$(` で segment を切るので、
  `git push origin $(git branch --show-current) --force` の `--force` は push の segment に入らない
  (push の segment の `$` で `ask` にはなる)。`deny` にするには reader が置換の入れ子を追う必要がある。
- **残存(受容): zsh のグロブのグループ・修飾子 `(…)`。** reader は語の途中の `(` を segment の区切りに読むので、
  `git push origin HEAD:main README.md(e:'reply=(-f)':)` や、cwd に `-f` があるときの `-(f)(N)` / `(-f|zz)` は
  `-f` が push の segment に入らず無出力になる(実 zsh で force push を確認)。修飾子の `e:'…':` / `+…` は
  中身をコードとして実行するので、`echo *(e:'git push origin main --force':)` のように force push を丸ごと
  修飾子に入れた形も無出力になる(引用符の中は 1 token。`bash -c "…"` と同じ種類で、ADR 0009)。
- **残存(受容): git-core の dashed binary と `send-pack`。** `…/libexec/git-core/git-push origin main --force` と
  `$(git --exec-path)/git-push …` は basename が `git` ではなく、`git send-pack --force …` はサブコマンドが `push`
  ではないので無出力になる。
- **残存(受容): 標準入力が運ぶ引数。** `echo --force | xargs git push origin main` の `--force` はパイプの左側にあり、
  push の segment に危険な綴りが無いので無出力になる。
- **残存(受容): `env -S "<文字列>"`。** `bash -c` の内側と同じく、文字列は 1 token になって読まない。
- **ログ出力先の決定はスクリプト内に持つ。** `settings.json` 側で
  `mkdir -p … && script 2>>log` と書くと、ログディレクトリを作れないときに
  **リダイレクトの失敗でスクリプトごと走らない** = 判定なし = フェイルオープンになる
  (`;` に変えても直らない。リダイレクトの失敗はそのコマンドを放棄させる)。フックの
  `command` はスクリプトのパスそのものにして、ログは開けたときだけ `exec 2>>` で繋ぐ。
  開けるかの判定は `-w` ではなく `(: >>"$LOG_FILE")` の実書き込みで行う — `exec` は
  special builtin なので、開けなかった場合に**無出力でシェルごと落ちる**(= 塞ごうとしている
  フェイルオープンそのもの)。書き込めない `$HOME` でも deny が出ることを `test/guard-contract.bats` で固定してある。

フックが未配置・クラッシュした場合は無出力=判定なしで**フェイルオープン**する。そのため
`settings.json.tmpl` の `deny` にある先頭フラグ形3行(`--force` / `--force-with-lease` / `-f`)は
冗長に見えても**残してある**(多層防御の床)。Source 上の配線(`PreToolUse` / `matcher: "Bash"` /
直接呼び出し / timeout / `disableAllHooks` が立っていないこと)とこの 3 行の存在は
`just test-settings-hooks`(`test/settings-hooks.bats`)が描画結果で固定している。
フック自身の判定は `just test-scripts`(`test/git-push-guard.bats`)がテストする。テストは危険な綴りだけでなく**無出力になるべきケース**と対で書くこと — 片側だけだと
「常に deny するフック」が全テストを通過してしまう。
設計: `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` の 2026-09-16 addendum。
