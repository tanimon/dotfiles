# ECC 最小導入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ecc@ecc` plugin を外し、実際に使っている ECC のファイル 17 個だけを `.chezmoiexternal.toml` で SHA 固定して取り込む。

**Architecture:** ECC リポジトリの GitHub archive(SHA 固定)を、4 つの external エントリから参照する。`archive-file` でコマンド 1 つをリネームして取り出し、`archive` + `include` で agent 4 つと rules 2 ディレクトリを取り出す。plugin・hook 用 env・rules コピー用スクリプトを撤去し、配置済みのコピーは `.chezmoiremove` で消す。指示文とテストを追従させる。

**Tech Stack:** chezmoi v2.72 external(`archive` / `archive-file`)、Go template、Renovate regex manager、bats、just

**Spec:** `docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md`

## Global Constraints

- ECC の URL: `https://github.com/affaan-m/ECC/archive/bf70150eb2df8070024e5bdf08e4aa08959e2735.tar.gz`(main、VERSION 2.2.2。2026-09-24 に `git ls-remote` で取得)。4 エントリで同じ SHA を使う
- 各 `url = ...` の**直後の行**に `  # renovate: branch=main` を置く。間に他のキーを挟まない(`.claude/rules/renovate-external.md`)
- 配置するのは 1 + 4 + 5 + 7 = **17 ファイルちょうど**
- コマンド名は `ecc-code-review`(組込みの `code-review` skill との衝突を避ける)
- `.chezmoiremove` は **bare entry**(`/**` を付けない)
- 生成物(`CLAUDE.md` / `AGENTS.md` / `.cursor/rules/*.mdc`)は直接編集しない。`harness/modules/` を編集してから `just harness-sync` を実行する
- public リポジトリなので、work org 名・ローカルアカウント名を書かない(`just scan-sensitive`)
- ブランチ上の検証は必ず `--source "$(pwd)"` を付ける(付けないと main の Source を見て、何も検証しないまま通る)
- `git diff` は difftastic になるので、unified 形式が要るときは `git diff --no-ext-diff` を使う

## Review Focus

1. **`.chezmoiignore` の `.claude/agents`(74 行目)が external を黙って無効化する** → Task 1 で行を削除し、`chezmoi managed` に agent 4 ファイルが出ることを確認する
2. **`include` の書き間違いで ECC 全体が展開される/1 ファイルも展開されない** → Task 1 で external 由来の managed ファイルがちょうど 17 個であることを確認する
3. **`.chezmoiremove` が自前の common rules(Source 管理の 4 ファイル)まで消す** → Task 2 で、dry-run の削除予定に ECC 由来 10 ファイルと golang しか出ないことを確認する
4. **settings.json.tmpl の編集で JSON が壊れる(末尾カンマ等)** → Task 2 で `just check-templates` と、レンダリング結果に対する `jq` 検査を行う
5. **sandbox 側の PR より先に `chezmoi apply` して無人ループが壊れる** → Task 5 の手順を「両 PR マージ → apply」の 1 手順として扱う

---

### Task 1: ECC ファイルを external で取り込む

**Files:**
- Modify: `.chezmoiexternal.toml`(末尾に追記)
- Modify: `.chezmoiignore:74`(`.claude/agents` の行を削除)
- Modify: `.claude/rules/renovate-external.md:37`

**Interfaces:**
- Produces: `~/.claude/commands/ecc-code-review.md`(`/ecc-code-review`)、`~/.claude/agents/{vue-reviewer,php-reviewer,security-reviewer,pr-test-analyzer}.md`、`~/.claude/rules/typescript/*.md`(5)、`~/.claude/rules/web/*.md`(7)

- [ ] **Step 1: 変更前の状態を記録する(対照の「無い」側)**

Run:
```bash
chezmoi managed --source "$(pwd)" | grep -E '^\.claude/(commands/ecc-code-review\.md|agents/|rules/(typescript|web)/)' | wc -l
```
Expected: `0`

