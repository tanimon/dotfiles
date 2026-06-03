---
title: "sheldon/libgit2 SSH clone fails because libgit2 ignores ~/.ssh/config IdentityAgent"
date: 2026-06-03
category: docs/solutions/integration-issues
module: shell environment / sheldon
problem_type: integration_issue
component: tooling
symptoms:
  - "sheldon lock --update fails to clone every plugin with `remote rejected authentication: Failed getting response; class=Ssh (23); code=Auth (-16)`"
  - "plugins.toml uses HTTPS URLs (github = \"owner/repo\") yet the failure is an SSH authentication error"
  - "`ssh -T git@github.com` succeeds (\"Hi <user>!\") while sheldon/libgit2 fails on the same host"
root_cause: config_error
resolution_type: config_change
severity: medium
related_components:
  - authentication
  - development_workflow
tags:
  - sheldon
  - libgit2
  - ssh-auth-sock
  - 1password
  - identityagent
  - git-insteadof
  - ssh-agent
---

# sheldon/libgit2 SSH clone fails because libgit2 ignores ~/.ssh/config IdentityAgent

## Problem

`sheldon lock --update` failed to install every zsh plugin with an SSH authentication error, even though `plugins.toml` declares plugins via HTTPS (`github = "owner/repo"`). The OpenSSH CLI authenticated to GitHub fine, but sheldon (which uses libgit2) did not — because libgit2 and the OpenSSH CLI resolve the SSH agent through *different* mechanisms.

## Symptoms

- `sheldon --verbose lock --update` errors on each source:
  ```
  error: failed to install source `https://github.com/zsh-users/zsh-autosuggestions`
    due to: failed to git clone `https://github.com/zsh-users/zsh-autosuggestions`
    due to: remote rejected authentication: Failed getting response; class=Ssh (23); code=Auth (-16)
  ```
- The URLs in the error are all `https://github.com/...`, yet the failure class is `Ssh` / `Auth` — i.e. an SSH credential failure on what looks like an HTTPS clone.
- `ssh -T git@github.com` succeeds, proving the SSH key itself is valid and reachable *to the OpenSSH CLI*.
- `ssh-add -l` against the default `$SSH_AUTH_SOCK` reports `The agent has no identities`, while pointing `SSH_AUTH_SOCK` at the 1Password socket lists the GitHub keys.

## What Didn't Work

- **Assuming it was a real HTTPS problem.** The URLs are HTTPS, so the instinct is to look at HTTPS credential helpers or tokens. That is a dead end — the `class=Ssh` in the error is the tell that the request never went out over HTTPS at all.
- **Trusting `ssh -T git@github.com` as proof the environment is fine.** It succeeds because the OpenSSH CLI reads `~/.ssh/config`. libgit2 does not, so a passing CLI check says nothing about whether libgit2 can authenticate.

## Solution

Three settings interact to produce the failure:

1. **gitconfig rewrites HTTPS to SSH.** `dot_gitconfig.tmpl` contains:
   ```ini
   [url "git@github.com:"]
     insteadOf = https://github.com/
   ```
   libgit2 reads git config and applies `insteadOf`, so `https://github.com/owner/repo` becomes `git@github.com:owner/repo` — an SSH clone. This is why an HTTPS-looking URL fails with an SSH error.

2. **libgit2 ignores `~/.ssh/config`'s `IdentityAgent`.** The OpenSSH CLI honors `IdentityAgent` (here pointed at the 1Password agent socket), but libgit2's SSH transport does not parse `ssh_config` that way — it reads the `SSH_AUTH_SOCK` environment variable directly.

3. **`SSH_AUTH_SOCK` pointed at the wrong agent.** It defaulted to the macOS launchd agent (`/var/run/com.apple.launchd.*/Listeners`), which holds no identities. The GitHub keys live only in the 1Password agent.

Fix — export `SSH_AUTH_SOCK` to the 1Password agent socket in `dot_zprofile` so libgit2-based tools use the same agent (and keys) the OpenSSH CLI already uses:

