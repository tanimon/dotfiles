## Claude Code specifics

Everything above applies to every agent working in this repository. This section is the Claude Code Runtime Extension — mechanisms that exist only on Claude Code's launch path and are not available to Codex or Cursor.

### Slash commands and the harness loop

```sh
/harness-reflect                     # Extract session learnings into ~/.claude/harness/queue.md
/harness-review                      # Health check + queue triage -> one PR (7-day cadence)
bash ~/.claude/scripts/harness-doctor.sh  # Deterministic liveness check
```

The loop itself (SessionEnd hook, queue, briefing) is described under "Harness self-improvement loop" above; these are the Claude Code entry points into it.

### Sandbox

The `claude` shell command is wrapped by `dot_config/zsh/sandbox.zsh` so that **this session is running inside nono** (macOS Seatbelt, deny-all default) unless it was launched by a path that bypasses the wrapper, in which case Claude Code's own native Bash sandbox applies. Exactly one boundary is in effect per launch path. Read `dot_config/nono/CLAUDE.md` before assuming a path or host is reachable.

### Browsing

Web の取得は組込みの WebFetch / WebSearch を使う(専用のブラウジング skill は置かない。撤去の経緯は #360)。`mcp__claude-in-chrome__*` は使わない — nono のポリシーはブラウザ経路を前提に書かれておらず、WebFetch / WebSearch 自体が nono の egress allowlist の内側に留まるかも未検証(`dot_config/nono/CLAUDE.md`)。

### Bash ツールの落とし穴

どちらも 2026-09-18 の `/doctor` で実際に踏んだもので、**症状が「失敗」ではなく「別のものに成功した」ように見える**のが共通点。

- **`dangerouslyDisableSandbox: true` のコマンドは `$TMPDIR` が別になる。** サンドボックス内のコマンドには専用の `TMPDIR`(`/var/folders/.../T/`)が渡るが、サンドボックスを外したコマンドはシェル本来の `TMPDIR` を見る。したがって**サンドボックス内で `$TMPDIR` に書いたファイルは、サンドボックスを外したコマンドからは存在しない**。「リストを作る → 権限の要るコマンドでそれを読む」という 2 段構えが静かに `no such file or directory` で落ちる。ファイルを跨がせるならセッションの scratchpad ディレクトリの絶対パスを使う。
- **`dangerouslyDisableSandbox: true` のコマンドは、完了しているのにタイムアウトを誤報告することがある。** コマンド本体は終わっているのにシェルが生き残り、60s/120s で「background に移した」と報告される。**再実行する前に必ずタスク出力ファイルを読むこと** — 中身が完了を示していれば、そのまま再実行すると同じ破壊的操作を二度走らせる。

### Global configuration

Claude Code also loads `~/.claude/CLAUDE.md` and `~/.claude/rules/**` (deployed from `dot_claude/`). Those are user-global, not repository-specific; global instruction synchronization across products is a separate change (#311).
