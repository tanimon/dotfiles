---
date: 2026-09-28
trigger: "Bash ツール・サンドボックス・権限照合の同じ落とし穴を、リポジトリを跨いで毎回再発見していた"
---

# Bash ツール・サンドボックス・権限照合の落とし穴

Claude Code 専用のルール。どのリポジトリでも成立する。この dotfiles リポジトリの CLAUDE.md にしか
書かれていなかったため、他リポジトリのセッションで 2 か月後も同じ失敗が起きていた。

## Bash ツールは zsh で動く

- **`=` で始まる語をクォートする。** `echo === x` は zsh の `=cmd` 展開で `== not found` になり、
  コマンド全体が exit 1 で出力ごと失われる。区切り線は `echo '==='` か `echo ---` にする。
- **glob を含む引数はクォートする。** zsh は一致しない glob でコマンド全体を `no matches found` で止める。
  `grep -r --include='*.vue'` のようにオプション値の `*` も対象。`no matches found` の後に出た件数(`0` など)は無効。
- **`path` `fpath` `cdpath` `manpath` `status` `argv` を変数名にしない。** `for path in …` は `PATH` を書き換え、
  以降の外部コマンドが `command not found` になる。症状は代入から離れた場所で出る。
- `$VAR` の直後に `:` が続くときは `${VAR}` で閉じる(`:a` `:h` などが修飾子として消費される)。

## 権限とサンドボックス除外はコマンド文字列の前方一致

`permissions.allow` / `ask` / `deny` と `sandbox.excludedCommands` は、Bash に渡した文字列の先頭で照合する。

- **ラッパー経由のコマンドは除外されない。** `excludedCommands` の `gh *` / `docker *` は、先頭が `gh` / `docker`
  のときだけ効く。`$(gh …)`、`sh -c "gh …"`、内部で gh や docker を呼ぶスクリプト(`./scripts/worktree/*` など)は
  サンドボックス内で走る。
- **制御構文で包むと allow に当たらない。** `if … fi` や `for` で包んだコマンドは allow ルールにマッチせず(実測)、
  非決定的な分類器の判定に落ちる。`&&` / `;` / `|` で繋いだものはサブコマンドごとに照合されるので、1 つでも
  allow に無いサブコマンドがあれば全体が当たらない。決定的に通したいコマンドは単独の 1 コマンドにし、
  分岐はツール呼び出しの外に置く。
- **`gh api` はエンドポイントを最初の引数にする。** `gh api repos/<o>/<r>/pulls/<n>/reviews -X POST --input <file>` の順に書く。
  `-X POST` を前に置くか先頭に `/` を付けると allow の `Bash(gh api repos/…)` に当たらない。

**理由:** 無人 PR レビューの投稿が `if … fi` で包まれていたため 26 回拒否され、完成済みレビューが捨てられた。
`gh api -X POST …` の形でも 1 か月おいて 2 回ブロックされた。

## Docker はサンドボックス内では動かない

`~/.docker/buildx/activity` への書き込み拒否(`operation not permitted`)か、
Docker ソケットへの接続拒否(`permission denied … docker.sock`)が出たらサンドボックスが原因。
調査せず、通常の権限フローでサンドボックス外に出して再実行する。

**理由:** 仕事用 worktree のセッションの 3〜5 割で、毎回 1 ターン使って同じ原因を再発見していた。
Docker ソケットをサンドボックスで許可するとホスト全体への経路になるため、許可はしていない。

## サンドボックス内の git 操作は途中で止まることがある

`git merge` / `rebase` / `checkout` は、保護されたパス(他ディレクトリの `.claude/agents` など)への書き込みで
`Operation not permitted` になり、作業ツリーに untracked の残骸を残して止まる。
`--abort` で戻ったと思わず `git status` で残骸を確認し、サンドボックス外でやり直す。

