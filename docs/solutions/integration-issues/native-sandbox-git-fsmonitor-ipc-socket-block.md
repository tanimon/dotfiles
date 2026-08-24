---
title: "git fsmonitor IPC blocked by Claude Code native sandbox's Unix socket allowlist"
date: 2026-08-15
last_updated: 2026-08-24
category: integration-issues
module: "Claude Code native Bash sandbox (dot_claude/settings.json.tmpl) / git core.fsmonitor"
problem_type: integration_issue
component: tooling
symptoms:
  - "`error: fsmonitor_ipc__send_query: unspecified error on '.../fsmonitor--daemon.ipc'` printed to stderr on every git invocation inside Claude Code's Bash tool"
  - "Error path varies per repo/worktree (`$GIT_DIR/fsmonitor--daemon.ipc`, or `<main-repo>/.git/worktrees/<name>/fsmonitor--daemon.ipc` under a git worktree)"
  - "(2026-08-24) 上記の最初の Solution（`.zshrc` 経由の `CLAUDECODE` 条件付き `GIT_CONFIG_*` export）を適用済みのはずが、実際には一度も抑制されていなかった"
root_cause: config_error
resolution_type: config_change
severity: low
tags: [claude-code, sandbox, seatbelt, git, fsmonitor, unix-socket, worktree]
related_components: [development_workflow]
---

# git fsmonitor IPC blocked by Claude Code native sandbox's Unix socket allowlist

## Problem

Every `git status`/`git add`/etc. run inside Claude Code's Bash tool (native sandbox path, i.e. `command claude` or any launch that does not go through the nono wrapper) printed an `fsmonitor_ipc__send_query` error to stderr, even though the command's exit code and stdout were unaffected.

## Symptoms

- `error: fsmonitor_ipc__send_query: unspecified error on '/path/to/.git/worktrees/<name>/fsmonitor--daemon.ipc'` on stderr for ordinary git commands (`git status`, `git commit`, …)
- Exit code stays `0` and stdout is unaffected — this is stderr noise only, not a functional break
- Reproduces only inside Claude Code's Bash tool sandbox; disappears with `dangerouslyDisableSandbox: true` or when nono wraps the session (nono's launch path disables Claude Code's own sandbox via `--settings '{"sandbox":{"enabled":false}}'`, see `dot_config/zsh/sandbox.zsh:14-22`)

## What Didn't Work

