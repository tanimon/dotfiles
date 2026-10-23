### Key Patterns

**`dot_apm/apm.yml` + APM (microsoft/apm)** — MCP サーバーだけを宣言する APM のグローバル manifest(`~/.apm/apm.yml` に配置)。Skills / plugins は APM ではなく Claude Code ネイティブの marketplace で管理する(次項)。ターゲットの二重宣言・APM の所有境界・`~/.claude.json` symlink との関係・手動 `apm install` が apply で消える点など運用上の契約は `dot_apm/CLAUDE.md`(`dot_apm/` 配下の作業時に読み込まれる)にまとめてある。

**`dot_config/karabiner/modify_karabiner.json`** — `~/.config/karabiner/karabiner.json` の `profiles[*].complex_modifications.rules` だけを所有する部分管理(`modify_` スクリプト。ルールの実体は `complex_modifications.json`)。所有範囲・空 stdin の扱い・ファイルモードの挙動は `dot_config/karabiner/CLAUDE.md`(`dot_config/karabiner/` 配下の作業時に読み込まれる)にまとめてある。Smoke-tested by `just test-modify`.

**Skill/plugin management via native Claude Code marketplace** — Skills and plugins are managed by Claude Code's own plugin/marketplace mechanism, not APM, because only it provides per-plugin Skill namespacing (`plugin:skill` invocation names, e.g. `/commit-commands:commit`) — APM deploys all Skills flatly to `~/.claude/skills/<name>/SKILL.md` regardless of how the dependency is declared (git shorthand or marketplace form), so it can't provide this namespacing; only Claude Code's native plugin loader (which keeps each plugin's Skills under its own `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/`) does. `dot_claude/settings.json.tmpl` declares `enabledPlugins` (which plugins are on) and `extraKnownMarketplaces` (which marketplace repos are known) directly — both chezmoi-owned, declarative. There is deliberately **no automation** for marketplace registration: `extraKnownMarketplaces` alone does not fetch/clone a marketplace, so on a new machine you must run `claude plugin marketplace add <owner/repo>` once per marketplace listed in `extraKnownMarketplaces` before `enabledPlugins` entries can resolve — this manual step was accepted as a tradeoff for keeping the mechanism to a single file. Accepted risk: if a marketplace or plugin is renamed upstream, the `plugin@marketplace` key in `enabledPlugins` silently stops matching and the plugin stops loading with no error (see the Known Pitfalls entry below) — re-running is what surfaces it. `nono@nolabs-ai` is a special case: the nono pack registers its own marketplace as a local `directory` source (not a GitHub repo) as a side effect of `nono pull`/`nono update`, so it has no corresponding `extraKnownMarketplaces` entry — only the `enabledPlugins` flag is chezmoi-managed for it (see the comment above that key in `settings.json.tmpl`). MCP servers stay on APM (`dot_apm/apm.yml`'s `dependencies.mcp`, see above).

**Declarative gh extension sync** — `dot_config/gh/extensions.txt` lists gh extensions (one `owner/repo` per line). `run_onchange_after_install-gh-extensions.sh.tmpl` installs them when the list changes. `scripts/update-gh-extensions.sh` regenerates the list from `gh extension list`. Note: `gh extension list` is tab-delimited — use `awk -F'\t'` to parse.

**`run_onchange_` scripts** — Track file hashes in comments (e.g., `# brewfile hash: {{ include "darwin/Brewfile" | sha256sum }}`). They re-run only when the tracked content changes.

**リポジトリの場所ベースの gitignore 切り替え(includeIf)** — 経緯ドキュメント(`docs/superpowers/` など)を仕事リポジトリでは除外し個人リポジトリでだけ commit する仕組みと不採用案は、`.claude/rules/gitignore-includeif.md`(関連ファイルを扱うときだけ読み込まれる)にある。

**Identity leak guard(`scripts/scan-sensitive-info.sh`)** — このリポジトリは public なので、work 用 GitHub org 名とローカルアカウント名を git 管理下のファイルに**書かない**(散文中の言及・プロジェクトスラグ `-Users-<user>--` の形も含む。例示はプレースホルダにする)。ガードの 2 層の仕組み・出力の redact・allowlist の書式は `.claude/rules/identity-leak-guard.md`(ガードを触るときだけ読み込まれる)にある。

**Claude Code sandbox (nono)** — `claude-nono` in `dot_config/zsh/sandbox.zsh` (on trial; plain `claude` is unwrapped) runs Claude Code inside [nono](https://github.com/nolabs-ai/nono) (Homebrew, macOS Seatbelt / Linux Landlock, deny-all default), extending the official `claude-code` pack via `dot_config/nono/profiles/claude-seal.json`. See `dot_config/nono/CLAUDE.md` for the full policy detail (egress control, git/gh-inside-the-boundary, 1Password signing, accepted security residuals, the native Bash sandbox).

**Notification hook ownership** — `dot_claude/scripts/executable_notify.sh` wires notification delivery to `Notification`/`StopFailure` only. See `dot_claude/scripts/CLAUDE.md` for the full detail (matcher filtering, orca handoff, delivery backend fallback).

**Worktree seeding hook** — `dot_claude/scripts/executable_worktree-include.sh` runs at `SessionStart` and copies the files a repo's `.worktreeinclude` lists from the main worktree into the linked worktree, filling the gap left when a worktree is created by anything other than `gtr new` (orca, plain `git worktree add`). Copy-if-absent, never overwrite. See `dot_claude/scripts/CLAUDE.md` for the full detail (why not `git gtr copy`, the deliberate leading-`/` divergence from gtr, pattern semantics).

**git push guard hook** — `dot_claude/scripts/executable_git-push-guard.sh` は `PreToolUse`(`matcher: "Bash"`)で走り、`git push` の破壊的な綴り(force / delete / mirror / prune / `+refspec` / `:branch`)を**引数位置に関係なく** `deny` し、読み切れない引数は fail-closed で `ask` にする。素の push は無出力で `defaultMode: auto` のクラシファイアに任せる。`Bash(git push:*)` を `permissions.ask` に戻さないこと(承認疲れの構成の置き換え)。判定・残存リスクは `.claude/rules/git-push-guard.md`、共有の reader は `.claude/rules/shell-reader.md`。

**curl localhost guard hook** — `dot_claude/scripts/executable_curl-localhost-guard.sh` は `PreToolUse`(`matcher: "Bash"`)で走り、宛先がすべてループバックだと読み切れない curl に `ask` を返し、それ以外は無出力。**git push guard と同じ向き**: フックは `allow` を返さず、`Bash(curl:*)` も `permissions.ask` に置かない — Claude Code 2.1.285 ではフックの `allow` が ask ルールに負ける(`docs/adr/0009-command-guard-hooks-gate-without-allow.md`)。フックが死ぬと curl の確認は外れる(フェイルオープン)。認識のホワイトリスト・curlrc・対象外のホスト・受容した残存は `.claude/rules/curl-localhost-guard.md`。

**Automated security alert handling** — `.github/workflows/security-alerts.yml` runs a weekly Saturday sweep (schedule) and supports manual dispatch (`gh workflow run security-alerts.yml`). Uses `claude-code-action` to analyze all open security alerts (Dependabot, code scanning, secret scanning) and either auto-fix (low-risk Dependabot/code scanning → PR) or escalate (high-risk/secret scanning → issue with `security` label).

**Scheduled workflow failure alerting** — The scheduled workflow
(`security-alerts.yml`) ends with an `if: failure()` step calling the local composite
action `.github/actions/harness-issue-alert`, which creates (or comments on) an issue
deduplicated by exact title. This prevents silent scheduled failures (an expired
`CLAUDE_CODE_OAUTH_TOKEN` once caused 401 failures for a month unnoticed). Any new
scheduled workflow must include the same step; the alerting steps need `issues: write`
permission.

**Harness self-improvement loop** — Local-only, PR-gated. A SessionEnd hook
(`harness-reflect-trigger.sh`) records substantial sessions (>= 10 assistant turns) to
`~/.claude/harness/pending.jsonl` — deterministic, no LLM. Claude Code's `/harness-reflect`
slash command extracts learnings from the current session and pending transcripts into
`~/.claude/harness/queue.md`. Claude Code's `/harness-review` (nudged by the SessionStart briefing when
overdue >7 days) runs `harness-doctor.sh`, triages the queue against existing rules, and
opens one PR per run; humans review and merge — no auto-apply. Runtime state in
`~/.claude/harness/` is chezmoi-ignored; only rule changes are version-controlled. All
monitoring is deterministic shell — the briefing prints a status line every session, so
silence itself signals a dead hook. Design:
`docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`.
人の起動に頼らないよう、抽出と選別(採用があれば draft PR まで)は launchd の週次ジョブでも回る(ADR 0012。plist は `private_Library/LaunchAgents/local.dotfiles.harness-weekly.plist.tmpl`、入口は `dot_claude/scripts/executable_harness-weekly.sh`)。入口スクリプトは nono の内側から書けるので、nono はスクリプトの中ではなく plist で掛ける。起動方法・heartbeat・lock・予算は `.claude/rules/harness-weekly.md`。
ループの PR は Guarded Path(Evaluator と改善ループ自身。ADR 0011)を変えられない: ブランチ名が `harness/review-` で始まる PR(ループが PR を作る手順がこの名前を指定し、人の PR は使わない)が `scripts/guarded-paths.txt` のパスに触れると、`just check-guarded-paths` が CI で落とす。判定の詳細と残存リスクは `scripts/check-guarded-paths.sh` のヘッダ。

**Harness sync seam (`harness/`)** — Claude Code / Codex / Cursor / APM の harness 設定を Harness Manifest から検証・同期する repo-only ツール(#308 の基盤、#309)。`bash harness/bin/harness.sh check` が runtime の Capability Probe と Target の drift を報告し、`sync` が Atomic Sync(staging → 全体検証 → 置換)で Target を更新する。`--no-probe` を付けると Capability Probe を飛ばして Target の drift だけを見る(製品が入っていない CI 用。省略したことは出力に必ず出る)。`init` / `update` は未実装(#322 / #323)。`harness/` は `.chezmoiignore` で除外され `~/` には配置されない。manifest は 2 つある: `harness/manifest.json` はグローバル用で **runtime 宣言のみ、`targets` は空のまま**(グローバル指示は harness ではなく chezmoi テンプレートが合成する。`.claude/rules/global-agent-instructions.md` と ADR 0005 を参照)、`harness/project.json` はこのリポジトリを Managed Project として扱うもので、下の「Generated agent instructions」の 3 Target を持つ。adapter は `harness/adapters/<owner>.sh render <staging-file> <target-json>` の契約で追加する。設計: `docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md`

**Generated agent instructions (`CLAUDE.md` / `AGENTS.md` / `.cursor/rules/dotfiles.mdc`)** — この 3 ファイルは**生成物**であり、直接編集してはいけない。Source は `harness/modules/` の Content Module 群で、`harness/project.json` が「どの Target がどのモジュールを、どの順で持つか」を宣言する。`just harness-sync` で再生成し、`just check-instructions`(`just lint` と CI に組み込み済み)が手編集を drift として検出する。分割の原則は **「このリポジトリについての事実」= `harness/modules/project/` の共有モジュール / 「あなた(この製品)がここでどう動くか」= `harness/modules/runtime/` の Runtime Extension**。`dot_claude/` や `~/.claude/` への言及も、リポジトリの中身の説明であるかぎり共有側に置く(Codex がこのリポジトリを編集するのに必要な事実だから)。Cursor は project root の `AGENTS.md` をネイティブに読むので、`.cursor/rules/dotfiles.mdc` には Cursor 固有の記述だけを置き、共有内容を二重にロードさせない(`docs/adr/0004-cursor-project-instructions-via-agents-md.md`)。**Codex は `AGENTS.md` を `project_doc_max_bytes`(既定 32 KiB)で黙って切り捨てる**(`codex debug prompt-input` で実測)。生成後の `AGENTS.md` は 32 KiB を超えるので、`AGENTS.md` の `modules` だけ順序が違う: Runtime Extension を先頭に置き、この「Key Patterns」モジュールを末尾に置いて、**切り捨てが 1 つの宣言されたモジュールの内側で起きる**ようにしてある。並びを変えるときはこの不変条件を壊さないこと(`test/harness-instructions.bats` が強制する)。設計: `docs/superpowers/specs/2026-09-12-project-instruction-sync-design.md`

**Global agent instructions (`~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`)** — グローバル指示は `harness/` を通らず、chezmoi テンプレートだけで合成する(ADR 0005)。合成の構成・rules の取り込み方・検査は `.claude/rules/global-agent-instructions.md`(その rule の `paths` に挙げたファイルを扱うときだけ読み込まれる)。

**Autonomous review (`review-verify`)** — 入口 skill `dot_claude/skills/review-verify/` が Workflow `dot_claude/workflows/review-verify.js` を起動し、既存のブランチにレビュー修正ループと動作確認だけをかける。実装・push・PR の作成はしない(実装の段を持っていた Deliver を廃止した理由は ADR 0019)。ループの判定はコードで行う(ADR 0007、`just test-review-verify`)。ループの設計は `docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`。