`.git/config` もサンドボックス内では書けない(nono・ネイティブのどちらの境界でも。nono 側の意図は dotfiles リポジトリの `dot_config/nono/CLAUDE.md`)。
`.git/config` を書き換える操作は `could not lock config file …/.git/config` で失敗し、操作によって残る状態が違う。

- **`git push -u`:** 付けなくてよい。素の `git push` は upstream を書かずに同名のリモートブランチへ push する(`push.default = current`)。
  付けてしまっても push 自体は成功し、upstream だけが付かない。このエラーは調査せず、ユーザーへの報告にも書かない
  (`git branch --set-upstream-to=…` などの再設定も案内しない)。push できたことは、リモートの head と `HEAD` の一致で示す。
  `git ls-remote origin "refs/heads/$(git branch --show-current)" | cut -f1` と `git rev-parse HEAD` を比べる
  (`ls-remote` の出力は `<SHA><TAB><ref>` なので SHA 列だけを取り出す。upstream が無いので `@{u}` や `git status` の ahead/behind は使えない)。
  `git push origin HEAD:<headRefName>` で push したときは、`refs/heads/` の後ろを push 先の `<headRefName>` に替える
  (ローカル名のままだと、その ref が無いか古い SHA が返り、push 済みでも不一致に見える)。
  **理由:** 任意の許可(「報告しなくてよい」)の書き方では、「注意として一言添える」判断で 3 セッション続けて報告された。
- **`git branch -m`:** リネームは済むが、config の書き換えで `fatal: branch is renamed, but update of config-file failed` を出して exit 128 になる(branch config の有無に関係ない)。
  `git branch --show-current` で確かめ、再実行しない。
- **`git switch -c <b> origin/<x>`:** ブランチは作られるが HEAD は移らない(追跡設定の書き込みで中断する)。
  `git switch --no-track -c <b> origin/<x>` なら config を書かずに切り替わる(実測)。
- **ローカルのブランチ名が PR の head と違うときは素の `git push` を打たない。** 素の push はローカル名で push するので別のリモートブランチができ、その削除は
  push guard が止める。既存 PR へ push するときは `gh pr view --json headRefName -q .headRefName` で head を引き、
  `git push origin HEAD:<headRefName>` と明示する。

## 一時ファイルとファイルの置き場所

- **`$TMPDIR` はサンドボックスの有無で変わる。** サンドボックス内で `$TMPDIR` に書いたファイルは、
  サンドボックス外のコマンドからは見えない。`$TMPDIR` は並行セッション間で共有されることもある。
  呼び出しを跨ぐファイルは scratchpad の絶対パスに置く。
- **scratchpad は数日で消える。** ユーザーが後で開く・実行する・貼り付ける成果物(依頼用 SQL、返信文面など)は
  scratchpad に置かず、リポジトリ内かユーザーが指定した場所に置く。パスを案内する前に `ls` で実在を確かめる。

## その他

- **`run_in_background` の Bash の完了を `sleep` で待たない。** background の Bash も終了すると task-notification で
  呼び戻される(サブエージェントと同じ。`subagents.md`)。待つ間はターンを終えるか別の作業をする。
  途中経過が要るときだけ、sleep を付けずに出力ファイルを 1 回読む。`sleep 120〜300; tail <output>` を
  1 セッションで 6 回繰り返した例がある。
- **`gh auth token` の出力を表示しない。** `| head -c 20` のように一部だけ出しても分類器が拒否する。
  認証の確認は `gh auth status` か `gh auth token >/dev/null 2>&1 && echo ok` で行う。
- **`git diff` は difftastic で表示される。** このマシンは `diff.external = difft` なので、出力に `+` / `-` の行頭記号が無い。
  grep や wc で機械処理するときは `git diff --no-ext-diff` を使う。行頭記号の grep が 0 行でも「差分なし」の証拠にならない。
- **Bash で読んだだけのファイルは Edit できない。** `Edit` / `Write` は `Read` ツールで読んだファイルにしか使えず、
  `cat` や `sed -n` で読んでも `File has not been read yet` で失敗する。直前に `Read` するか、編集も Bash で行う。
