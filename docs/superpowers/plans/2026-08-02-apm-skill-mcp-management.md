# APM (microsoft/apm) による Skill/MCP 管理一本化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 現在3つに分かれているClaude Code拡張機能の宣言的管理（MCPサーバー / マーケットプレイス登録 / プラグイン有効化）を、[microsoft/apm](https://github.com/microsoft/apm) の単一マニフェスト `~/.apm/apm.yml` に一本化する。

**Architecture:** `dot_apm/apm.yml`（chezmoi管理、`~/.apm/apm.yml` にデプロイ）に MCP サーバーと Skill/プラグインの依存を宣言し、`.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl` がハッシュ変化時に `apm install --global` を自動実行して実際に反映する。フェーズ1でMCPサーバーを移行して旧仕組み（`mcp-servers.json` + `modify_claude.json`）を撤去し、動作確認後、フェーズ2でSkill/プラグインを移行して旧仕組み（`marketplaces.txt` + `settings.json.tmpl` の `enabledPlugins`/`extraKnownMarketplaces`）を撤去する。

**Tech Stack:** chezmoi（`run_onchange_after_` パターン）、APM CLI（Homebrew配布、Python製）、bats-core（既存スモークテスト）

## Global Constraints

- 新旧メカニズムを並行稼働させない。撤去は導入と同一PR・同一タスク内で行う（`~/.claude.json` の `mcpServers` キーへの二重書き込みを防ぐため）。design docの「Conflict Prevention」節を参照: `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md`
- `apm.yml` に Go template は使わない（`.tmpl` 拡張子は付けない）
- 実行タイミングは自動（`run_onchange_after_`）。既存の `add-marketplaces.sh.tmpl` と同じ骨格を踏襲する
- OSガードは `run_onchange_` スクリプトでは許容される（`modify_` スクリプトのみ禁止）。既存の `add-marketplaces.sh.tmpl` が前例
- `docs/plans/` と `docs/solutions/` の既存ファイルは履歴記録なので編集しない。生きたドキュメント（`CLAUDE.md`, `.chezmoiignore`）のみ更新する

---

## Phase 1: MCPサーバー移行

### Task 1: APMをHomebrewでインストール可能にする

**Files:**
- Modify: `darwin/Brewfile`

**Interfaces:**
- Produces: `apm` コマンドが `brew bundle` 経由でインストールされる（後続タスクが `apm` CLI に依存する）

- [ ] **Step 1: `tap` セクションにAPMのtapを追加**

`darwin/Brewfile` の `tap` 行はアルファベット順。`tap "manaflow-ai/cmux"` と `tap "theboredteam/boring-notch"` の間に挿入する。

```
old_string:
tap "manaflow-ai/cmux"
tap "theboredteam/boring-notch"

new_string:
tap "manaflow-ai/cmux"
tap "microsoft/apm"
tap "theboredteam/boring-notch"
```

- [ ] **Step 2: tap修飾済み `brew` セクションに追加**

ファイル末尾付近、`brew "k1low/tap/mo"` と `brew "yammerjp/tap/pdef"` の間に挿入する（この3行は tap 名のアルファベット順でまとまっている）。

```
old_string:
brew "coderabbitai/tap/git-gtr"
brew "k1low/tap/mo"
brew "yammerjp/tap/pdef"

new_string:
brew "coderabbitai/tap/git-gtr"
brew "k1low/tap/mo"
brew "microsoft/apm/apm"
brew "yammerjp/tap/pdef"
```

- [ ] **Step 3: 手元でインストールして動作確認**

Run: `brew bundle install --file=darwin/Brewfile 2>&1 | tail -5 && apm --version`
Expected: `apm` のバージョン番号が出力される（ネットワークアクセスとHomebrewの実行権限が必要。サンドボックス内で失敗する場合は `dangerouslyDisableSandbox: true` で再実行する）

- [ ] **Step 4: Commit**

