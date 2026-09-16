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
別パターンが要る)、および**コマンド位置を確定できないセグメント**(下記)。それ以外は**無出力 exit 0** で
`defaultMode: auto` のクラシファイア判定に落ちる。`ask` は auto mode でもプロンプトを出す
(公式ドキュメントの PreToolUse 契約)ので、フェイルクローズが実際に閉じる。

実装上の要点:

- **セグメント分割**(`tr ';&|' '\n'`)を先に行う。`git commit -m wip && git push --force` を
  1つの文字列として見ると最初の動詞しか読めない。
- **分割の前に正規化が要る。** 「過剰分割は安全側に転ぶ」は**誤り**で、実際にはフェイルオープンする
  経路が3種類あった(いずれも修正前に再現済み):
  (1) **グルーピング記号がフラグに接着する** — `(cd dir && git push origin main --force)` の最後の
  トークンは `--force)` になり、完全一致の deny 判定から外れる。`(git push --force)` や
  `{ git push --force; }` では `tokens[0]` が `(git` / `{` になって「git ではない」と判定される。
  (2) **リダイレクトの `&` が分割してしまう** — `git push origin main 2>&1 --force` は
  `2>` と `1 --force` に割れ、フラグ側のセグメントに `git` が無くなる。
  (3) **バックスラッシュ改行** — 継続行が別セグメントになり同様。
  対策は分割前の3つの正規化(継続行の結合 → リダイレクト演算子の除去 → `(){}` の空白化)。
  `(){}` は**削除ではなく空白に置換**する(隣接トークンを連結させないため)。`$` は正規化の
  対象に**含めない** — `$(…)` が `$ …` になっても `$` が残るので、下のコマンド置換 fail-closed
  判定はそのまま効く。`(cd dir && git push origin feature)` が無出力のままであることを、
  対のテストで固定している。
- **`$`/バッククォートの検査は push セグメントに限定する。** コマンド全体に広げると
  `git commit -m "$(date)" && git push origin x` まで `ask` になり、承認疲れの解消という目的を
  自分で潰す。一方 `F=--force; git push $F` は push セグメント側に `$` が出るので捕まる。
- **長オプションは完全一致で見る。** 部分一致にすると `--no-force-with-lease` を force として
  誤検出する。
- **トークンの引用符は1層だけ剥がす**(`unquote`)。`git push origin "+main"` のトークンは
  `"+main"` のままなので、剥がさないと `+` 始まり判定が外れる。再実行はしないので、シェル忠実な
  unquote である必要はない。
- **`git` がトークン0に無いセグメントを素通りさせない。** 正規化で潰した3経路
  (グルーピング記号・リダイレクト・継続行)に加えて、**普通のトークンとして binary の前に立つもの**
  が4つ目の経路だった。先頭の変数代入(`VAR=v git push …`)と、シェルキーワード・コマンド前置詞
  (`if` / `then` / `elif` / `else` / `fi` / `while` / `until` / `do` / `done` / `!` / `time` /
  `nohup` / `command` / `env` / `sudo` / `nice` / `exec`)を読み飛ばしてから binary を読む。
  1行の `for r in …; do git push $r --force; done` や `if true; then git push --force; fi` は
  エージェントが普通に書く綴りで、修正前はいずれも**無出力**だった。読み飛ばしは配列を
  スライスせずインデックスを進める形で書く — bash 3.2 は `set -u` 下で空配列の展開を拒否する。
- **認識に失敗したセグメントにも床を張る。** 上のリストに無い前置詞(`xargs -n1 git push …`)では
  コマンド位置を確定できない。そこで、セグメント内に**生のまま**(引用符を剥がす前に)`git` と
  読めるトークンがあれば、そこから同じ走査をやり直し、危険な綴りが見つかったら `deny` ではなく
  **`ask`** にする。deny にしない理由は、`gh pr create --body "$(cat <<EOF … )"` の中の
  `- git push --force を deny する` のような**散文が同じ形にトークナイズされる**ため。
  生トークンで見るのは `echo "git push --force"` を無出力のまま保つため(引用された `git` は
  テキスト)。ただし**バッククォートだけは剥がす** — `` `git push …` `` は実行されるので、
  引用符とは違いテキストではない。この床のおかげで `$(git push … --force)` と
  `` `git push … --force` `` のどちらも `ask` に落ちる。
  初版はこの床が無く、しかも `$`/バッククォートの fail-closed 判定が「binary が git だった」
  分岐の**内側**にあったため、認識器が外れた瞬間に fail-closed 自体が無効化されていた。
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
冗長に見えても**残してある**(多層防御の床)。`just test-scripts`(`test/git-push-guard.bats`)が
テストする。テストは危険な綴りだけでなく**無出力になるべきケース**と対で書くこと — 片側だけだと
「常に deny するフック」が全テストを通過してしまう。
設計: `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` の 2026-09-16 addendum。
