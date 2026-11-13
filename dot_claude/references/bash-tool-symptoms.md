# 症状が出たときにだけ要る Bash ツールの対処

常時読み込まれる `~/.claude/rules/claude-code/bash-tool.md` の「症状から引く項目」節が、症状からこのファイルを指している。
どれもサンドボックスが原因で、対処が決まっている。

## Docker はサンドボックス内では動かない

`~/.docker/buildx/activity` への書き込み拒否(`operation not permitted`)か、
Docker ソケットへの接続拒否(`permission denied … docker.sock`)が出たらサンドボックスが原因。
調査せず、通常の権限フローでサンドボックス外に出して再実行する。

**理由:** 仕事用 worktree のセッションの 3〜5 割で、毎回 1 ターン使って同じ原因を再発見していた。
Docker ソケットをサンドボックスで許可するとホスト全体への経路になるため、許可はしていない。

## aws CLI のキャッシュ書き込み

aws CLI は読み取りだけの呼び出しでも `~/.aws/cli/cache` に書くので、
`Operation not permitted …/.aws/cli/cache` は調査せずサンドボックス外で再実行する。

**理由:** 1 つのセッションで、読み取りだけの aws 呼び出しを 4 回再実行した。

## `dangerouslyDisableSandbox: true` のタイムアウト誤報告

`dangerouslyDisableSandbox: true` のコマンドは、完了しているのにタイムアウトを誤報告することがある。コマンド本体は
終わっているのにシェルが生き残り、60s/120s で「background に移した」と報告される。**再実行する前にタスク出力ファイルを
読むこと** — 中身が完了を示していれば、そのまま再実行すると同じ破壊的操作を二度走らせる。