```bash
git add darwin/Brewfile
git commit -m "chore: darwin/BrewfileにAPM(microsoft/apm)を追加"
```

---

### Task 2: `dot_apm/apm.yml` を作成しMCPサーバーを宣言する

**Files:**
- Create: `dot_apm/apm.yml`

**Interfaces:**
- Consumes: Task 1 の `apm` CLI
- Produces: `~/.apm/apm.yml`（chezmoi適用後）。Task 3 の自動化スクリプトが読み込むファイルパス `dot_apm/apm.yml`

- [ ] **Step 1: `dot_apm/apm.yml` を作成**

`dot_claude/mcp-servers.json` の2エントリ（`codex`, `deepwiki`）をAPMの非レジストリ・インライン形式に変換する。

```yaml
name: tanimon-global
version: 1.0.0

dependencies:
  mcp:
    - name: codex
      registry: false
      transport: stdio
      command: codex
      args: ["-m", "gpt-5.2-codex", "mcp-server"]
    - name: deepwiki
      registry: false
      transport: http
      url: https://mcp.deepwiki.com/mcp
```

- [ ] **Step 2: YAML構文を検証**

Run: `python3 -c "import yaml; print(yaml.safe_load(open('dot_apm/apm.yml')))"`
Expected: パースされた辞書が出力される（例外が出ないこと）

- [ ] **Step 3: 手元で `~/.apm/apm.yml` に配置し `apm install --global` を試行**

まだ `run_onchange_` スクリプトを作っていないので、手動でコピーして動作確認する。

Run:
```bash
mkdir -p ~/.apm
cp dot_apm/apm.yml ~/.apm/apm.yml
apm install --global --dry-run
```
Expected: `codex` と `deepwiki` の2つのMCPサーバーがインストール計画に含まれる出力。スキーマエラーが出た場合は、エラーメッセージに従って `dot_apm/apm.yml` の `mcp` エントリのフィールド名（`name`/`registry`/`transport`/`command`/`args`/`url`）を修正する（`apm view` や `apm doctor` でスキーマ詳細を確認できる）。

- [ ] **Step 4: 実際に反映して `~/.claude.json` を確認**

Run:
```bash
apm install --global
jq '.mcpServers' ~/.claude.json
```
Expected: `codex` と `deepwiki` の2キーのみが `mcpServers` に存在する

- [ ] **Step 5: Commit**

```bash
git add dot_apm/apm.yml
git commit -m "feat: dot_apm/apm.ymlを新設しMCPサーバー定義を移行"
```

---

### Task 3: `apm install --global` を自動実行する run_onchange スクリプトを作成する

**Files:**
- Create: `.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl`

**Interfaces:**
- Consumes: `dot_apm/apm.yml`（Task 2で作成）、既存パターン: `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl`
- Produces: `chezmoi apply` 実行時に `apm.yml` のハッシュ変化を検知して `apm install --global` を実行する仕組み

- [ ] **Step 1: スクリプトを作成**

既存の `run_onchange_after_add-marketplaces.sh.tmpl` と同じ骨格（OSガード、ハッシュコメント、コマンド存在チェック）を踏襲する。

```
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# apm.yml hash: {{ include "dot_apm/apm.yml" | sha256sum }}

if ! command -v apm &>/dev/null; then
  echo "apm CLI not found, skipping apm install --global"
  exit 0
fi

apm install --global --target claude || echo "WARNING: apm install --global failed; run it manually to sync Skills/MCP servers" >&2
{{ end -}}
```

**注記（Task 2実装中に判明）**: `apm install --global`（`--target`省略）は、検出できた「グローバル対応の全ランタイム」に配布する挙動で、実機検証の結果Claude Code以外にGemini CLI（`~/.gemini/settings.json`）・Kiro（`~/.kiro/settings/mcp.json`）にも実際にMCPサーバー設定を書き込むことを確認した。これらはこのdotfilesリポジトリが管理していないツールであり、意図しない副作用となる。`apm install --help` で確認した `-t, --target TARGET` オプションに `claude` を指定し、Claude Codeのみに展開先を限定する（ユーザー承認済み、2026-08-02）。