- **`git config --global fsmonitor.socketDir <fixed-dir>`** — the git manual (`git help fsmonitor--daemon`, "REMARKS") states the daemon only honors `fsmonitor.socketDir` when `.git` (or `$HOME`) is on a network-mounted filesystem. Verified empirically: with `fsmonitor.socketDir` set to a fresh directory, the daemon still created its socket at the default `$GIT_DIR/fsmonitor--daemon.ipc` because the filesystem here is native, not network-mounted. The configured directory stayed empty.
- **Editing `~/.claude/settings.json`'s `sandbox.network.allowUnixSockets` directly from within the session** — Claude Code's auto-mode classifier blocked the edit as self-modification of the agent's own sandbox config, requiring explicit user authorization it hadn't given for that specific change. This surfaced a real fork in the fix (see [Prevention](#prevention)), not just a permissions inconvenience.
- **(2026-08-15〜08-24 に運用していたが、実際には無効だった) `.zshrc`（`dot_config/zsh/sandbox.zsh`）に `CLAUDECODE` 条件付きの `export GIT_CONFIG_COUNT=1 / GIT_CONFIG_KEY_0=core.fsmonitor / GIT_CONFIG_VALUE_0=false` を書く** — 一見動きそうで、実際に `chezmoi apply` 済み・PRマージ済みの状態でも、後日ユーザーから同じ `fsmonitor_ipc__send_query` エラーが再発したと報告があり、稼働中セッションで実測して判明した。原因は二重: (1) Claude CodeのBash toolは**非対話シェル**でコマンドを実行するため、対話シェルのみ読み込まれる `.zshrc`（ひいては `sandbox.zsh`）がそもそも一度もsourceされない。(2) 百歩譲って最初の対話シェル起動時にこの行が実行されたとしても、Claude Codeの「シェルスナップショット」機構（`~/.claude/shell-snapshots/*.sh`、セッション開始時に一度だけ関数・alias・`PATH` を捕捉し、以降のBash tool呼び出しはこのスナップショットを再生するだけで `.zshrc` を再sourceしない）は `PATH` 以外の `export` を保持しない。実測: 稼働中セッションで `env | grep GIT_CONFIG` すると `GIT_CONFIG_COUNT=6` が Claude Code自身が設定する `credential.interactive` / `credential.guiPrompt` / `safe.directory`×4 用の値になっており、`core.fsmonitor` の上書きは存在しなかった。関数（`claude()` 等）はスナップショットに残るため、この失敗はexportに固有の落とし穴であり、単なる「試し忘れ」ではない。

## Solution

Claude Code自身が読む `~/.claude/settings.json` の**トップレベル `env`** キー（`dot_claude/settings.json.tmpl` の `env` ブロック）で `GIT_CONFIG_GLOBAL` を、`~/.gitconfig` をまず `include` してから `core.fsmonitor = false` だけ上書きする専用ファイルに向ける：

```jsonc
// dot_claude/settings.json.tmpl の env ブロック
"GIT_CONFIG_GLOBAL": "{{ .chezmoi.homeDir }}/.config/git/claude-code.inc"
```

```gitconfig
# dot_config/git/claude-code.inc
[include]
  path = ~/.gitconfig
[core]
  fsmonitor = false
```

`settings.json` の `env` はClaude Code自身がBash toolの子プロセスに渡す環境そのものなので、「シェルにexportして`.zshrc`経由で伝播させる」という失敗したアプローチと違い、**シェルの対話/非対話やスナップショットの有無に関係なく、Claude Codeが起動する全てのコマンドに確実に効く**。かつ、この`env`はClaude Code自身のプロセスにしか渡らないため、通常のインタラクティブなターミナル作業（`.zshrc`は素通り、`GIT_CONFIG_GLOBAL`も未設定）では`~/.gitconfig`の`fsmonitor = true`がそのまま有効 — 旧アプローチが`CLAUDECODE`分岐で狙っていた「Claude Code内だけ無効化」という区別を、より確実な機構で達成している。

なお `GIT_CONFIG_GLOBAL` は「global scopeとして読むファイル」を丸ごと差し替える変数であり、単に1エントリを追加する`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`とは独立した軸。そのため、Claude Code自身が同じBash tool呼び出しの中で独自に設定してくる`GIT_CONFIG_COUNT`（`credential.interactive`/`credential.guiPrompt`/`safe.directory`用、リポジトリごとに個数が変わりうる）と衝突しない — 実測: `GIT_CONFIG_GLOBAL`でfsmonitorを上書きしつつ、同時に`GIT_CONFIG_COUNT=2`で`credential.interactive=false`を追加注入しても、両方とも正しく解決される。`includeIf`（個人リポジトリ向け`core.excludesfile`切り替え、`dot_gitconfig.tmpl`参照）も`include`の後段で評価されるため影響を受けない。

## Why This Works

git's built-in fsmonitor daemon (`core.fsmonitor = true`) talks to git commands over a Unix domain socket at `$GIT_DIR/fsmonitor--daemon.ipc` (or, under a worktree, `<main-repo>/.git/worktrees/<name>/fsmonitor--daemon.ipc`). Claude Code's native Bash sandbox (`sandbox.network.allowUnixSockets` in `dot_claude/settings.json.tmpl`) denies outbound connections to any Unix socket not on its allowlist — which at the time of this fix contained only the 1Password SSH-agent socket, added for commit signing (see [native-sandbox-1password-socket-signing-2026-07-09.md](native-sandbox-1password-socket-signing-2026-07-09.md)). The fsmonitor socket isn't on that list, so the connection attempt fails; git degrades gracefully (falls back to a full filesystem scan) and only logs the failure to stderr.

Confirmed with a Seatbelt contrast test (`sandbox-exec -f <profile> git status`, isolated from Claude Code's own config): a profile denying all unix-socket `network-outbound` reproduces the exact error; the same profile with `(allow network-outbound (remote unix-socket (subpath "<repo>/.git")))` added does not. This also showed that a `subpath` grant on the parent `.git` **directory** — not the exact socket file — covers every worktree under that repo, since Seatbelt's `subpath` matches the given path and everything nested under it. That finding matters for anyone who instead widens `allowUnixSockets` (see Prevention below).

## Prevention

- **`.zshrc`/`dot_config/zsh/sandbox.zsh`はClaude CodeのBash tool呼び出しには効かない、と心得る。** Claude Code配下で「毎回のコマンド実行に確実に効かせたい環境変数」は、シェルの`export`ではなく`~/.claude/settings.json`の`env`（`dot_claude/settings.json.tmpl`）に置く。逆に、`sandbox.zsh`に残っている`claude()`/`codex()`のような**関数**定義はスナップショットに残るため引き続き有効 — 落とし穴は「exportとfunctionでスナップショットの扱いが違う」という点にある。
- **`GIT_CONFIG_COUNT`系を使うときは、Claude Code自身が同じ変数を使っている（`credential.interactive`/`guiPrompt`/`safe.directory`）ことを前提にする。** 数値インデックスは単純な後勝ち上書きであり、マージされない。個数はセッション/リポジトリ（worktreeの有無等）で変わりうるため、固定の`GIT_CONFIG_COUNT`を静的に足すと衝突・破壊のリスクがある（nono環境での類似事例: [nono-sandbox-migration-observations-2026-07-25.md](nono-sandbox-migration-observations-2026-07-25.md)）。今回のように「1つの値だけ上書きしたい」ケースでは、`GIT_CONFIG_GLOBAL`で`include`＋上書きの構成にする方が、Claude Code側の動的な`GIT_CONFIG_COUNT`と独立に扱えて安全。
- There were two viable fixes at the sandbox-config layer, and the choice is a real security/performance tradeoff, not a settled default — anyone touching this again should re-evaluate rather than assume one is strictly better:
  - **Chosen here: disable fsmonitor only for Claude Code's own processes** (this doc's fix, now via `GIT_CONFIG_GLOBAL`). No sandbox widening, zero added attack surface, fsmonitor stays fast for interactive terminal use. Cost: git commands *run by Claude Code itself* lose fsmonitor's speedup (usually not perceptible for repos this size).
  - **Alternative: widen `sandbox.network.allowUnixSockets`** with a directory entry (e.g. `~/.local/share/chezmoi/.git`) so fsmonitor also speeds up Claude Code's own git calls. Confirmed via `sandbox-exec` that Seatbelt's `subpath` semantics make a directory entry cover all present and future worktrees of that repo — but this was **only verified at the Seatbelt layer**; whether Claude Code's settings schema accepts a directory (vs. requiring an exact socket file path) is untested, and a directory grant also permits connecting to *any* Unix socket created under that tree, not just fsmonitor's. If you pursue this path, verify the schema behavior first (the `/sandbox` panel, or a controlled test edit with the user's explicit authorization) before rolling it out.
- Editing `~/.claude/settings.json`'s sandbox config from inside a running session is a self-modification the auto-mode classifier will block without prior explicit user authorization for that specific change — expect to stop and ask rather than routing around the denial.

## Related Issues

- [native-sandbox-1password-socket-signing-2026-07-09.md](native-sandbox-1password-socket-signing-2026-07-09.md) — the precedent for `allowUnixSockets` (1Password SSH-agent socket); same underlying Seatbelt Unix-socket-denial mechanism, different specific socket
- [claude-code-internal-sandbox-nested-seatbelt-conflict.md](claude-code-internal-sandbox-nested-seatbelt-conflict.md) — why nono-wrapped sessions don't hit this (native sandbox is disabled there)
- [native-sandbox-git-ssh-to-https-insteadof-reversal.md](native-sandbox-git-ssh-to-https-insteadof-reversal.md) — another case of the native sandbox breaking a git operation (raw TCP for SSH, not Unix sockets); its `ssh://` scp-form gap was closed the same day as this doc's rewrite (2026-08-24)
- [nono-sandbox-migration-observations-2026-07-25.md](nono-sandbox-migration-observations-2026-07-25.md) — the `GIT_CONFIG_COUNT`衝突（Claude Codeが自分のインデックスを使う）が最初に文書化されたのはnono環境でのこの事例。今回のネイティブサンドボックス側の再発は、同じ落とし穴を`GIT_CONFIG_GLOBAL`という別軸に逃がすことで回避した
- Fix opened in [tanimon/dotfiles#287](https://github.com/tanimon/dotfiles/pull/287); the `GIT_CONFIG_GLOBAL`-based follow-up fix that actually made it work is a separate, later PR
