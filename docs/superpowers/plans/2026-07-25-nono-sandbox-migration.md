# nono Sandbox Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the three overlapping sandbox mechanisms (safehouse, cco, Claude Code's native Bash sandbox) with a single chezmoi-managed nono profile that enforces a domain allowlist at the kernel level, while keeping the native sandbox reachable via `command claude`.

**Architecture:** A plain-JSON nono profile at `dot_config/nono/profiles/claude-seal.json` extends the official `claude-code` pack profile. The `claude()` zsh wrapper invokes `nono run --profile claude-seal` and passes `--settings '{"sandbox":{"enabled":false}}'` so the native sandbox is off inside nono but still active under `command claude`. Package-install commands move from `permissions.allow` to `permissions.ask`. safehouse/cco are removed only after a manual observation phase grows the allowlist.

**Tech Stack:** chezmoi (Go templates, `run_onchange_` scripts), nono v0.68.0+ (Homebrew formula, macOS Seatbelt), zsh, Claude Code settings JSON, GNU Make, prek/secretlint pre-commit hooks.

**Design doc:** `docs/superpowers/specs/2026-07-25-nono-sandbox-migration-design.md`

## Global Constraints

- **Target OS is macOS.** Windows/WSL2 is out of scope (nono domain filtering does not work on WSL2's Landlock V3).
- **The nono profile must be strict JSON with no comments.** `make oxfmt` runs `pnpm exec oxfmt --check` over every `*.json` in the repo (`JSON_FILES` in `Makefile:16-19`), and nono parses profiles as strict JSON. Rationale that would otherwise be a comment goes into CLAUDE.md.
- **The nono profile must NOT be a chezmoi template.** nono expands `$HOME`, `$XDG_CONFIG_HOME`, `$WORKDIR`, `$TMPDIR`, `$NONO_CONFIG`, and `$NONO_PACKAGES` itself. Use those, never `{{ .chezmoi.homeDir }}`.
- **Profile name is `claude-seal`.** It must differ from `claude-code`, because a user profile shadows a pack profile of the same name and would silently discard the base.
- **All shell scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`** (`.claude/rules/shell-scripts.md`).
- **`run_onchange_` scripts guard for missing tools** with `command -v <tool> >/dev/null 2>&1 || { echo "WARNING: ..."; exit 0; }` and live in `.chezmoiscripts/`.
- **`.tmpl` files are excluded from shellcheck/shfmt** and cannot be linted; keep template logic minimal.
- **Never edit deployed targets under `~/`.** Always edit the chezmoi source under `~/.local/share/chezmoi/`.
- **`make lint` must pass before every commit.** prek runs secretlint + scan-sensitive on commit.
- **Commits use conventional-commit format** and end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **`git commit` and `git push` are `permissions.ask`-gated** — expect an approval prompt on every commit step.

---

### Task 1: Install nono and sync the pack declaratively

Adds nono to the Brewfile and a declarative pack-sync script mirroring the existing marketplace-sync pattern. safehouse stays installed and `claude()` is untouched, so nothing about daily work changes yet.

**Files:**
- Modify: `darwin/Brewfile:3` (replace `tap "eugene1g/safehouse"` with nothing; add `brew "nono"` in the alphabetical brew block)
- Create: `dot_config/nono/packs.txt`
- Create: `.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl`
- Modify: `.chezmoiignore` (add two entries)

**Interfaces:**
- Consumes: nothing.
- Produces: the `nono` binary on `PATH`; the pack `nolabs-ai/claude` installed at `~/.config/nono/packages/nolabs-ai/claude/`, providing the `claude-code` base profile that Task 2's profile extends; the plugin key written into `~/.claude/plugins/installed_plugins.json` that Task 3 reads.

- [ ] **Step 1: Confirm the current state fails**

Run:
```bash
command -v nono; echo "exit=$?"
```
Expected: no output, `exit=1` — nono is not installed.

- [ ] **Step 2: Add nono to the Brewfile and drop the safehouse tap**

In `darwin/Brewfile`, delete line 3 (`tap "eugene1g/safehouse"`) and add `brew "nono"` to the `brew` block. The block is alphabetical after the first two entries, so place it between `brew "nkf"` and `brew "osv-scanner"`:

```ruby
brew "nkf"
brew "nono"
brew "osv-scanner"
```

Note: nono is in `homebrew/core`, so no `tap` line is needed. The safehouse tap is removed now rather than at cutover because it was already orphaned — there is no `brew "safehouse"` line, so the tap grants nothing.

- [ ] **Step 3: Create the declarative pack list**

Create `dot_config/nono/packs.txt`:

```text
# nono registry packs to install (one per line: <namespace>/<pack>)
# Lines starting with # are comments.
#
# Removal requires `nono remove <namespace>/<pack>` on each machine —
# deleting a line here does NOT uninstall the pack.
nolabs-ai/claude
```

- [ ] **Step 4: Create the pack sync script**

Create `.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl`:

```bash
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# packs.txt hash: {{ include "dot_config/nono/packs.txt" | sha256sum }}

if ! command -v nono >/dev/null 2>&1; then
  echo "WARNING: nono not found, skipping pack install"
  exit 0
fi

# nono treats a non-TTY context as NONO_NO_MIGRATE=1 and exits without
# pulling. Set NONO_AUTO_MIGRATE=1 so the pull runs unattended.
export NONO_AUTO_MIGRATE=1

while IFS= read -r pack || [ -n "$pack" ]; do
  [[ -z "$pack" || "$pack" == \#* ]] && continue
  echo "Ensuring nono pack: ${pack}"
  nono pull "$pack" || echo "WARNING: nono pull ${pack} failed"
done < "{{ .chezmoi.sourceDir }}/dot_config/nono/packs.txt"
{{ end -}}
```

- [ ] **Step 5: Add `.chezmoiignore` entries**

`packs.txt` is read from the source tree via `include`, so it must not deploy. `~/.config/nono/packages/` is nono's own pack store and must not be managed. A bare `*.txt` entry only matches root level, so `packs.txt` needs an explicit line (same reason `.config/gh/extensions.txt` has one).

Add next to the existing `.config/gh/extensions.txt` line:

```text
.config/gh/extensions.txt
.config/nono/packs.txt

# ~/.config/nono/packages/ is nono's own pack store (pulled by
# run_onchange_after_pull-nono-packs.sh.tmpl, not managed by chezmoi)
.config/nono/packages
```

Do **not** ignore `.config/nono/profiles` — Task 2's profile must deploy.

- [ ] **Step 6: Verify the template renders and the ignore rules are right**

Run:
```bash
make check-templates
chezmoi managed | grep -E '^\.config/nono'
```
Expected: `check-templates` prints `PASS: all templates valid`. The `chezmoi managed` output shows **no** `.config/nono/packs.txt` and **no** `.config/nono/packages` line. (`profiles/claude-seal.json` does not exist yet, so expect empty output from the grep at this point — that is correct.)

- [ ] **Step 7: Install nono and pull the pack**

Run:
```bash
brew install nono
nono --version
chezmoi apply --dry-run
chezmoi apply
```
Expected: `nono --version` reports 0.68.0 or newer. `chezmoi apply` runs the pack script and prints `Ensuring nono pack: nolabs-ai/claude`.

- [ ] **Step 8: Record the pack's plugin key for Task 3**

Run:
```bash
jq -r 'paths(scalars) as $p | select($p[-1]|tostring|test("nono";"i")) | "\($p|join(".")) = \(getpath($p))"' ~/.claude/plugins/installed_plugins.json
ls ~/.config/nono/packages/nolabs-ai/claude/
nono profile show claude-code | head -40
```
Expected: an entry whose key contains `nono` (e.g. `nono@nolabs-ai` or `nono@always-further`). **Write the exact key down** — Task 3 needs it verbatim. The README's namespace migration and the client docs disagree, so the installed file is the only authority.

Note: `nono profile show claude-code` also confirms the base profile resolved, which Task 2 depends on.

- [ ] **Step 9: Verify lint passes and commit**

Run:
```bash
make lint
```
Expected: all targets pass.

```bash
git add darwin/Brewfile dot_config/nono/packs.txt \
  .chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl .chezmoiignore
git commit -m "$(cat <<'EOF'
feat(nono): nono 導入と pack の宣言的同期

Brewfile に brew "nono" を追加（homebrew-core なので tap 不要）。
orphan だった tap "eugene1g/safehouse" は削除 — brew "safehouse" の
行が無かったため、新規マシンには tap だけ入って本体は入らず黙って
cco fallback に落ちる状態だった。

packs.txt + run_onchange_ による pack 同期は marketplaces.txt と
同じパターン。非 TTY では nono が NONO_NO_MIGRATE=1 相当で何もせず
抜けるので NONO_AUTO_MIGRATE=1 を明示する。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add the nono profile and its validation target

Creates the profile and wires `nono profile validate` into `make lint`, so a malformed profile is caught by the same command CI and prek already run. A broken profile means `claude` will not start, so this validation earns its place.

**Files:**
- Create: `dot_config/nono/profiles/claude-seal.json`
- Modify: `Makefile:1` (`.PHONY`), `Makefile:25` (`lint` prerequisites), and append a `test-nono-profile` target

**Interfaces:**
- Consumes: the `claude-code` base profile installed by Task 1.
- Produces: the profile name `claude-seal`, used by Task 6's `claude()` wrapper as `nono run --profile claude-seal`; the environment variable `INSIDE_NONO_SANDBOX=1`, which Task 6's `codex()` wrapper tests for; the `make test-nono-profile` target.

- [ ] **Step 1: Write the failing validation**

Create the target first so it can be seen to fail. Append to `Makefile`:

```makefile
## Validate the nono sandbox profile (local only — CI does not install nono)
test-nono-profile:
	@if command -v nono >/dev/null 2>&1; then \
		echo "Validating nono profile..."; \
		nono profile validate dot_config/nono/profiles/claude-seal.json \
			|| { echo "FAIL: claude-seal.json is not a valid nono profile"; exit 1; }; \
		echo "PASS: nono profile valid"; \
	else \
		echo "WARNING: nono not found, skipping nono profile validation"; \
	fi
```

Add `test-nono-profile` to the `.PHONY` list on `Makefile:1` and to the `lint` prerequisites on `Makefile:25` (append after `test-harness-scripts`).

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
make test-nono-profile
```
Expected: FAIL — the profile file does not exist yet, so `nono profile validate` errors and the target prints `FAIL: claude-seal.json is not a valid nono profile`.

- [ ] **Step 3: Write the profile**

Create `dot_config/nono/profiles/claude-seal.json`. **Strict JSON, no comments** (see Global Constraints).

```json
{
  "meta": {
    "name": "claude-seal",
    "version": "1.0.0",
    "description": "Claude Code sandbox for this dotfiles setup"
  },
  "extends": "claude-code",
  "workdir": { "access": "readwrite" },
  "groups": {
    "include": [
      "git_config",
      "mise_manager",
      "homebrew_macos",
      "node_runtime",
      "bun_runtime",
      "go_runtime",
      "go_runtime_macos",
      "rust_runtime",
      "python_runtime",
      "user_tools",
      "user_caches_macos",
      "codex_macos"
    ]
  },
  "filesystem": {
    "allow": [
      "$HOME/ghq",
      "$HOME/.cache",
      "$HOME/.codex",
      "$HOME/.gstack"
    ],
    "read": [
      "$HOME/.local/bin",
      "$HOME/.local/share/cco",
      "$HOME/.bun",
      "$HOME/.pnpm-state",
      "$HOME/.agents",
      "$HOME/Library/Caches/ms-playwright",
      "$XDG_CONFIG_HOME/chezmoi",
      "$HOME/.local/share/chezmoi",
      "$XDG_CONFIG_HOME/ghostty",
      "$XDG_CONFIG_HOME/helix",
      "$XDG_CONFIG_HOME/karabiner",
      "$XDG_CONFIG_HOME/opencode",
      "$XDG_CONFIG_HOME/sheldon",
      "$XDG_CONFIG_HOME/yazi",
      "$XDG_CONFIG_HOME/zed",
      "$XDG_CONFIG_HOME/zellij",
      "$XDG_CONFIG_HOME/zsh",
      "$XDG_CONFIG_HOME/nono"
    ],
    "read_file": [
      "$XDG_CONFIG_HOME/starship.toml",
      "$HOME/.bashrc",
      "$HOME/.bash_profile",
      "$HOME/.vimrc",
      "$HOME/.tmux.conf",
      "$HOME/.cVimrc",
      "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    ],
    "bypass_protection": [
      "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    ]
  },
  "network": {
    "network_profile": "developer",
    "allow_domain": [
      "formulae.brew.sh",
      "proxy.golang.org",
      "sum.golang.org",
      "mcp.deepwiki.com",
      "chatgpt.com",
      "auth.openai.com",
      "mise.jdx.dev",
      "registry.nono.sh",
      "cdn.playwright.dev",
      "storage.googleapis.com",
      "code.claude.com",
      "docs.anthropic.com"
    ],
    "open_port": [0]
  },
  "environment": {
    "set_vars": { "INSIDE_NONO_SANDBOX": "1" }
  }
}
```

Notes on specific entries, so a reviewer can check intent:
- `read_file` (not `read`) is used for the 1Password agent socket and for single-file dotfiles; `read` is for directories.
- `bypass_protection` lifts the `deny_credentials` group's block on the 1Password container. It grants nothing on its own, which is why the socket also appears in `read_file`.
- `$HOME/.local/share/cco` is listed for read because cco is still present at this point; Task 6 removes it.
- `open_port: [0]` is macOS-only shorthand for `localhost:*` outbound, matching the current native sandbox's `allowLocalBinding: true`.
- `$XDG_CONFIG_HOME` expands to `$HOME/.config` on macOS.

- [ ] **Step 4: Run the validation to verify it passes**

Run:
```bash
make test-nono-profile
```
Expected: `PASS: nono profile valid`.

- [ ] **Step 5: Verify the target actually catches breakage**

A validation target that always passes is worse than none. Prove it fails on bad input:

```bash
cp dot_config/nono/profiles/claude-seal.json /tmp/claude-seal.bak
jq '.filesystem.nonexistent_key = ["x"]' /tmp/claude-seal.bak > dot_config/nono/profiles/claude-seal.json
make test-nono-profile; echo "exit=$?"
cp /tmp/claude-seal.bak dot_config/nono/profiles/claude-seal.json
make test-nono-profile
```
Expected: the middle run FAILs with a non-zero exit (nono rejects unknown keys); the last run PASSes again.

If nono *accepts* the unknown key, note it in the commit message — the target still catches JSON syntax errors and unresolvable `extends`, which is the main risk.

- [ ] **Step 6: Verify the profile deploys and lint passes**

Run:
```bash
chezmoi apply --dry-run | grep -i nono
chezmoi managed | grep '^\.config/nono'
make lint
```
Expected: `chezmoi managed` lists `.config/nono/profiles/claude-seal.json` and nothing else under `.config/nono`. `make lint` passes, including the new `test-nono-profile` and `oxfmt` (which now formats the new JSON file — if `oxfmt --check` fails, run `pnpm exec oxfmt dot_config/nono/profiles/claude-seal.json` to fix formatting).

- [ ] **Step 7: Commit**

```bash
git add dot_config/nono/profiles/claude-seal.json Makefile
git commit -m "$(cat <<'EOF'
feat(nono): claude-seal プロファイルと validate ターゲット追加

safehouse config の grant を nono プロファイルに翻訳。素の JSON に
することで make oxfmt の構文検証と nono profile validate の意味検証が
両方効く（nono が $HOME/$XDG_CONFIG_HOME を自前展開するので chezmoi
テンプレートにする必要がない）。

1Password 署名ソケットは deny_credentials group がデフォルトで塞ぐ
ため bypass_protection と read_file の併記が必須。bypass_protection は
deny を外すだけで grant しない。

network は developer プロファイル + 取りこぼしドメインのシード。
この列挙は不完全な前提で、観測フェーズで育てる。

make test-nono-profile は nono 未インストール時 skip（CI は nono を
入れないのでローカル専用の検証）。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Reflect the pack's plugin key and nono diagnostics into settings

The pack writes its `enabledPlugins` key into `~/.claude/settings.json`, but chezmoi fully owns `settings.json.tmpl` — without reflecting the key, `chezmoi apply` wipes it and the plugin silently stops loading. This is the same failure shape as #228 and the marketplace-rename pitfall in CLAUDE.md.

**Files:**
- Modify: `dot_claude/settings.json.tmpl` — `permissions.allow` array (around line 20-73) and `enabledPlugins` object (around line 380)

**Interfaces:**
- Consumes: the exact plugin key recorded in Task 1 Step 8.
- Produces: the pack's diagnostic hooks stay active across `chezmoi apply`; `nono why` / `nono profile *` no longer prompt.

- [ ] **Step 1: Demonstrate the drift**

Run:
```bash
jq -r '.enabledPlugins // {} | keys[]' ~/.claude/settings.json | grep -i nono
chezmoi apply --dry-run 2>&1 | grep -c 'settings.json' || true
```
Expected: the first command prints the nono plugin key (the pack wrote it). The second shows chezmoi wants to rewrite `settings.json` — i.e. the key is about to be lost.

- [ ] **Step 2: Add nono's diagnostic commands to `permissions.allow`**

In the `permissions.allow` array in `dot_claude/settings.json.tmpl`, insert these four entries in the existing alphabetical position (after `Bash(mv:*)` and before `Bash(npm:*)`):

```json
      "Bash(nono profile guide)",
      "Bash(nono profile show:*)",
      "Bash(nono profile validate:*)",
      "Bash(nono why:*)",
```

These are read-only diagnostics. The pack's `PostToolUseFailure` hook instructs Claude to run `nono why` on every sandbox denial, so without this the prompt fires constantly.

- [ ] **Step 3: Add the plugin key to `enabledPlugins`**

Using the **exact key recorded in Task 1 Step 8** (do not guess between `nono@nolabs-ai` and `nono@always-further`), add it to the `enabledPlugins` object with a template comment explaining why it is there:

```json
  {{/* nono@<ns>: the nono pack (nolabs-ai/claude) writes this key into ~/.claude/settings.json at install time. chezmoi fully owns this template, so without reflecting it here `chezmoi apply` wipes the key and the pack's sandbox-diagnostic hooks silently stop firing — same failure shape as #228 and the marketplace-rename pitfall in CLAUDE.md. If the pack namespace changes upstream, this key must be updated in lockstep. */ -}}
  "enabledPlugins": {
    "nono@nolabs-ai": true,
```

Replace `nono@nolabs-ai` with the recorded key. Place it as the first entry so the comment sits directly above it.

- [ ] **Step 4: Verify the template renders and the key survives apply**

Run:
```bash
make check-templates
chezmoi apply
jq -r '.enabledPlugins | to_entries[] | select(.key|test("nono")) | "\(.key) = \(.value)"' ~/.claude/settings.json
jq -r '.permissions.allow[] | select(startswith("Bash(nono"))' ~/.claude/settings.json
```
Expected: `check-templates` passes. The nono plugin key is present and `true` **after** apply. All four `Bash(nono ...)` entries are present.

- [ ] **Step 5: Verify lint passes and commit**

Run:
```bash
make lint
```
Expected: all targets pass.

```bash
git add dot_claude/settings.json.tmpl
git commit -m "$(cat <<'EOF'
feat(claude): nono pack のプラグインキーと診断コマンドを settings に反映

nono pack は install 時に ~/.claude/settings.json の enabledPlugins に
自分のキーを書き込むが、chezmoi が settings.json.tmpl を全所有して
いるため apply で消えてプラグインが無言で止まる（#228 と同型）。
テンプレート側に明示反映する。

pack の PostToolUseFailure hook はサンドボックス拒否のたびに
nono why を実行するよう Claude に指示するため、読み取り専用の
診断コマンド4件を permissions.allow に追加してプロンプトを抑える。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Gate package and module installation behind human approval

`Bash(npm:*)`, `Bash(pnpm:*)`, `Bash(mise:*)`, and `Bash(go get:*)` are currently in `permissions.allow`, so installs are auto-approved. Moving install commands to `permissions.ask` puts a human in the loop before new code enters the machine — the supply-chain half of the threat the network allowlist addresses.

**Files:**
- Modify: `dot_claude/settings.json.tmpl` — `permissions.ask` array (around line 145-190)

**Interfaces:**
- Consumes: nothing.
- Produces: no interface other tasks depend on.

Precedence is `deny > ask > allow`, so the broad `allow` entries can stay and the narrower `ask` entries win. `ask` fires even under `bypassPermissions`, so the gate holds on the `--dangerously-skip-permissions` path Task 6's wrapper uses.

- [ ] **Step 1: Confirm installs are currently auto-approved**

Run:
```bash
jq -r '.permissions.allow[] | select(test("npm|pnpm|mise|go get"))' ~/.claude/settings.json
jq -r '.permissions.ask[] | select(test("install|add|dlx|npx"))' ~/.claude/settings.json; echo "ask matches: $?"
```
Expected: the first command lists `Bash(go get:*)`, `Bash(mise:*)`, `Bash(npm:*)`, `Bash(pnpm:*)`. The second prints nothing — no install command is gated today.

- [ ] **Step 2: Add the install gates to `permissions.ask`**

Insert into the `permissions.ask` array in `dot_claude/settings.json.tmpl`, keeping alphabetical order within the array. The existing array runs `Bash(gh ...)` then `Bash(git ...)`; these entries interleave accordingly.

```json
      "Bash(brew bundle:*)",
      "Bash(brew install:*)",
      "Bash(brew tap:*)",
      "Bash(bun add:*)",
      "Bash(bun install:*)",
      "Bash(bunx:*)",
      "Bash(cargo add:*)",
      "Bash(cargo install:*)",
      "Bash(claude plugin install:*)",
      "Bash(claude plugin marketplace add:*)",
      "Bash(gem install:*)",
      "Bash(gh extension install:*)",
      "Bash(go get:*)",
      "Bash(go install:*)",
      "Bash(mise install:*)",
      "Bash(mise plugin:*)",
      "Bash(mise use:*)",
      "Bash(nono pull:*)",
      "Bash(nono update:*)",
      "Bash(npm add:*)",
      "Bash(npm ci:*)",
      "Bash(npm i:*)",
      "Bash(npm install:*)",
      "Bash(npm update:*)",
      "Bash(npx:*)",
      "Bash(pip install:*)",
      "Bash(pip3 install:*)",
      "Bash(pnpm add:*)",
      "Bash(pnpm dlx:*)",
      "Bash(pnpm install:*)",
      "Bash(pnpm update:*)",
      "Bash(uv add:*)",
      "Bash(uv pip install:*)",
      "Bash(uvx:*)",
      "Bash(yarn add:*)",
      "Bash(yarn dlx:*)",
      "Bash(yarn install:*)",
```

Also add a template comment above the `permissions.ask` array's existing comment block, documenting the scope and — critically — the holes:

```json
    {{/* Package/module install gate: installing new code is a supply-chain event, so it goes through a human. Precedence is deny > ask > allow, so the broad Bash(npm:*)/Bash(pnpm:*)/Bash(mise:*) entries in allow stay and these narrower ask entries win. Two deliberate holes: (1) Claude Code permissions match the Bash string the agent issues, NOT its subprocesses — `make lint` (Bash(make:*), still in allow) invokes pnpm without prompting; acceptable because make targets are version-controlled and reviewable. (2) Lockfile restore (bare `pnpm install`, `npm ci`) is gated too, deliberately: splitting "new deps ask, restore allow" is an illusory boundary because an agent can edit package.json then run bare `pnpm install` straight through it. curl/wget are already in deny, which closes `curl … | sh`. */ -}}
```

- [ ] **Step 3: Verify the gates land and that `allow` is correctly overridden**

Run:
```bash
make check-templates
chezmoi apply
jq -r '.permissions.ask[] | select(test("install|add|dlx|npx|bunx|uvx|tap|pull|update"))' ~/.claude/settings.json | wc -l
jq -r '.permissions.allow[] | select(test("^Bash\\((npm|pnpm|mise|go get)"))' ~/.claude/settings.json
```
Expected: `check-templates` passes. The `ask` count is 37. The broad `allow` entries are still present — that is intentional, `ask` takes precedence.

- [ ] **Step 4: Verify the gate actually fires**

This is a behavioral check, not a config check. In a **new** Claude Code session (permissions are read at session start):

```bash
# In a scratch directory, ask the agent to run: pnpm add --save-dev left-pad
```
Expected: an approval prompt appears before the command runs. Decline it. Then confirm `make lint` still runs without a prompt (verifying hole 1 above is as described).

- [ ] **Step 5: Verify lint passes and commit**

Run:
```bash
make lint
```
Expected: all targets pass.

```bash
git add dot_claude/settings.json.tmpl
git commit -m "$(cat <<'EOF'
feat(claude): パッケージ/モジュールインストールを ask ゲート化

npm/pnpm/mise/go get は permissions.allow に入っており、インストールが
無条件で自動承認されていた。新しいコードの持ち込みはサプライチェーン
イベントなので人間を挟む。deny > ask > allow なので広い allow は
残したまま個別 ask が勝つ。ask は bypassPermissions 下でも発火する
ので --dangerously-skip-permissions 経路でもゲートが効く。

lockfile 復元（素の pnpm install / npm ci）も意図的にゲートする:
「新規依存だけ ask、復元は allow」の二層分割は、package.json を編集
してから素の install を打てば素通りするので実質的に穴。

穴として明記: permissions はエージェントが発行した Bash 文字列に
マッチし子プロセスを見ないため、make 経由の pnpm は止まらない
（make ターゲットはリポジトリ管理下でレビュー可能なので許容線）。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Observation phase — grow the allowlist against real work

The allowlist from Task 2 is assumed incomplete. This task exercises nono explicitly while `claude()` still routes through safehouse, so an incomplete allowlist never blocks daily work. It ends when every checklist row passes.

**Files:**
- Modify: `dot_config/nono/profiles/claude-seal.json` (iteratively)
- Create: `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md`

**Interfaces:**
- Consumes: the `claude-seal` profile from Task 2.
- Produces: a profile whose allowlist covers real work; answers to the four open questions Task 6 and Task 7 depend on (SSH-over-proxy, `--settings` precedence, codex MCP nesting, `/Applications` executability).

- [ ] **Step 1: Start an observation session**

Run, from a repository under `~/ghq`:
```bash
nono run --profile claude-seal -vv -- claude \
  --settings '{"sandbox":{"enabled":false}}' --dangerously-skip-permissions 2>&1 \
  | tee "$HOME/.cache/nono-observe-$(date +%Y%m%d-%H%M%S).log"
```

`-vv` prints `ALLOW CONNECT <host>` and `DENY CONNECT <host>:<port> reason=<r>` for every proxy decision. Filesystem denials are diagnosed inside the session with `nono why --path <p> --op read`.

- [ ] **Step 2: Work the checklist**

Run each row and record PASS/FAIL plus the denial text. Rows 1, 2, 6, and 12 answer questions later tasks depend on — do those first.

| # | Item | What to confirm |
|---|---|---|
| 1 | `git commit` with 1Password signing | **Highest risk.** `bypass_protection` + socket `read_file` work, and `/Applications/1Password.app/Contents/MacOS/op-ssh-sign` is executable (whether `system_read_macos` covers `/Applications` is unverified — if not, add it to `filesystem.read`) |
| 2 | `git push` / `git fetch` | Whether SSH transport works under the proxy. `allow_domain` is an HTTP(S) proxy allowlist, **not** raw TCP, so SSH may be blocked. Fallbacks: an HTTPS remote, or `network.open_port` |
| 12 | `--settings` precedence | The native sandbox is genuinely off inside nono. Check with `claude --debug` output or `/doctor` in-session |
| 6 | MCP: codex | ChatGPT backend reachable; **whether nested Seatbelt actually breaks the MCP stdio server** (it is exec'd directly and does not pass through the `codex()` zsh function) |
| 3 | `gh pr view`, `gh issue list` | Keychain auth readable |
| 4 | `make lint` | secretlint / oxlint / actionlint / zizmor plus pnpm dependency resolution |
| 5 | `chezmoi diff`, `chezmoi apply --dry-run` | Coverage of `$HOME`-root dotfiles and `.config/*` read grants |
| 7 | MCP: deepwiki | `mcp.deepwiki.com` reachable |
| 8 | gstack `/browse` | Chromium launches; `open_port: [0]` sufficient; measure which sites 403 |
| 9 | WebFetch / WebSearch | How far each is constrained (WebSearch is expected to work, routing via `api.anthropic.com`) |
| 10 | Claude Code hooks | `harness-briefing.sh`, `notify-wrapper.sh`, the secretlint `PostToolUse` hook, and the `node --experimental-strip-types` statusline |
| 11 | Plugin loading | Marketplace updates (covered by the `github` group) and the pack plugin active |

- [ ] **Step 3: Extract denials and grow the profile**

Run:
```bash
grep -hoE 'DENY CONNECT [^ ]+' "$HOME"/.cache/nono-observe-*.log | sort -u
```

For each denied host, decide whether it is a destination you trust with your data. If yes, add it to `network.allow_domain`; if no, leave it blocked and record the decision. For filesystem denials, add the narrowest grant that works (`read_file` for a single file, `read` for a directory, `allow` only when writes are genuinely needed).

After each edit:
```bash
make test-nono-profile
```
Expected: PASS. Repeat Steps 1-3 until the checklist is clean.

- [ ] **Step 4: Record the observations**

Create `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md` in English (per `~/.claude/rules/common/documentation-language.md`) containing:
- The final answers to rows 1, 2, 6, and 12, with the exact error text where something failed.
- Every host added to the allowlist and why.
- Every host left blocked and the consequence (e.g. Sentry's `*.ingest.sentry.io` — no allow-side wildcard exists, so either the real org hostname is enumerated or the plugin's telemetry stays blocked).
- Whether `nono profile validate` rejects unknown keys (from Task 2 Step 5).

- [ ] **Step 5: Verify lint passes and commit**

Run:
```bash
make lint
make scan-sensitive
```
Expected: both pass. `scan-sensitive` matters here — observation logs can contain hostnames and paths that must not be pasted verbatim into the doc.

```bash
git add dot_config/nono/profiles/claude-seal.json \
  docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md
git commit -m "$(cat <<'EOF'
feat(nono): 観測フェーズでプロファイルを実作業に合わせて調整

nono run -vv のプロキシ判定ログから DENY を拾い、allow_domain と
filesystem grant を実作業（git 署名/push、gh、make lint、chezmoi
diff、MCP、gstack browse、hooks、プラグイン読み込み）が通るまで育てた。

判断の記録と、塞いだままにしたホストの影響を
docs/solutions/integration-issues/ に残す。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Cut over and remove safehouse/cco

Switches `claude()` to nono, fixes `codex()`'s nested-sandbox detection, and removes safehouse/cco. This is the point of no return, so it comes only after Task 5's checklist is clean.

**Files:**
- Modify: `dot_config/zsh/sandbox.zsh` (rewrite `claude()`, `_claude_safehouse()`, `_claude_cco()`, `codex()`)
- Modify: `dot_config/nono/profiles/claude-seal.json` (drop the cco read grant)
- Delete: `dot_config/safehouse/config.tmpl`, `dot_config/cco/allow-paths.tmpl`, `.chezmoiscripts/run_onchange_after_link-cco.sh.tmpl`
- Modify: `.chezmoiexternal.toml:8-13` (remove the `.local/share/cco` block)
- Modify: `dot_claude/mcp-servers.json` (**only if** Task 5 row 6 showed the MCP codex server breaks)

**Interfaces:**
- Consumes: `claude-seal` profile name and `INSIDE_NONO_SANDBOX` from Task 2; Task 5's answers to rows 6 and 12.
- Produces: `claude` runs under nono; `command claude` / `\claude` runs under the native Bash sandbox.

- [ ] **Step 1: Rewrite the wrappers**

Replace the whole of `dot_config/zsh/sandbox.zsh` with:

```zsh
# Sandbox Claude Code via nono (kernel-enforced Seatbelt/Landlock, deny-all default).
# Policy lives in ~/.config/nono/profiles/claude-seal.json (chezmoi-managed).
#
# --settings disables Claude Code's own Bash sandbox for this invocation only, so
# nono is the single boundary (nested Seatbelt EPERMs and is hard to diagnose).
# Use `command claude` or `\claude` to bypass nono — that path keeps Claude Code's
# native Bash sandbox active, per the sandbox block in ~/.claude/settings.json.
claude() {
  if command -v nono &>/dev/null; then
    command nono run --profile claude-seal -- \
      claude --settings '{"sandbox":{"enabled":false}}' \
      --dangerously-skip-permissions "$@"
  else
    command claude "$@"
  fi
}

# Disable codex's own Seatbelt sandbox when already inside nono. macOS denies
# nested sandbox_apply, so codex would EPERM. --sandbox danger-full-access drops
# only the nested sandbox; --ask-for-approval on-request keeps codex's approval
# flow (nono's documented recommendation — strictly safer than
# --dangerously-bypass-approvals-and-sandbox, which discards both).
# INSIDE_NONO_SANDBOX is injected by the claude-seal profile's environment.set_vars.
# Use `command codex` to bypass this wrapper.
codex() {
  if [[ -n "${INSIDE_NONO_SANDBOX:-}" ]]; then
    command codex --sandbox danger-full-access --ask-for-approval on-request "$@"
  else
    command codex "$@"
  fi
}
```

The `_claude_safehouse` and `_claude_cco` helpers are gone: nono expands `$HOME` itself and tolerates paths that do not exist, so the line-by-line config parsing and existence filtering those functions performed is no longer needed.

- [ ] **Step 2: Drop the cco grant from the profile**

Remove `"$HOME/.local/share/cco",` from `filesystem.read` in `dot_config/nono/profiles/claude-seal.json`. Also remove `"$XDG_CONFIG_HOME/cco"` and `"$XDG_CONFIG_HOME/safehouse"` if Task 5 added them.

- [ ] **Step 3: Delete safehouse/cco**

Run:
```bash
git rm dot_config/safehouse/config.tmpl \
  dot_config/cco/allow-paths.tmpl \
  .chezmoiscripts/run_onchange_after_link-cco.sh.tmpl
```

Then remove the cco block from `.chezmoiexternal.toml` (lines 8-13), leaving only the gstack entry. Preserve the `url` / `# renovate: branch=...` adjacency of the remaining entry — the regex custom manager in `renovate.json` requires those two lines adjacent with only whitespace between (`.claude/rules/renovate-external.md`).

Finally, remove the safehouse/cco read entries from `dot_config/nono/profiles/claude-seal.json` if any remain, and clean up the now-empty source directories:
```bash
rmdir dot_config/safehouse dot_config/cco 2>/dev/null || true
```

- [ ] **Step 4: Handle the codex MCP server if Task 5 showed it breaks**

Only if Task 5 row 6 recorded a nesting failure. The MCP stdio server is exec'd directly and never passes through the `codex()` zsh function.

First try the flag — confirm `mcp-server` accepts it:
```bash
command codex mcp-server --help 2>&1 | grep -E 'sandbox|approval'
```

If `--sandbox` is accepted, edit `dot_claude/mcp-servers.json`:

```json
{
  "codex": {
    "type": "stdio",
    "command": "codex",
    "args": ["--sandbox", "danger-full-access", "-m", "gpt-5.2-codex", "mcp-server"]
  },
  "deepwiki": {
    "type": "http",
    "url": "https://mcp.deepwiki.com/mcp"
  }
}
```

If `mcp-server` rejects the flag, create `dot_claude/scripts/executable_codex-mcp.sh` instead:

```bash
#!/usr/bin/env bash
# Launch the codex MCP server, disabling codex's own Seatbelt sandbox when
# already inside nono (macOS denies nested sandbox_apply). MCP stdio servers are
# exec'd directly and do not pass through the codex() zsh wrapper.
set -euo pipefail

args=()
if [[ -n "${INSIDE_NONO_SANDBOX:-}" ]]; then
    args+=(--sandbox danger-full-access)
fi

exec codex "${args[@]}" -m gpt-5.2-codex mcp-server
```

and point `command` at `{{ .chezmoi.homeDir }}/.claude/scripts/codex-mcp.sh` — which requires renaming `dot_claude/mcp-servers.json` to `dot_claude/mcp-servers.json.tmpl` and updating the `modify_dot_claude.json` reference to it. Note that `executable_codex-mcp.sh` is a non-`.tmpl` shell file, so it must pass `make shellcheck` and `make shfmt` (indent 4).

If Task 5 showed no failure, skip this step entirely.

- [ ] **Step 5: Apply and verify the cutover**

Run:
```bash
make lint
chezmoi apply --dry-run
chezmoi apply
exec zsh -l
```

Then in the fresh shell:
```bash
type claude | head -3
claude --version
```
Expected: `claude` is a shell function referencing `nono run`. `claude --version` succeeds — it now runs inside nono.

Verify the escape hatch still works:
```bash
command claude --version
```
Expected: succeeds, running under the native Bash sandbox.

Verify the removals:
```bash
test -e ~/.config/safehouse/config && echo "STALE: safehouse config still deployed"
test -e ~/.config/cco/allow-paths && echo "STALE: cco allow-paths still deployed"
```
Expected: no output. If either prints, add the path to `.chezmoiremove` (the repo already tracks that file) so it is cleaned on the next apply.

Then run a full smoke test in a nono-backed session: `git commit` (signing), `make lint`, and one MCP call each to codex and deepwiki.

- [ ] **Step 6: Uninstall safehouse and commit**

Run:
```bash
brew uninstall safehouse 2>/dev/null || true
brew untap eugene1g/safehouse 2>/dev/null || true
rm -f ~/bin/cco
```

```bash
git add -A dot_config/zsh/sandbox.zsh dot_config/nono/profiles/claude-seal.json \
  .chezmoiexternal.toml dot_config/safehouse dot_config/cco \
  .chezmoiscripts/run_onchange_after_link-cco.sh.tmpl
git commit -m "$(cat <<'EOF'
feat(sandbox): safehouse/cco から nono へカットオーバー

claude() を nono run --profile claude-seal に切替。--settings で
Claude Code 内蔵サンドボックスをこの起動に限り無効化し、境界を nono
1枚に集約する（入れ子 Seatbelt は EPERM になり診断が困難）。
command claude / \claude は引き続き内蔵サンドボックスで走る逃げ道。

nono は $HOME を自前展開し存在しないパスも許容するので、safehouse
ラッパーがやっていた config の行単位パースと存在チェックが不要になり
_claude_safehouse / _claude_cco ヘルパーごと消える。

codex() の入れ子検出を $APP_SANDBOX_CONTAINER_ID（safehouse の
副産物）から $INSIDE_NONO_SANDBOX（プロファイルが注入）に変更。
フラグも --dangerously-bypass-approvals-and-sandbox から
--sandbox danger-full-access --ask-for-approval on-request へ —
入れ子サンドボックスだけ落として承認フローは残す（公式推奨）。

cco の external エントリ削除で Renovate 追跡対象が1件減る。

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Rewrite the documentation and open follow-up issues

CLAUDE.md currently documents safehouse/cco as primary and the native sandbox as a "migration target". Both framings are now wrong. The native-sandbox paragraph's content stays valid — it just describes the escape-hatch path now.

**Files:**
- Modify: `CLAUDE.md` — the "Claude Code sandbox" and "Native Bash sandbox (migration target)" paragraphs in the Key Patterns section, and the Known Pitfalls section
- Modify: `README.md` if it mentions safehouse or cco (check first)

**Interfaces:**
- Consumes: Task 5's recorded observations.
- Produces: documentation consistent with the shipped configuration.

- [ ] **Step 1: Find every stale reference**

Run:
```bash
grep -rn --include='*.md' -iE 'safehouse|\bcco\b' . | grep -v node_modules | grep -v '^./docs/solutions/'
```
Expected: hits in `CLAUDE.md` and possibly `README.md`. Leave `docs/solutions/` alone — those are historical records of past problems and must stay accurate to their moment.

- [ ] **Step 2: Replace the sandbox paragraph in CLAUDE.md**

Replace the existing `**Claude Code sandbox**` paragraph with:

```markdown
**Claude Code sandbox (nono)** — The `claude` shell command is wrapped by `dot_config/zsh/sandbox.zsh` to run inside [nono](https://github.com/nolabs-ai/nono) (Homebrew formula, macOS Seatbelt / Linux Landlock, deny-all default). Policy lives in one file: `dot_config/nono/profiles/claude-seal.json`, which `extends` the `claude-code` base profile from the official pack `nolabs-ai/claude`. The pack is synced declaratively via `dot_config/nono/packs.txt` + `.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl` (same pattern as marketplace and gh-extension sync; removal requires `nono remove` on each machine). The profile is **plain JSON, not a template** — nono expands `$HOME` / `$XDG_CONFIG_HOME` itself — so `make oxfmt` checks its syntax and `make test-nono-profile` checks it semantically. Use `command claude` or `\claude` to bypass nono; that path runs under Claude Code's native Bash sandbox instead (see below).

The reason to run nono rather than the native sandbox alone is **egress control**: with `network.network_profile` / `allow_domain` active, the sandboxed child can reach only `localhost:<proxy-port>` and all other outbound TCP is blocked at the kernel level. The proxy resolves DNS itself and checks resolved IPs against a deny list (DNS-rebinding protection); cloud metadata endpoints are denied unconditionally. The native sandbox's `allowedDomains` only *prompts* for unlisted domains, which is a click-through, not a boundary.

**Growing the allowlist** — the allowlist is an explicit enumeration and there is **no host wildcard on the allow side** (only `deny_domain` accepts `*.host`). A miss fails with `403`; the pack's `PostToolUseFailure` hook tells Claude the denial is a nono boundary and to run `nono why`. Decide whether the destination is one you trust with your data, then add it to `network.allow_domain` and commit — the allowlist doubles as a reviewed history of granted destinations. Do not reach for L7 `endpoints` rules as an exfiltration control: they restrict method+path but a `GET` can carry payload in the query string.

**1Password commit signing** — nono's built-in `deny_credentials` group blocks the 1Password container by default. The profile lifts it with `filesystem.bypass_protection` on the agent socket and grants it via `filesystem.read_file`; `bypass_protection` removes a deny rule but grants nothing on its own, so both are required. nono attaches capabilities to the Unix socket directly, so only the socket is exposed. Because nono has no `excludedCommands` concept, `git`, `gh`, and `docker` all run **inside** the boundary on this path — repository hooks, SSH transports, and `push` are all covered, which they are not on the native-sandbox path.

See `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md` for what the allowlist was grown against and what was left blocked, and `docs/superpowers/specs/2026-07-25-nono-sandbox-migration-design.md` for the migration design.
```

- [ ] **Step 3: Retitle the native-sandbox paragraph as the escape hatch**

Change the heading `**Native Bash sandbox (migration target)**` to `**Native Bash sandbox (escape hatch)**` and prepend one sentence to the paragraph, keeping the rest of its content verbatim:

```markdown
**Native Bash sandbox (escape hatch)** — `dot_claude/settings.json.tmpl` keeps Claude Code's built-in Bash sandbox enabled (`sandbox.enabled: true`), but the nono wrapper passes `--settings '{"sandbox":{"enabled":false}}'` so it is off inside nono and nono is the single boundary. This block therefore governs the `command claude` / `\claude` path, which is the deliberate escape hatch for when a nono policy blocks something — you still get a sandbox rather than falling back to nothing. Everything below (the `allowWrite` temp-dir grants, `denyRead` credential blocks, and the `excludedCommands` list including the `git commit` / `git push` 1Password-socket workaround) is the correct configuration for *that* path and remains in force there.
```

Then delete from that paragraph only the two sentences about the nested-Seatbelt conflict under the wrapped `claude` path and about re-auditing `dot_config/safehouse/config.tmpl` once safehouse is retired — both are now obsolete. Keep everything else, including the `failIfUnavailable: false` note, which is still what makes the failure mode graceful.

- [ ] **Step 4: Document the package-install gate**

Append to the git/gh write-governance paragraph:

```markdown
**Package-install governance:** `permissions.ask` also gates commands that pull in new code (`npm`/`pnpm`/`yarn`/`bun` install-family, `pip`/`uv`, `go get`/`go install`, `cargo add`/`install`, `gem install`, `brew install`/`tap`/`bundle`, `mise install`/`use`/`plugin`, `gh extension install`, `claude plugin install`, `nono pull`/`update`) and commands that execute remote code without installing (`npx`, `pnpm dlx`, `yarn dlx`, `bunx`, `uvx`). `curl`/`wget` are in `deny`, which closes `curl … | sh`. Lockfile restore (bare `pnpm install`, `npm ci`) is gated **deliberately**: splitting "new deps ask, restore allow" is an illusory boundary, because an agent can edit `package.json` and then run bare `pnpm install` straight through it. Two accepted holes: Claude Code permissions match the Bash string the agent issues and **not its subprocesses**, so `make lint` (`Bash(make:*)`, still in `allow`) invokes `pnpm` without a prompt — acceptable because `make` targets are version-controlled and reviewable; and `gh api` remains unlisted for the reasons above.
```

- [ ] **Step 5: Add the Known Pitfalls entries**

Add to the "External Constraints & Tool Integration" subsection of Known Pitfalls:

```markdown
- **nono profiles must not be chezmoi templates** — nono expands `$HOME`, `$XDG_CONFIG_HOME`, `$WORKDIR`, `$TMPDIR`, `$NONO_CONFIG`, and `$NONO_PACKAGES` itself. Writing `{{ .chezmoi.homeDir }}` works but forfeits `make oxfmt` JSON validation and `nono profile validate`. Keep profiles as plain JSON with **no comments** (both oxfmt and nono reject JSONC).
- **`nono` allow-side domain patterns have no host wildcard** — `network.allow_domain` takes a plain hostname or a URL with a path glob (`https://github.com/org/**`). Only `deny_domain` accepts `*.host`. Anything needing wildcard hosts (e.g. Sentry's `*.ingest.sentry.io`) must be enumerated per host or left blocked.
- **`nono` `bypass_protection` grants nothing** — it only removes a deny-group rule. The path must *also* appear in `filesystem.allow` / `read` / `write` (or a `*_file` variant) to become accessible. Granting a path in `bypass_protection` alone silently changes nothing.
- **A nono user profile shadows a pack profile of the same name** — naming a local profile `claude-code` silently discards the pack's base grants. Use a distinct name (`claude-seal`) and `extends`.
- **The nono pack writes `enabledPlugins` into `~/.claude/settings.json`** — chezmoi fully owns `settings.json.tmpl`, so the key must be reflected there or `chezmoi apply` wipes it and the pack's sandbox-diagnostic hooks silently stop firing. Same failure shape as the marketplace-rename pitfall above. Verify with `jq '.enabledPlugins' ~/.claude/settings.json` after apply.
- **MCP stdio servers do not pass through zsh wrapper functions** — `mcp-servers.json` entries are exec'd directly, so the `codex()` wrapper's nested-sandbox handling does not apply to the codex MCP server. Nested-sandbox flags for MCP servers must go in `args` or a shim script.
```

- [ ] **Step 6: Update the Directory Layout and Verification tables**

In the Directory Layout table, replace any safehouse/cco row with:

```markdown
| `dot_config/nono/` | nono sandbox policy: `profiles/claude-seal.json` (the boundary), `packs.txt` (declarative pack list) |
```

In the Verification section's list of individual `make` targets, add:

```markdown
make test-nono-profile         # Validate the nono sandbox profile (skipped if nono absent)
```

and add `test-nono-profile` to the `make lint` description line.

- [ ] **Step 7: Verify docs are consistent and lint passes**

Run:
```bash
grep -rn --include='*.md' -iE 'safehouse|\bcco\b' . | grep -v node_modules | grep -v '^./docs/'
make scan-sensitive
make lint
```
Expected: the grep returns nothing outside `docs/`. Both make targets pass.

- [ ] **Step 8: Commit the docs**

```bash
git add CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
docs: nono 移行に合わせて CLAUDE.md を再構成

safehouse/cco を主層とする記述と「Native Bash sandbox (migration
target)」という位置づけの両方が実態と合わなくなったため書き換え。

- Claude Code sandbox (nono): プロファイルの所在、pack の宣言的同期、
  egress control が nono を選ぶ理由、allowlist の育て方、1Password
  ソケットの bypass_protection + read_file
- Native Bash sandbox (escape hatch): 内容はそのまま生かし、
  command claude 経路の設定であると位置づけ直す。excludedCommands と
  1Password 回避策の理由づけはその経路で引き続き有効。入れ子 Seatbelt
  と safehouse 再監査の記述は陳腐化したので削除
- パッケージインストールゲートの governance 段落と、穴の明記
- Known Pitfalls に nono 固有の落とし穴6件

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 9: Open the follow-up issues**

Run each (all three are `gh issue create`, which is `permissions.ask`-gated — expect a prompt per call):

```bash
gh issue create --title "nono: command_policies による git/gh のツールサンドボックス化" --body "$(cat <<'EOF'
`docs/superpowers/specs/2026-07-25-nono-sandbox-migration-design.md` の follow-up (1/3)。

nono の `command_policies` は、エージェントが呼ぶツールを**別ポリシーの子サンドボックス**で起動できる。エージェントの広い grant・CWD アクセス・credential・ネットワークを継承させない。

やりたいこと:
- `gh` を credential proxy 経由にし、`endpoint_policy` で API の method+path 単位にカーネル強制制限（例: `GET /repos/**` は許可、`DELETE` は不許可）
- `git` に専用の狭いポリシー（リポジトリ + git config + object store のみ）

これは現在 `permissions.ask` が担っている制御を、クリック漏れのないカーネル強制に置き換えるもの。

**ブロッカー:** 現行の `gh` 認証は macOS Keychain 経由。credential proxy は `GITHUB_TOKEN` 相当の経路を前提とするため、認証方式の作り直しが必要で、壊れる面が広い。V1 のスコープ外にしたのはこの理由。

参照: https://nono.sh/docs/cli/features/tool-sandbox
EOF
)"
```

```bash
gh issue create --title "nono: environment.allow_vars でシェル環境変数を allowlist 化" --body "$(cat <<'EOF'
`docs/superpowers/specs/2026-07-25-nono-sandbox-migration-design.md` の follow-up (2/3)。

nono はデフォルトで**親プロセスの環境変数を全て継承する**。つまりシェルに export した API キーやトークンは、ファイルシステムとネットワークを絞ってもサンドボックス内から素通しで見える。

`environment.allow_vars` を設定すると、nono は継承環境をクリアして allowlist に一致する変数だけを通す（`AWS_*` のような末尾ワイルドカードに対応）。`deny_vars` は allow_vars に一致しても剥がす。

やること:
1. 実際に必要な変数を洗い出す（`PATH`, `HOME`, `TERM`, `LANG`, `SHELL`, `TMPDIR`, `SSH_AUTH_SOCK`, `XDG_*`, `CLAUDE_*`, `MISE_*` など）
2. `dot_config/nono/profiles/claude-seal.json` に `environment.allow_vars` を追加
3. 観測: 起動・MCP・hooks・statusline・`make lint` が通るか

**注意:** 絞りすぎると静かに壊れる（例: `SSH_AUTH_SOCK` を落とすと署名が死ぬ）。段階的に狭めること。
EOF
)"
```

```bash
gh issue create --title "nono: プロファイルの CI 検証と Sentry のワイルドカードホスト対応" --body "$(cat <<'EOF'
`docs/superpowers/specs/2026-07-25-nono-sandbox-migration-design.md` の follow-up (3/3)。

**1. CI でのプロファイル意味検証**

`make test-nono-profile` は `command -v nono` ガード付きなので CI ではスキップされる。CI が見ているのは `make oxfmt` による JSON 構文だけで、未知キーや解決できない `extends` は検出されない。プロファイルが壊れると `claude` が起動しないので、影響は大きい。

案: `lint.yml` に nono をインストールするジョブを足す（Linux は `curl -fsSL https://nono.sh/install.sh | sh`）。コストと価値を比較して判断する。

**2. Sentry の `*.ingest.sentry.io`**

`sentry@claude-plugins-official` プラグインが有効だが、Sentry のエンドポイントは `<org-id>.ingest.sentry.io` 形式。nono の `allow_domain` に**ホストのワイルドカードはない**（`deny_domain` のみ `*.host` 対応）。

選択肢:
- 実際に使う org のホスト名を1件だけ列挙する
- 塞いだままにする（プラグインのテレメトリが飛ばない影響を評価）

観測フェーズの記録は `docs/solutions/integration-issues/nono-sandbox-migration-observations-2026-07-25.md`。
EOF
)"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Decision 1 (nono single layer) | 6 |
| Decision 2 (generous enumeration, grown on miss) | 2 (seed), 5 (growth), 7 (documented procedure) |
| Decision 3 (pack as base) | 1 (pull), 2 (`extends`) |
| Decision 4 (straight translation; `command_policies` deferred) | 2, 7 Step 9 issue 1 |
| Decision 5 (observation phase, then removal) | 5, 6 |
| Decision 6 (native sandbox off inside nono only) | 6 Step 1, 5 row 12, 7 Step 3 |
| Deliverables table | 1 (packs.txt, run_onchange, Brewfile), 2 (profile, Makefile) |
| Removals table | 6 Step 3 |
| Profile / 1Password socket | 2 Step 3, 5 row 1 |
| Domain allowlist seed | 2 Step 3 |
| Package-install gate | 4 |
| Other settings changes | 3 |
| `.chezmoiignore` | 1 Step 5 |
| codex | 6 Steps 1 and 4, 5 row 6 |
| Verification checklist (12 rows) | 5 Step 2 |
| Commit sequence (4 phases) | Tasks 1-4 = phase 1, Task 5 = phase 2, Task 6 = phase 3, Task 7 = phase 4 |
| Documentation changes | 7 |
| Follow-up issues (3) | 7 Step 9 |
| Out of scope | Global Constraints (macOS), unaddressed elsewhere by omission |

No gaps.

**Placeholder scan:** No `TBD`/`TODO`/"implement later". Every config block is written out in full. Task 6 Step 4 and Task 7 Step 3 are conditional on Task 5's findings, but both branches are fully specified rather than deferred.

**Type consistency:** `claude-seal` is the profile name in Tasks 2, 5, 6, and 7. `INSIDE_NONO_SANDBOX` is set in Task 2 Step 3 and consumed in Task 6 Step 1 and Step 4. `test-nono-profile` is the target name in Task 2, Task 5 Step 3, and Task 7 Step 6. `dot_config/nono/packs.txt` is the path in Task 1 Steps 3, 4, and 5. `nolabs-ai/claude` is the pack in Task 1 Step 3 and Task 7 Step 2. The `enabledPlugins` key is deliberately not hardcoded — Task 1 Step 8 records it and Task 3 Step 3 consumes the recorded value, because the upstream sources disagree.
