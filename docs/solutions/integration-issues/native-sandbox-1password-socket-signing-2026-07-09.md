---
title: "1Password SSH signing fails under Claude Code native sandbox (Could not connect to socket)"
category: integration-issues
tags: [claude-code, sandbox, seatbelt, 1password, ssh-agent, op-ssh-sign, git-signing, permissions]
date: 2026-07-09
module: Claude Code native Bash sandbox (dot_claude/settings.json.tmpl)
symptom: "git commit fails with 'Could not connect to socket' when signing under `command claude`"
root_cause: "The native Seatbelt sandbox denies the network-outbound connection from op-ssh-sign to the 1Password SSH agent Unix socket; Claude Code v2.1.205 has no Unix-socket allow key, so the only lever is sandbox.excludedCommands"
resolution: "2026-07-30: v2.1.220 で sandbox.network.allowUnixSockets が追加されたのでソケットを直接許可し、git commit を excludedCommands から削除した（git push は生 TCP のため除外のまま）"
---

# 1Password SSH signing fails under Claude Code native sandbox

> **2026-07-30 解決済み（この文書の「Solution」は歴史的経緯として残す）:** Claude Code v2.1.220 で
> `sandbox.network.allowUnixSockets` が追加され、ソケットを直接許可できるようになった。`git commit *` は
> `excludedCommands` から削除し、サンドボックス内で実行するようになった。詳細は下記
> [Resolution (2026-07-30)](#resolution-2026-07-30) を参照。`git push *` は別の理由（生 TCP）で除外のまま。

## Problem

With `gpg.format=ssh`, `gpg.ssh.program=/Applications/1Password.app/Contents/MacOS/op-ssh-sign`, and `commit.gpgsign=true`, running `git commit` under `command claude` (native Bash sandbox active, no safehouse) fails:

```
error: Load key ... : Could not connect to socket
fatal: failed to write commit object
```

`op-ssh-sign` cannot reach the 1Password SSH agent socket at `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock` (the value of `SSH_AUTH_SOCK`).

## Root Cause

macOS Seatbelt governs Unix domain socket connections via `network-outbound` rules. Claude Code's native sandbox (`sandbox.enabled: true`) generates a Seatbelt profile that does not permit the outbound connection to the 1Password agent socket, so `op-ssh-sign` — spawned inside the sandbox as part of `git commit` — is denied.

Claude Code v2.1.205 exposes **no** dedicated Unix-socket allow key. The `sandbox` schema is limited to `enabled`, `failIfUnavailable`, `network.{allowLocalBinding,allowedDomains}` (HTTP/HTTPS domains only — not sockets), `filesystem.{allowRead,allowWrite,denyRead}` (ordinary file access, not `network-outbound`), and `excludedCommands`. Adding the socket path to `filesystem.allowRead` does not open the socket connection.

This only bites under `command claude`. Under the wrapped `claude` path the native sandbox degrades to unsandboxed (nested `sandbox_apply` EPERM — see [claude-code-internal-sandbox-nested-seatbelt-conflict.md](claude-code-internal-sandbox-nested-seatbelt-conflict.md)) while safehouse, which has `--enable=1password`, provides the socket. So the native sandbox is genuinely active — and the socket genuinely blocked — only via `command claude`.

## Solution

Run the signing/remote commands outside the sandbox via `sandbox.excludedCommands` in `dot_claude/settings.json.tmpl`:

```json
"excludedCommands": [
  "docker *", "gcloud *", "gh *",
  "git commit *", "git push *",
  "open *", "osascript *", "terraform *"
]
```

`excludedCommands` matches the full command string as a glob (same word-boundary rules as Bash permission globs), so the two-word `git commit *` / `git push *` patterns match `git commit -m "…"` / `git push origin …` without excluding read-only git. Verify two-word matching on the target Claude Code version before relying on it; fall back to `git *` if a version regresses it.

### Trade-off (accepted, not hook-neutralized)

Excluding git from the sandbox means it runs repo-controlled hooks (`pre-commit`, `commit-msg`, `pre-push`) and honors code-executing config/transports (`GIT_SSH_COMMAND`, `ext::`, `!`-aliases) on the host, and `git push` can reach any remote, bypassing `network.allowedDomains`. This is a real isolation reduction.

The instinctive mitigation — disabling hooks (`--no-verify` / `core.hooksPath=/dev/null`) on the excluded invocations — is **rejected here** because this repo's own `prek`/`secretlint` pre-commit hooks are a relied-upon secret-detection control; disabling them to defend against untrusted-repo hooks would remove a trusted gate on every commit. The residual risk (untrusted-repo hooks run unsandboxed on an approved commit/push) is instead accepted, mitigated by: git writes are human-approved via `permissions.ask`, the agent operates in trusted repos, and the exclusion is narrow (commit/push only, not all `git *`).

### Companion change: git write approval

Independently, git write governance was tightened. `permissions.ask` (which fires even under `bypassPermissions` and takes precedence over `allow` — eval order is deny > ask > allow) gates `commit`, `push`, and history-altering commands (`rebase`, `reset`, `revert`, `cherry-pick`, `merge`, `filter-branch`). Routine writes (`add`, `checkout`, `fetch`, `pull`, `submodule`, `worktree`) stay in `allow` so unattended autonomous runs (ralph-loop, ce-work, LFG) don't deadlock on an unanswerable prompt. All three force-push forms stay in `deny`.

**2026-07-25 追記:** 上記の `ask` 一覧は 2026-07-09 時点のもので、現在は一部が `allow` へ移っている。リスク Tier モデル（`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`、`claude-code-ask-rule-cannot-be-relaxed-per-directory-2026-07-25.md`）に基づき、`commit` / `revert` / `merge` は `allow` へ移動した。`push` / `rebase` / `reset` / `cherry-pick` / `filter-branch` は `ask` のまま残っている。

これにより、上記「Trade-off」で述べた緩和策のうち **git writes are human-approved via `permissions.ask`** の部分は分割して読む必要がある:

- **`push` については維持されている。** `ask` に残っているため、サンドボックス外で走る SSH transport（`GIT_SSH_COMMAND`、`ext::`）と `network.allowedDomains` のバイパスは、依然として承認プロンプトが最後の砦になっている。
- **`commit` については失われた。** `excludedCommands` に含まれたまま `allow` へ移ったため、リポジトリ側の `pre-commit` / `commit-msg` フックがプロンプトなしでサンドボックス外で実行される。残る緩和策は「信頼できるリポジトリでのみ作業する」「除外範囲が commit/push に限定されている」の 2 点のみで、承認プロンプトによる裏付けはない。

なお `--force` / `--force-with-lease` / `-f` の `deny` は 3 件とも維持しているが、これらは前方一致ルールであり `git push origin main --force` のような後置フラグや `--delete` によるリモートブランチ削除は捕捉しない。`push` を `ask` に残しているのはまさにこのためである。

## Resolution (2026-07-30)

Claude Code v2.1.220 に `sandbox.network.allowUnixSockets`（macOS 限定。Linux は seccomp がパス単位で
フィルタできないため無視される）が追加された。これにより `excludedCommands` による回避策は不要になり、
`dot_claude/settings.json.tmpl` は以下の形に変わった:

```json
"network": {
  "allowUnixSockets": [
    "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
  ]
},
"excludedCommands": ["docker *", "gcloud *", "gh *", "git push *", "open *", "osascript *", "terraform *"]
```

`~` は展開される（`filesystem.*` と同じパス正規化を通る）。パスに空白を含むが Seatbelt 側でクォートされる。
生成される SBPL は `(allow system-socket (socket-domain AF_UNIX))` が 1 回、以下 2 行がエントリごとに出力される:

```
(allow network-bind    (local  unix-socket (subpath "<path>")))
(allow network-outbound (remote unix-socket (subpath "<path>")))
```

兄弟キーの `allowAllUnixSockets: true` を使うと `subpath` ではなく `path-regex #"^/"` になり全 Unix socket が
開くため、1 ソケットだけ通したい今回の用途では過剰。なお v2.1.205 に本キーが無かったことは本文書の
2026-07-09 時点の記録に基づく（ローカルに残るのは 2.1.217 以降のみで、今回の再検証対象外）。今回実測で
確認したのは「v2.1.220 に存在し、Seatbelt まで配線されている」ことである。

### 検証（対照実験）

1. **SBPL 単体** — 同等プロファイルを `sandbox-exec` に直接与えると `ssh-add -l` の成否が反転する
   （許可なし: `Error connecting to agent: Operation not permitted` / 許可あり: 鍵一覧が出る）。
2. **Claude Code 経由の E2E** — レンダリング後の `sandbox` ブロックのみを `claude -p --settings` に渡し、
   `allowUnixSockets` の有無だけを差分にした 2 回の実行で同じ反転を確認。キーが実際に Seatbelt まで
   配線されていること、およびサンドボックスが黙って無効化されていないことの両方をこの対照ペアが示す。
3. **署名 commit** — 許可前のサンドボックス内では
   `error: 1Password: Could not connect to socket` → `fatal: failed to write commit object` で失敗する。
   一方 `commit.gpgsign=false` の commit はサンドボックス内で成功し、worktree の共通 git dir
   (`~/.local/share/chezmoi/.git`) への書き込みも許可されている（Claude Code が自動で write 許可に加える）。
   つまり `git commit` の唯一のブロッカーはソケットであり、それが解けた以上サンドボックス内実行で足りる。

### `git push` を除外したままにする理由

ソケットとは無関係。remote が `git@github.com:tanimon/dotfiles.git` で、さらにグローバル設定の
`url.git@github.com:.insteadOf https://github.com/` により https URL も ssh に書き換わるため、push は
github.com:22 への**生 TCP** を必要とする。ネイティブサンドボックスのネットワーク経路は HTTP(S) プロキシ
（+ `allowLocalBinding`）だけなので、`allowedDomains` に github.com があっても ssh transport は通らない。
よって `git push *` は `excludedCommands` に残す。`push` は `permissions.ask` に残っているため、
サンドボックス外実行と `allowedDomains` バイパスは承認プロンプトが裏付けとして残る（上記 2026-07-25 追記のとおり）。

### 解消した残存リスク

上記 2026-07-25 追記の「**`commit` については失われた**」— `allow` かつ `excludedCommands` のため
リポジトリ管理の `pre-commit` / `commit-msg` フックが無プロンプトでサンドボックス外実行される — は解消した。
commit はサンドボックス内で走るため、フックも Seatbelt 境界の内側で実行される。代償として、cwd 外への
書き込みや `allowedDomains` 外への通信を行うフックは失敗しうる（この repo の prek/secretlint は
サンドボックス内で問題なく動作する）。

## Prevention

- サンドボックス内のツールが Unix domain socket（SSH agent、gpg-agent、Docker socket）に到達する必要が
  ある場合、まず `sandbox.network.allowUnixSockets` を使う。`filesystem.allowRead` にソケットパスを
  足しても `network-outbound` は開かない。`excludedCommands` はサンドボックス自体を外す最後の手段であり、
  隔離の縮小と引き換えなので、専用キーが使えるならそちらを選ぶ。
- サンドボックスのキーが「存在しない」と判断した回避策は、Claude Code のバージョンが上がったら再点検する。
  この件は v2.1.205 で「キーが無い」ため `excludedCommands` を選んだが、v2.1.220 で追加されていた。
  スキーマの実地確認は `strings <claude バイナリ> | grep -o '.\{400\}<キー名>.\{600\}'` で zod 定義と
  `describe()` を直接読むのが速い（バイナリ配布なので `--help` やドキュメントより確実）。
- サンドボックス設定の検証は必ず**対照ペア**で行う。「許可を入れたら通った」だけでは、サンドボックスが
  そもそも適用されていない（`failIfUnavailable: false` で fail open に degrade する）ケースと区別できない。
  該当キーだけを削った設定でも実行し、失敗することを確認する。これは
  [verification through the wrong resolution path](../workflow-issues/verification-through-the-wrong-resolution-path.md)
  が集約している「空虚に成功する検証」の一種で、同文書の実例リストに本件を追加してある。
- When a sandboxed tool must reach a Unix domain socket (SSH agents, gpg-agent, Docker socket) and the sandbox has no socket-allow key, `excludedCommands` is the lever — not `filesystem.allowRead`.
- Do not blanket-disable git hooks to shrink the excluded-git escape surface if the repo relies on pre-commit hooks as a security control; document and accept the residual risk instead.
- Re-audit `excludedCommands` glob matching after Claude Code upgrades (the native sandbox is research-preview).

## Related

- [claude-code-internal-sandbox-nested-seatbelt-conflict.md](claude-code-internal-sandbox-nested-seatbelt-conflict.md) — why the native sandbox is active only under `command claude`
- [1password-ssh-agent-libgit2-ssh-auth-sock.md](1password-ssh-agent-libgit2-ssh-auth-sock.md) — prior 1Password agent socket learning
- [verification-through-the-wrong-resolution-path.md](../workflow-issues/verification-through-the-wrong-resolution-path.md)
  — 2026-07-30 の検証で使った対照ペアの一般形。本件はその実例リストに追加済み
- `docs/plans/2026-07-09-001-fix-sandbox-1password-socket-and-git-approval-plan.md` — the plan behind this change