- [ ] **Step 2: `.chezmoiexternal.toml` の末尾に追記する**

```toml

# ECC(affaan-m/ECC)から実際に使っているファイルだけを取り込む。plugin 全体(skill 292 /
# agent 68 / hook 24 系統)は読み込まない。経緯: docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md
# 4 エントリは同じ SHA を指す。Renovate はそれぞれの url 行を個別に更新する。
[".claude/commands/ecc-code-review.md"]
  type = "archive-file"
  url = "https://github.com/affaan-m/ECC/archive/bf70150eb2df8070024e5bdf08e4aa08959e2735.tar.gz"
  # renovate: branch=main
  stripComponents = 1
  path = "commands/code-review.md"
  refreshPeriod = "168h"

[".claude/agents"]
  type = "archive"
  url = "https://github.com/affaan-m/ECC/archive/bf70150eb2df8070024e5bdf08e4aa08959e2735.tar.gz"
  # renovate: branch=main
  stripComponents = 2
  include = ["*/agents/vue-reviewer.md", "*/agents/php-reviewer.md", "*/agents/security-reviewer.md", "*/agents/pr-test-analyzer.md"]
  refreshPeriod = "168h"

[".claude/rules/typescript"]
  type = "archive"
  url = "https://github.com/affaan-m/ECC/archive/bf70150eb2df8070024e5bdf08e4aa08959e2735.tar.gz"
  # renovate: branch=main
  stripComponents = 3
  include = ["*/rules/typescript/**"]
  refreshPeriod = "168h"

[".claude/rules/web"]
  type = "archive"
  url = "https://github.com/affaan-m/ECC/archive/bf70150eb2df8070024e5bdf08e4aa08959e2735.tar.gz"
  # renovate: branch=main
  stripComponents = 3
  include = ["*/rules/web/**"]
  refreshPeriod = "168h"
```

(`archive-file` の `path` は stripComponents 適用後のパスで指定する。2026-09-24 に一時 Source/Destination で実測済み)

- [ ] **Step 3: `.chezmoiignore` から `.claude/agents` の行を削除する**

`~/.claude/agents` は現在存在しない。external で管理するため除外を外す。

```bash
grep -n '^\.claude/agents$' .chezmoiignore   # 74 行目の 1 件だけであることを確認
sed -i '' '/^\.claude\/agents$/d' .chezmoiignore
```

- [ ] **Step 4: `.claude/rules/renovate-external.md` の Existing Entries を更新する**

`See `.chezmoiexternal.toml` for current entries (currently gstack skills only).` を次の内容に置き換える:

```markdown
See `.chezmoiexternal.toml` for current entries: gstack skills と、ECC(affaan-m/ECC)から選んだファイル(`ecc-code-review` コマンド・agent 4 つ・rules/typescript・rules/web)。ECC の 4 エントリは同じ SHA を指す。ECC を plugin として丸ごと有効化しない理由は `docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md`。
```

- [ ] **Step 5: 配置予定が 17 ファイルちょうどであることを確認する**

Run(archive のダウンロードが要るので sandbox 外で実行する):
```bash
chezmoi managed --source "$(pwd)" --include files | grep -E '^\.claude/(commands/ecc-code-review\.md|agents/|rules/(typescript|web)/)' | sort
```
Expected: 次の 17 行だけ
```
.claude/agents/php-reviewer.md
.claude/agents/pr-test-analyzer.md
.claude/agents/security-reviewer.md
.claude/agents/vue-reviewer.md
.claude/commands/ecc-code-review.md
.claude/rules/typescript/coding-style.md
.claude/rules/typescript/hooks.md
.claude/rules/typescript/patterns.md
.claude/rules/typescript/security.md
.claude/rules/typescript/testing.md
.claude/rules/web/coding-style.md
.claude/rules/web/design-quality.md
.claude/rules/web/hooks.md
.claude/rules/web/patterns.md
.claude/rules/web/performance.md
.claude/rules/web/security.md
.claude/rules/web/testing.md
```