```sh
# Route SSH agent requests to the 1Password agent.
# OpenSSH CLI already uses it via ~/.ssh/config IdentityAgent, but tools built
# on libgit2 (e.g. sheldon) ignore IdentityAgent and read SSH_AUTH_SOCK directly.
# Without this they hit the empty macOS launchd agent and fail with
# `class=Ssh (23); code=Auth (-16)` when insteadOf rewrites HTTPS to SSH.
export SSH_AUTH_SOCK="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

(`2BUA8C4S2C` is 1Password/AgileBits' fixed public Apple Developer Team ID — identical on every install, not user-specific or a secret.)

## Why This Works

The OpenSSH CLI and libgit2 are two independent SSH clients. OpenSSH resolves the agent via `~/.ssh/config` (`IdentityAgent`); libgit2 resolves it via `SSH_AUTH_SOCK`. In a 1Password SSH agent setup, only the OpenSSH path was wired up, so anything that went through libgit2 silently fell back to the empty launchd agent and failed authentication. Exporting `SSH_AUTH_SOCK` aligns the libgit2 path with the OpenSSH path — both now reach the 1Password agent that holds the keys.

Verification was empirical: re-running `sheldon lock --update` with the corrected `SSH_AUTH_SOCK` changed the error class from `class=Ssh (23); code=Auth (-16)` to gone. (A residual `class=Os (2) Operation not permitted` appeared only because the command ran inside the Claude Code Seatbelt sandbox, which blocks the plugin-repo write — it does not occur in a normal shell.)

## Prevention

- **In any 1Password (or non-default) SSH agent setup, set `SSH_AUTH_SOCK` explicitly — do not rely on `IdentityAgent` alone.** `IdentityAgent` only covers the OpenSSH CLI. Tools built on libgit2 (sheldon, some Git GUIs, language Git bindings) and anything else reading `SSH_AUTH_SOCK` directly need the env var. The CLI working is not evidence the agent is reachable to every client.
- **Read the error *class*, not just the URL.** `class=Ssh` on an HTTPS URL means a `url.*.insteadOf` rewrite is in play — trace gitconfig before chasing HTTPS credential helpers.
- **Quick diagnostic:** `SSH_AUTH_SOCK=<1password-socket> ssh-add -l` should list the expected keys; if the default `ssh-add -l` says "agent has no identities" but the 1Password socket lists them, the env var is the gap.
- **Secondary discovery — chezmoi source/target drift:** the deployed `~/.zprofile` had an OrbStack init line added directly by OrbStack's installer that was missing from the chezmoi source. Because `dot_zprofile` is a fully-owned (non-`modify_`) file, `chezmoi apply` would have clobbered it. Always run `chezmoi diff` before applying after editing a fully-owned file, and fold externally-injected lines back into the source. See the CLAUDE.md pitfall "Never edit deployed targets directly."

## Related Issues

- [migrate-cco-to-agent-safehouse.md](./migrate-cco-to-agent-safehouse.md) — safehouse's `--enable=ssh` / `--enable=1password` grants the *sandbox process boundary* access to the 1Password agent socket. That is a separate, non-redundant layer from this `SSH_AUTH_SOCK` shell-env fix: safehouse covers what the sandbox can reach, `SSH_AUTH_SOCK` covers which agent libgit2 talks to.
- [../runtime-errors/cco-sandbox-hook-and-git-eperm.md](../runtime-errors/cco-sandbox-hook-and-git-eperm.md) — same 1Password agent socket path (`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`) in the sandbox-allowlist context.
- [claude-code-action-unsigned-commits-2026-04-05.md](./claude-code-action-unsigned-commits-2026-04-05.md) — a different layer of 1Password SSH signing failure (CI lacks `op-ssh-sign`). When signing/auth is the symptom, distinguish the layer: missing CI signing config, wrong local `SSH_AUTH_SOCK`, or OpenSSH-vs-libgit2 agent routing.
