---
title: "1Password SSH signing fails under Claude Code native sandbox (Could not connect to socket)"
category: integration-issues
tags: [claude-code, sandbox, seatbelt, 1password, ssh-agent, op-ssh-sign, git-signing, permissions]
date: 2026-07-09
module: Claude Code native Bash sandbox (dot_claude/settings.json.tmpl)
symptom: "git commit fails with 'Could not connect to socket' when signing under `command claude`"
root_cause: "The native Seatbelt sandbox denies the network-outbound connection from op-ssh-sign to the 1Password SSH agent Unix socket; Claude Code v2.1.205 has no Unix-socket allow key, so the only lever is sandbox.excludedCommands"
---

# 1Password SSH signing fails under Claude Code native sandbox

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

## Prevention

- When a sandboxed tool must reach a Unix domain socket (SSH agents, gpg-agent, Docker socket) and the sandbox has no socket-allow key, `excludedCommands` is the lever — not `filesystem.allowRead`.
- Do not blanket-disable git hooks to shrink the excluded-git escape surface if the repo relies on pre-commit hooks as a security control; document and accept the residual risk instead.
- Re-audit `excludedCommands` glob matching after Claude Code upgrades (the native sandbox is research-preview).

## Related

- [claude-code-internal-sandbox-nested-seatbelt-conflict.md](claude-code-internal-sandbox-nested-seatbelt-conflict.md) — why the native sandbox is active only under `command claude`
- [1password-ssh-agent-libgit2-ssh-auth-sock.md](1password-ssh-agent-libgit2-ssh-auth-sock.md) — prior 1Password agent socket learning
- `docs/plans/2026-07-09-001-fix-sandbox-1password-socket-and-git-approval-plan.md` — the plan behind this change
