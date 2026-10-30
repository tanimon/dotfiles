# サンドボックス内の git 操作は途中で止まることがある

エラーが出たときにだけ要る手順。常時読み込まれる `~/.claude/rules/claude-code/bash-tool.md` の
「サンドボックス内の git 操作は途中で止まることがある」節が、エラー文字列からこのファイルを指している。

## 保護されたパスへの書き込み

`git merge` / `rebase` / `checkout` は、保護されたパス(他ディレクトリの `.claude/agents` など)への書き込みで
`Operation not permitted` になり、作業ツリーに untracked の残骸を残して止まる。
`--abort` で戻ったと思わず `git status` で残骸を確認し、サンドボックス外でやり直す。

## `git worktree add`

`git worktree add -b <b> <path>` は、`<path>` が書き込み許可の外(cwd の兄弟ディレクトリ `../<name>` など)だと
`could not create leading directories … Operation not permitted` で失敗するが、ブランチ `<b>` は先に作られて残る。
やり直すときは `-b` を外して `git worktree add <書ける path> <b>` とする(`-b` のままだと `already exists` で失敗する)。
後で使い続ける作業ツリーは、サンドボックス外で兄弟ディレクトリに作る。scratchpad は数日で消える(`bash-tool.md` の「一時ファイルとファイルの置き場所」節)ので、
置くのはその場で捨てる検証用だけにし、残す変更をコミットしてから `git worktree remove <path>` で登録ごと消す。
ディレクトリだけが消えると未コミットの変更が失われ、`git worktree prune` するまで登録が残って、
そのブランチは別の path でも `is already used by worktree` で使えない。

## `.git/config` への書き込み

`.git/config` もサンドボックス内では書けない(nono・ネイティブのどちらの境界でも。nono 側の意図は dotfiles リポジトリの `dot_config/nono/CLAUDE.md`)。
`.git/config` を書き換える操作は `could not lock config file …/.git/config` で失敗し、操作によって残る状態が違う。

- **`git push -u`:** push 自体は成功し、upstream だけが付かない。報告の扱いは `bash-tool.md` の `git push -u` の項に従う。
  push できたことは、リモートの head と `HEAD` の一致で示す。
  `git ls-remote origin "refs/heads/$(git branch --show-current)" | cut -f1` と `git rev-parse HEAD` を比べる
  (`ls-remote` の出力は `<SHA><TAB><ref>` なので SHA 列だけを取り出す。upstream が無いので `@{u}` や `git status` の ahead/behind は使えない)。
  `git push origin HEAD:<headRefName>` で push したときは、`refs/heads/` の後ろを push 先の `<headRefName>` に替える
  (ローカル名のままだと、その ref が無いか古い SHA が返り、push 済みでも不一致に見える)。
- **`git branch -m`:** リネームは済むが、config の書き換えで `fatal: branch is renamed, but update of config-file failed` を出して exit 128 になる(branch config の有無に関係ない)。
  `git branch --show-current` で確かめ、再実行しない。
- **`git switch -c <b> origin/<x>`:** ブランチは作られるが HEAD は移らない(追跡設定の書き込みで中断する)。
  `git switch --no-track -c <b> origin/<x>` なら config を書かずに切り替わる(実測)。
