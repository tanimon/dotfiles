## Claude Code specifics

Everything above applies to every agent working in this repository. This section is the Claude Code Runtime Extension — mechanisms that exist only on Claude Code's launch path and are not available to Codex or Cursor.

### Slash commands and the harness loop

```sh
/harness-reflect                     # Extract session learnings into ~/.claude/harness/queue.md
/harness-review                      # Health check + queue triage -> one PR (7-day cadence)
bash ~/.claude/scripts/harness-doctor.sh  # Deterministic liveness check
launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly  # 週次ジョブを今すぐ 1 回実行する(ターミナルから。launchd の定義どおり nono の内側で走る。有料)
```

The loop itself (SessionEnd hook, queue, briefing) is described under "Harness self-improvement loop" above; these are the Claude Code entry points into it.

### Sandbox

The `claude` shell command is wrapped by `dot_config/zsh/sandbox.zsh` so that **this session is running inside nono** (macOS Seatbelt, deny-all default) unless it was launched by a path that bypasses the wrapper, in which case Claude Code's own native Bash sandbox applies. Exactly one boundary is in effect per launch path. Read `dot_config/nono/CLAUDE.md` before assuming a path or host is reachable.

### Browsing

Web の取得は組込みの WebFetch / WebSearch を使う(専用のブラウジング skill は置かない。撤去の経緯は #360)。`mcp__claude-in-chrome__*` は使わない — nono のポリシーはブラウザ経路を前提に書かれておらず、WebFetch / WebSearch 自体が nono の egress allowlist の内側に留まるかも未検証(`dot_config/nono/CLAUDE.md`)。

### Bash ツールの落とし穴

どのリポジトリでも成立する落とし穴なので `dot_claude/rules/claude-code/bash-tool.md` に置いてある。`dangerouslyDisableSandbox: true` のコマンドでは `$TMPDIR` が別になること(「一時ファイルとファイルの置き場所」)と、完了しているのにタイムアウトを誤報告すること(「その他」)の 2 つは、症状が「失敗」ではなく「別のものに成功した」ように見える。

### Global configuration

Claude Code also loads `~/.claude/CLAUDE.md` and `~/.claude/rules/**` (deployed from `dot_claude/`). Those are user-global, not repository-specific; how they are composed is described under "Global agent instructions" above.