- [ ] **Step 2: テンプレート構文を検証**

Run: `make check-templates`
Expected: `Validating chezmoi templates...` の後、全ファイルでFAILが出ない（新規ファイルが `TMPL_FILES` に自動的に含まれる — Makefileの `find . -name '*.tmpl'` による動的検出のため、Makefile自体の変更は不要）

- [ ] **Step 3: shellcheck / shfmt の対象になることを確認**

`.tmpl` 拡張子のファイルは `SHELL_FILES`（`! -name '*.tmpl'` で除外）の対象外であることを確認する。

Run: `make shellcheck 2>&1 | grep apm-install || echo "対象外(想定通り)"`
Expected: `対象外(想定通り)` が出力される（`.tmpl` ファイルはshellcheck対象外という既存方針に従う。中身のシェルロジックは `add-marketplaces.sh.tmpl` と同じ骨格なので個別のshellcheckは行わない）

- [ ] **Step 4: Commit**

```bash
git add .chezmoiscripts/run_onchange_after_apm-install.sh.tmpl
git commit -m "feat: apm.yml変更時にapm install --globalを自動実行するrun_onchangeスクリプトを追加"
```

---

### Task 4: 旧MCPメカニズムを撤去する（`mcp-servers.json` / `modify_claude.json`）

**Files:**
- Delete: `dot_claude/mcp-servers.json`
- Delete: `dot_claude/modify_claude.json`
- Delete: `test/modify-dot-claude.bats`
- Modify: `Makefile`
- Modify: `CLAUDE.md`
- Modify: `.chezmoiignore`

**Interfaces:**
- Consumes: Task 2・Task 3 が完了し、APM経由でMCPサーバーが反映されることを確認済みであること
- Produces: chezmoiが `~/.claude/claude.json` に一切書き込まなくなる状態（APMが単独でその `mcpServers` キーを所有する）

- [ ] **Step 1: 旧ファイルを削除**

```bash
git rm dot_claude/mcp-servers.json dot_claude/modify_claude.json test/modify-dot-claude.bats
```

- [ ] **Step 2: `Makefile` の `test-modify` ターゲットを更新**

```
old_string:
test-modify:
	pnpm exec bats test/modify-dot-claude.bats test/modify-karabiner.bats

new_string:
test-modify:
	pnpm exec bats test/modify-karabiner.bats
```

- [ ] **Step 3: `make test-modify` を実行して確認**

Run: `make test-modify`
Expected: `test/modify-karabiner.bats` のテストのみ実行され、全てPASSする

- [ ] **Step 4: `CLAUDE.md` の `modify_claude.json` に関する説明を置き換え**

`### Key Patterns` 内の該当パラグラフを、APMベースの新しいパターン説明に差し替える。