- [ ] **Step 6: Renovate の隣接契約を確認する**

Run:
```bash
grep -A1 'url = "https://github.com/affaan-m/ECC' .chezmoiexternal.toml | grep -c '# renovate: branch=main'
```
Expected: `4`

- [ ] **Step 7: Commit**

```bash
git add .chezmoiexternal.toml .chezmoiignore .claude/rules/renovate-external.md
git commit -m "feat(ecc): 使用中の ECC ファイルだけを external で取り込む"
```

---

### Task 2: ECC plugin と付随設定を撤去する

**Files:**
- Modify: `dot_claude/settings.json.tmpl:10-15`(env の 3 キーとコメント)、`:266`(コメント内の `ecc:code-review` 言及)、`:272`(`"ecc@ecc": true`)、`:292-298`(`extraKnownMarketplaces.ecc`)
- Delete: `dot_claude/continuous-learning-config.json`
- Delete: `.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl`
- Delete: `dot_claude/ecc-rules-languages.txt`
- Modify: `.chezmoiremove`(末尾に追記)

**Interfaces:**
- Consumes: Task 1 で `~/.claude/rules/{typescript,web}` が external 管理になっていること(コピー用スクリプトの撤去で、この 2 ディレクトリが消えないことの前提)

- [ ] **Step 1: settings.json.tmpl の env から 3 キーを削除する**

`dot_claude/settings.json.tmpl` の 10〜15 行目(`CLV2_CONFIG` のコメントと値、`ECC_DISABLED_HOOKS` のコメントと値、`ECC_CONTEXT_MONITOR_COST_WARNINGS` のコメントと値の計 6 行)を削除する。前後は `"LANG": "ja_JP.UTF-8",` と `{{/* _ZO_DOCTOR: ...` なので、カンマの整合は変わらない。

- [ ] **Step 2: enabledPlugins と extraKnownMarketplaces から ecc を削除する**

- `    "ecc@ecc": true,` の行を削除する
- `extraKnownMarketplaces` の次のブロックを削除する:
```json
    "ecc": {
      "source": {
        "source": "github",
        "repo": "affaan-m/everything-claude-code"
      },
      "autoUpdate": true
    },
```
- 266 行目のコメントにある「および ecc:code-review と機能が重複していた」を「と機能が重複していた」に直す。plugin 撤去後の実態に合わせるため。ECC の code-review は `ecc-code-review` として残る

- [ ] **Step 3: レンダリング結果を検査する**

Run:
```bash
just check-templates
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ecc-XXXXXX"); printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmp/c.toml"
chezmoi execute-template --config "$tmp/c.toml" --source "$(pwd)" < dot_claude/settings.json.tmpl \
  | jq -e '(.env|has("CLV2_CONFIG") or has("ECC_DISABLED_HOOKS") or has("ECC_CONTEXT_MONITOR_COST_WARNINGS")|not)
           and (.enabledPlugins|has("ecc@ecc")|not)
           and (.extraKnownMarketplaces|has("ecc")|not)'
rm -rf "$tmp"
```
Expected: `PASS: all templates valid` と `true`

- [ ] **Step 4: ファイルを削除する**

```bash
git rm dot_claude/continuous-learning-config.json \
       .chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl \
       dot_claude/ecc-rules-languages.txt
```

- [ ] **Step 5: `.chezmoiremove` の末尾に追記する**

