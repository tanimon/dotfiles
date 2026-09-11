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