```
old_string:
**`dot_claude/modify_claude.json`** — Partially manages `~/.claude/claude.json` (a large runtime file). Uses `jq` to replace only the `mcpServers` key from `dot_claude/mcp-servers.json`, preserving all other runtime state. This is the correct pattern for files where chezmoi should own a subset of keys. Since 2026-07-26, native Claude Code installs store their real state at `~/.claude/claude.json` and leave `~/.claude.json` as a symlink to it for backward compatibility; the script targets the real file directly, and `~/.claude.json` is excluded via `.chezmoiignore` (see Known Pitfalls).

new_string:
**`dot_apm/apm.yml` + APM (microsoft/apm)** — Single declarative manifest for MCP servers and (as of the Skill/plugin migration) Claude Code Skills/plugins, deployed to `~/.apm/apm.yml`. `run_onchange_after_apm-install.sh.tmpl` tracks the file's hash and runs `apm install --global` when it changes, which writes MCP servers directly into the top-level `mcpServers` key of `~/.claude.json` (real file: `~/.claude/claude.json`, see the symlink note below) and deploys Skills to `~/.claude/skills/`. APM marks its own generated files, so hand-authored files (e.g. `dot_claude/skills/*`) are never overwritten. chezmoi no longer manages `~/.claude/claude.json` directly — this replaced the earlier `modify_claude.json` (jq-based partial ownership) approach. See `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md`.
```

- [ ] **Step 5: `CLAUDE.md` のディレクトリレイアウト表を更新**

```
old_string:
| `dot_claude/` | Claude Code config (`~/.claude/`): settings (`settings.json.tmpl`), MCP servers (`mcp-servers.json`), rules, commands, plugins, scripts (hooks), keybindings |

new_string:
| `dot_claude/` | Claude Code config (`~/.claude/`): settings (`settings.json.tmpl`), rules, commands, plugins, scripts (hooks), keybindings |
| `dot_apm/` | APM (microsoft/apm) global manifest: `apm.yml` — declares MCP servers and Claude Code Skills/plugins, deployed to `~/.apm/apm.yml` |
```

- [ ] **Step 6: 「Known Pitfalls」の `modify_*` 拡張子の注意書きをkarabinerのみの例に更新**

```
old_string:
- **Do not judge `modify_*` files by extension** — `dot_claude/modify_claude.json` has a `.json` extension but is a bash script. Add `! -name 'modify_*'` exclusions to file-type-based linter/formatter globs (`*.json`, `*.yaml`, etc.). Also include `modify_` patterns in pre-commit excludes.
- **Claude Code's native install symlinks `~/.claude.json` to `~/.claude/claude.json`** — since 2026-07-26 the real runtime state file moved to `~/.claude/claude.json`, leaving `~/.claude.json` as a symlink for backward compatibility. A `modify_` script that still targeted `~/.claude.json` directly would have chezmoi read through the symlink for stdin but **write a plain file back, deleting the symlink** — verified in an isolated test (`chezmoi apply -S <tmp> -D <tmp>` replaced a `120755` symlink with a `100644` regular file). `dot_claude/modify_claude.json` now targets `~/.claude/claude.json` directly, and `~/.claude.json` is listed in `.chezmoiignore` so chezmoi never touches the symlink itself.

new_string:
- **Do not judge `modify_*` files by extension** — `dot_config/karabiner/modify_karabiner.json` has a `.json` extension but is a bash script. Add `! -name 'modify_*'` exclusions to file-type-based linter/formatter globs (`*.json`, `*.yaml`, etc.). Also include `modify_` patterns in pre-commit excludes.
- **Claude Code's native install symlinks `~/.claude.json` to `~/.claude/claude.json`** — since 2026-07-26 the real runtime state file moved to `~/.claude/claude.json`, leaving `~/.claude.json` as a symlink for backward compatibility. Nothing in this repo manages `~/.claude/claude.json` directly anymore (APM's `apm install --global` writes its `mcpServers` key at runtime, outside chezmoi's control) — but the historical lesson stands for any future `modify_` script: writing back through the `~/.claude.json` symlink would replace it with a plain file (verified in an isolated test, `chezmoi apply -S <tmp> -D <tmp>` replaced a `120755` symlink with a `100644` regular file). `~/.claude.json` stays listed in `.chezmoiignore` so chezmoi never touches the symlink itself.
```

- [ ] **Step 7: `.chezmoiignore` のコメントを更新**

```
old_string:
# ~/.claude.json is a symlink to ~/.claude/claude.json managed by Claude Code
# itself (since 2026-07-26); dot_claude/modify_claude.json targets the real
# file directly, so chezmoi must never touch this symlink.
.claude.json

new_string:
# ~/.claude.json is a symlink to ~/.claude/claude.json managed by Claude Code
# itself (since 2026-07-26). Nothing in this repo targets the real file
# directly anymore (APM's `apm install --global` owns its mcpServers key at
# runtime); chezmoi must never touch this symlink.
.claude.json
```

- [ ] **Step 8: `make lint` を実行**

Run: `make lint`
Expected: 全ターゲットPASS（`secretlint`, `scan-sensitive`, `test-modify` 等）

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "chore: 旧MCPサーバー管理(mcp-servers.json/modify_claude.json)を撤去しAPMに一本化"
```

---

### Task 5: フェーズ1のエンドツーエンド検証

**Files:**
- （変更なし。検証のみ）

**Interfaces:**
- Consumes: Task 1〜4 の全変更

- [ ] **Step 1: テンプレートレンダリングを検証**

`chezmoi apply` は `main` ブランチのソースを読むため、未マージのブランチではこのworktreeから直接検証できない（既知の落とし穴、`CLAUDE.md` の "chezmoi apply deploys from main" 参照）。代わりに `--source` を明示してレンダリングを検証する。

Run:
```bash
tmpconfig=$(mktemp "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml")
printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
chezmoi execute-template --config "$tmpconfig" --source "$(pwd)" < .chezmoiscripts/run_onchange_after_apm-install.sh.tmpl
```
Expected: レンダリングされたシェルスクリプトが出力され、`# apm.yml hash: ...` の行に実際のSHA256ハッシュが埋め込まれている

- [ ] **Step 2: `make lint` を再実行して全体を確認**

Run: `make lint`
Expected: 全ターゲットPASS

- [ ] **Step 3: マージ後の実機確認をユーザーに依頼するメモを残す**

このタスクはコード変更を伴わないため、実装者はここでユーザーに次を依頼する: 「このブランチをmainにマージし、実機で `chezmoi apply` を実行して `~/.claude.json` の `mcpServers` が `codex`/`deepwiki` の2件のみになっていることを確認してください」。

- [ ] **Step 4: Commit**

変更がなければコミット不要。Step 1で一時ファイルを作った場合は削除する: `rm -f "$tmpconfig"`（`$TMPDIR` 配下なのでリポジトリには影響しない）。

---

## Phase 2: Skill/プラグイン移行

### Task 6: APMのプラグイン参照構文を1件で検証し `apm.yml` に反映する

**Files:**
- Modify: `dot_apm/apm.yml`

**Interfaces:**
- Consumes: Phase 1 完了（`apm` CLIが動作していること）
- Produces: `dependencies.apm` の正しい参照構文（後続タスクで残り8件に機械的に適用する）

現在 `dot_claude/settings.json.tmpl` の `enabledPlugins` で `true` になっている9件が移行対象。まず1件（`superpowers@claude-plugins-official`）で構文を確定させる。

- [ ] **Step 1: `apm search` / `apm view` でパッケージ参照構文を確認**

Run:
```bash
apm search superpowers 2>&1 | head -20
apm view anthropics/claude-plugins-official/plugins/superpowers 2>&1 | head -20
```
Expected: いずれかのコマンドがエラーにならず、`superpowers` プラグインの情報（パス、バージョン等）を返す。両方エラーになる場合は `apm marketplace add anthropics/claude-plugins-official` を先に実行してから再試行する。

- [ ] **Step 2: dry-runでインストール計画を確認**

Run: `apm install anthropics/claude-plugins-official/plugins/superpowers --global --target claude --dry-run`
Expected: `superpowers` プラグインのSkill群が `~/.claude/skills/` 配下に展開される計画が出力される。参照構文がエラーになった場合、Step 1のエラーメッセージに従って正しい形式（`plugin-name@marketplace-name` 形式の可能性がある。例: `superpowers@claude-plugins-official`）に変える。

- [ ] **Step 3: `dot_apm/apm.yml` に `dependencies.apm` を追加**

Step 1〜2で確定した構文を使う（以下は `owner/repo/plugins/name` 形式が有効だった場合の例。実際に検証した構文に置き換えること）。

```yaml
dependencies:
  mcp:
    - name: codex
      registry: false
      transport: stdio
      command: codex
      args: ["-m", "gpt-5.2-codex", "mcp-server"]
    - name: deepwiki
      registry: false
      transport: http
      url: https://mcp.deepwiki.com/mcp
  apm:
    - anthropics/claude-plugins-official/plugins/superpowers
```

- [ ] **Step 4: 実インストールして確認**

Run:
```bash
apm install --global --target claude
ls ~/.claude/skills/ | grep -i superpower || ls ~/.claude/agents/
```
Expected: `superpowers` プラグイン由来のSkill/エージェントファイルが展開されている

- [ ] **Step 5: Commit**

```bash
git add dot_apm/apm.yml
git commit -m "feat: apm.ymlにsuperpowersプラグインを追加(参照構文の検証)"
```

---

### Task 7: 残り8件のプラグインを `apm.yml` に追加する

**注記（Task 6実装中に判明・2026-08-02訂正）**: 当初想定していた `owner/repo/plugins/name` 形式・`name@marketplace`（マーケットプレイスのオブジェクト参照）形式は、いずれも実機検証で無効と判明した。有効なのは **git直指定の文字列形式 `owner/repo#ref`** のみ（`ref`はタグ/ブランチ/コミット）。`superpowers` は `obra/superpowers#v6.2.0` として解決済み（`dot_apm/apm.yml` に反映・コミット済み）。また、マーケットプレイス登録（`apm marketplace add`）は宣言的に管理されていないため、新規マシンでの再現性を優先し、**マーケットプレイス参照ではなく必ずgit直指定形式を使うこと**（ユーザー承認済み）。

**Files:**
- Modify: `dot_apm/apm.yml`

**Interfaces:**
- Consumes: Task 6 で確定した `owner/repo#ref` 形式

現在 `enabledPlugins` で `true` の残り8件を対象とする。それぞれの実際のソースリポジトリは、`enabledPlugins`のキーが指すマーケットプレイス経由でしか分からない（マーケットプレイスがプラグインを別リポジトリへの参照として保持している場合がある — `superpowers`の実体が`anthropics/claude-plugins-official`ではなく`obra/superpowers`だったのがその例）。そのため、各プラグインについて以下の手順で実体を特定してから `owner/repo#ref` 形式でピン留めする。

- [ ] **Step 1: 各プラグインの実体リポジトリ・バージョンを特定**

対象と、現時点で分かっている所属マーケットプレイス（`dot_claude/settings.json.tmpl` の `enabledPlugins`/`extraKnownMarketplaces` より）:

| プラグイン | マーケットプレイス | マーケットプレイスのソースリポジトリ |
|---|---|---|
| `commit-commands` | `claude-plugins-official` | `anthropics/claude-plugins-official` |
| `ralph-loop` | `claude-plugins-official` | `anthropics/claude-plugins-official` |
| `claude-md-management` | `claude-plugins-official` | `anthropics/claude-plugins-official` |
| `skill-creator` | `claude-plugins-official` | `anthropics/claude-plugins-official` |
| `sentry` | `claude-plugins-official` | `anthropics/claude-plugins-official` |
| `compound-engineering` | `compound-engineering-plugin` | `EveryInc/compound-engineering-plugin` |
| `ecc` | `ecc` | `affaan-m/everything-claude-code` |
| `nono` | `nolabs-ai`（`extraKnownMarketplaces`未登録） | 不明。まず `apm marketplace list` に登録があるか確認 |

`claude-plugins-official` は既にTask 6で `apm marketplace add anthropics/claude-plugins-official` 済みのはず(未登録なら再実行)。各プラグインについて:

```bash
apm view <plugin-name>@claude-plugins-official 2>&1 | head -20
```

出力から実体のgitリポジトリとバージョン/コミットを読み取る（`superpowers`の場合は`repo_url: obra/superpowers`, `version: 6.2.0`だった）。`compound-engineering`/`ecc`/`nono`はマーケットプレイスが異なるため、先に `apm marketplace add EveryInc/compound-engineering-plugin` / `apm marketplace add affaan-m/everything-claude-code` を実行してから同様に `apm view <name>@<marketplace>` を試す。`nono`が解決できない場合（`nolabs-ai`が`extraKnownMarketplaces`に未登録で、独自配布の可能性が高い）は、手作業ファイルとして残す判断も可（懸念事項に記載し先送りしてよい）。

- [ ] **Step 2: 特定した実体を `owner/repo#ref` 形式でdry-run検証**

各プラグインについて（`superpowers`と同じ検証パターン）:

```bash
apm install <owner>/<repo>#<ref> --global --target claude --dry-run
```

Expected: エラーなくインストール計画に表示される。`--dry-run`はロックファイルを実際には更新しないため、8件分を1つずつ実行して構わない。

- [ ] **Step 3: `dot_apm/apm.yml` に `dependencies.apm` として追加**

Step 1〜2で特定した実体を使う（以下は判明した内容の例。プレースホルダの `owner/repo#ref` は実際にStep 1〜2で確認した値に置き換えること）:

```yaml
  apm:
    - obra/superpowers#v6.2.0
    - <commit-commandsの実体owner/repo#ref>
    - <ralph-loopの実体owner/repo#ref>
    - <claude-md-managementの実体owner/repo#ref>
    - <skill-creatorの実体owner/repo#ref>
    - <sentryの実体owner/repo#ref>
    - <compound-engineeringの実体owner/repo#ref>
    - <eccの実体owner/repo#ref>
```

`nono`をStep 1で解決できなかった場合は追加せず、報告書に理由を明記する。

- [ ] **Step 2: dry-runで全体を確認**

Run: `apm install --global --target claude --dry-run`
Expected: 9件全てのプラグインがインストール計画に含まれる。エラーが出たプラグインは個別に `apm view <ref>` で参照構文を再確認する。

- [ ] **Step 3: 実インストールして確認**

Run:
```bash
apm install --global --target claude
ls ~/.claude/skills/
```
Expected: 各プラグイン由来のSkillディレクトリが並ぶ。既存の自作Skill（`chezmoi-adopt-drift`, `harness-reflect`, `harness-review`, `node-typescript-mts-esm`）が消えていないことも確認する。

- [ ] **Step 4: Commit**

```bash
git add dot_apm/apm.yml
git commit -m "feat: 残りのプラグイン8件をapm.ymlに追加"
```

---

### Task 8: 旧マーケットプレイス/プラグイン有効化メカニズムを撤去する

**Files:**
- Delete: `dot_claude/plugins/marketplaces.txt`
- Delete: `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl`
- Delete: `scripts/update-marketplaces.sh`
- Modify: `dot_claude/settings.json.tmpl`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: Task 6・Task 7 が完了し、APM経由で全プラグインが反映されることを確認済みであること

- [ ] **Step 1: 旧ファイルを削除**

```bash
git rm dot_claude/plugins/marketplaces.txt .chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl scripts/update-marketplaces.sh
```

- [ ] **Step 2: `dot_claude/settings.json.tmpl` から `enabledPlugins` / `extraKnownMarketplaces` ブロックを削除**

`"enabledPlugins": { ... },` から `"extraKnownMarketplaces": { ... },` までのブロック全体（現在の該当箇所は `enabledPlugins` 開始から `extraKnownMarketplaces` の閉じ `},` まで、`"language": "japanese",` の直前）を削除する。Editツールで該当ブロックの開始行 `"enabledPlugins": {` から終了行の次の `"language": "japanese",` の直前までを対象にする(既存ファイルを読んでから正確な行範囲を確認して編集すること)。

- [ ] **Step 3: `make check-templates` で構文検証**

Run: `make check-templates`
Expected: 全 `.tmpl` ファイルでFAILが出ない

- [ ] **Step 4: `CLAUDE.md` のマーケットプレイス同期の説明を置き換え**

```
old_string:
**Declarative marketplace sync** — `dot_claude/plugins/marketplaces.txt` lists marketplace sources (one per line: `owner/repo` or URL). `run_onchange_after_add-marketplaces.sh.tmpl` tracks the file hash and runs `claude plugin marketplace add` for each entry when it changes. To add a new marketplace: register it locally with `claude plugin marketplace add`, run `scripts/update-marketplaces.sh` to regenerate the list, then commit and push. To remove: run `claude plugin marketplace remove` manually on each machine — removing a line from `marketplaces.txt` does not unregister the marketplace. Plugin install/enable state (`installed_plugins.json`, `known_marketplaces.json`) is not managed by chezmoi — these files are in `.chezmoiignore`.

new_string:
**Skill/plugin management via APM** — `dot_apm/apm.yml`'s `dependencies.apm` list declares every Claude Code plugin to install (superseding the earlier `marketplaces.txt` + `settings.json.tmpl` `enabledPlugins`/`extraKnownMarketplaces` combination). `run_after_apm-install.sh.tmpl` runs `apm install --global --target claude` on every `chezmoi apply` (not gated on `apm.yml`'s hash — plugin hooks land directly in `~/.claude/settings.json`, which `settings.json.tmpl` also fully owns, so this script must re-run every apply to keep hooks from silently disappearing after the next `chezmoi apply` overwrites them). Plugins are pinned as git shorthand strings (`owner/repo#ref`, e.g. `obra/superpowers#v6.2.0`) rather than marketplace references, since APM's own marketplace registry (`~/.apm/marketplaces.json`) is not declaratively bootstrapped and would fail to resolve on a fresh machine. To add a plugin: find its real upstream repo+ref (`apm view <name>@<marketplace>` after `apm marketplace add <marketplace-repo>`, or check the marketplace's `.claude-plugin/marketplace.json` directly), append `owner/repo#ref` to `dependencies.apm`, commit, and let the next `chezmoi apply` install it. To remove: delete the line from `apm.yml` — `apm install --global` reconciles deployed files against the current manifest, but only for files it generated (hand-authored files, e.g. `dot_claude/skills/*`, are never touched). Plugin install/enable runtime state (`installed_plugins.json`, `known_marketplaces.json`) is still not managed by chezmoi — these files remain in `.chezmoiignore`.
```

- [ ] **Step 5: `CLAUDE.md` の `scripts/` ディレクトリ説明を更新**

```
old_string:
| `scripts/` | Repo-only helper scripts (`update-brewfile.sh`, `update-marketplaces.sh`, `update-gh-extensions.sh`) |

new_string:
| `scripts/` | Repo-only helper scripts (`update-brewfile.sh`, `update-gh-extensions.sh`) |
```

- [ ] **Step 6: `make lint` を実行**

Run: `make lint`
Expected: 全ターゲットPASS

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: 旧マーケットプレイス/プラグイン有効化メカニズムを撤去しAPMに一本化"
```

---

### Task 9: フェーズ2のエンドツーエンド検証

**Files:**
- （変更なし。検証のみ）

**Interfaces:**
- Consumes: Task 6〜8 の全変更

- [ ] **Step 1: `make lint` の最終実行**

Run: `make lint`
Expected: 全ターゲットPASS

- [ ] **Step 2: `dot_claude/settings.json.tmpl` のレンダリング確認**

Run:
```bash
tmpconfig=$(mktemp "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml")
printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
chezmoi execute-template --config "$tmpconfig" --source "$(pwd)" < dot_claude/settings.json.tmpl | jq -e 'has("enabledPlugins") | not'
rm -f "$tmpconfig"
```
Expected: `true`（`enabledPlugins` キーが存在しない）

- [ ] **Step 3: マージ後の実機確認をユーザーに依頼するメモを残す**

実装者はここでユーザーに次を依頼する: 「このブランチをmainにマージし、実機で `chezmoi apply` を実行後、`ls ~/.claude/skills/` で9件のプラグイン由来Skillと4件の自作Skillが両方存在することを確認してください」。

- [ ] **Step 4: Commit**

変更がなければコミット不要。