```
# ECC plugin を外し、使用中のファイルだけを .chezmoiexternal.toml で取り込むようにした
# (docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md)。以下は旧
# run_onchange_after_install-ecc-rules.sh が plugin cache からコピーした chezmoi 管理外の
# ファイルなので、明示しないと残り続けて読み込まれる。rules/common の自前 4 ファイル
# (documentation-language / github-actions / harness-engineering / shell-scripting)は
# Source 管理なので列挙しない。`path/**` は socket で apply が落ちる既知の落とし穴を踏むので bare entry にする。
.claude/rules/common/agents.md
.claude/rules/common/code-review.md
.claude/rules/common/coding-style.md
.claude/rules/common/development-workflow.md
.claude/rules/common/git-workflow.md
.claude/rules/common/hooks.md
.claude/rules/common/patterns.md
.claude/rules/common/performance.md
.claude/rules/common/security.md
.claude/rules/common/testing.md
.claude/rules/golang
.claude/continuous-learning-config.json
```

- [ ] **Step 6: 削除予定を確認する(Review Focus 3)**

Run:
```bash
chezmoi apply --dry-run --verbose --source "$(pwd)" 2>&1 | grep -E '^(rm|remove)|\.claude/rules/common/' | sort -u
```
Expected: 削除対象は Step 5 の 12 項目だけ。`documentation-language.md` / `github-actions.md` / `harness-engineering.md` / `shell-scripting.md` は削除対象に出ない。出力の形式が想定と違う場合は、`chezmoi apply --dry-run --verbose --source "$(pwd)"` の全出力から `.claude/rules` と `continuous-learning` を含む行を目視で確認する

- [ ] **Step 7: ECC への参照が残っていないことを確認する**

Run:
```bash
grep -rn -E 'ecc@ecc|ECC_DISABLED_HOOKS|CLV2_CONFIG|ECC_CONTEXT_MONITOR|ecc-rules-languages|install-ecc-rules|continuous-learning-config' \
  --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=docs . | grep -v '^./\.chezmoiremove:'
```
Expected: 一致なし。残っていれば生成物(`CLAUDE.md` / `AGENTS.md`)かどうかを見分け、Task 3 で直す

- [ ] **Step 8: Commit**

```bash
git add -A dot_claude/settings.json.tmpl .chezmoiremove
git commit -m "feat(ecc): ecc plugin と hook 用 env・rules コピー処理を撤去する"
```

---

### Task 3: 指示文とテストを実態に合わせる

**Files:**
- Modify: `dot_claude/CLAUDE.md.tmpl:4`
- Modify: `test/global-instructions.bats:121`
- Modify: `dot_codex/AGENTS.md.tmpl:34`
- Modify: `harness/modules/project/35-key-patterns.md:64`
- Modify: `harness/modules/project/50-pitfalls.md:39`
- Regenerate: `CLAUDE.md`, `AGENTS.md`(`just harness-sync`)

- [ ] **Step 1: 期待値テストを先に直す(RED)**

`test/global-instructions.bats:121` の「(`web/`、`golang/`、`typescript/`等。」を「(`web/`、`typescript/`等。」に変更する。

Run: `just test-global-instructions`
Expected: FAIL(`CLAUDE.md.tmpl` が旧文面のまま)

- [ ] **Step 2: `dot_claude/CLAUDE.md.tmpl:4` を同じ文面に直す(GREEN)**

「(`web/`、`golang/`、`typescript/`等。」→「(`web/`、`typescript/`等。」

Run: `just test-global-instructions`
Expected: PASS

- [ ] **Step 3: Codex 前置きを直す**

`dot_codex/AGENTS.md.tmpl:34` の段落を次の内容に置き換える:

```
Claude Code の `~/.claude/rules/` にはこれ以外に言語別ルール(`typescript/` / `web/`)も存在するが、それらは `.chezmoiexternal.toml` が外部リポジトリ(ECC)から取り込むもので `dot_claude/rules/common/` の Source に無いため、ここには連結されない。
```

Run: `just test-global-instructions`
Expected: PASS(32 KiB 制約を含む)

- [ ] **Step 4: harness モジュールを直す**

`harness/modules/project/35-key-patterns.md:64` の次の部分を置き換える:
- 置換前: `**連結されるのは `dot_claude/rules/common/` に Source として存在するものだけ**で、`~/.claude/rules/common/` に実在する残りのルール(`testing.md` / `security.md` / `coding-style.md` 等)は `.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl` が apply 時に ECC プラグインキャッシュからコピーするものなので Source に無く、Codex には連結されない(Codex 前置きの「ルール構成」はこの事実を明示する)。`
- 置換後: `**連結されるのは `dot_claude/rules/common/` に Source として存在するものだけ**で、`~/.claude/rules/{typescript,web}/` は `.chezmoiexternal.toml` が ECC リポジトリから SHA 固定で取り込むものなので Source に無く、Codex には連結されない(Codex 前置きの「ルール構成」はこの事実を明示する)。ECC は plugin として丸ごと有効化せず、使っているファイルだけを external で取り込む(`docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md`)。`

`harness/modules/project/50-pitfalls.md:39` の例示「(the ecc plugin has been renamed upstream more than once, `ecc` ↔ `everything-claude-code`)」を「(the since-removed ecc plugin was renamed upstream more than once, `ecc` ↔ `everything-claude-code`)」に変更する。

- [ ] **Step 5: 生成物を再生成して検査する**

Run:
```bash
just harness-sync
just check-instructions
just test-harness-instructions
```
Expected: 3 つとも成功。`git status` の変更に `CLAUDE.md` と `AGENTS.md` が含まれる

- [ ] **Step 6: Commit**

```bash
git add dot_claude/CLAUDE.md.tmpl test/global-instructions.bats dot_codex/AGENTS.md.tmpl harness/modules/project/35-key-patterns.md harness/modules/project/50-pitfalls.md CLAUDE.md AGENTS.md .cursor/rules
git commit -m "docs(harness): ECC の取り込み方式の変更を指示文に反映する"
```

---

### Task 4: ブランチ全体を検証する

- [ ] **Step 1: 全 lint**

Run: `just lint`
Expected: 全レシピ成功(`scan-sensitive` を含む)

- [ ] **Step 2: 残存の最終確認**

Run: Task 2 Step 7 のコマンドを再実行する
Expected: 一致なし

- [ ] **Step 3: PR を作成する**

PR 本文には次を含める:
- 実測値(hook エラー 33,545 件、skill の利用実績、instincts の注入内容)
- 残した 17 ファイル
- **マージ後の apply 順序制約**(Task 5)

---

### Task 5: マージ後の適用と対照確認(ブランチ外・手動)

- [ ] **Step 1: sandbox リポジトリ側の PR**

`<work-org>/sandbox` にある `ai-code-review` skill、QA 項目系 skill、`pr-review-automation-loop/README.md` の `ecc:code-review` を `ecc-code-review` に置き換える PR を作る(`grep -rn 'ecc:code-review'` で全箇所を洗い出す)。

- [ ] **Step 2: 両 PR マージ後に apply する**

```bash
git -C ~/.local/share/chezmoi pull --ff-only
chezmoi apply
claude plugin uninstall ecc@ecc   # plugin cache を片付ける(enabledPlugins を false にするだけでは cache が残る)
claude plugin marketplace remove ecc
```

- [ ] **Step 3: 新しいセッションで対照確認する(変更前の値は spec の表)**

- SessionStart の出力に `Active instincts:` が出ない
- skill 一覧に `ecc:` が無く、`/ecc-code-review` と agent 4 つが見える
- 数セッション後、直近のトランスクリプトで `node: command not found` の `hook_non_blocking_error` が 0 件:
```bash
find ~/.claude/projects -name '*.jsonl' -newer ~/.claude/commands/ecc-code-review.md | xargs grep -h '"type":"hook_non_blocking_error"' | grep -c 'node: command not found'
```
- 無人ループで 1 件のレビューが完走する

- [ ] **Step 4: 任意の後片付け(ユーザー判断)**

`~/.local/share/ecc-homunculus`(instinct データ)は plugin を外せば読まれなくなる。不要なら手動で削除する。
