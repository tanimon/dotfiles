# ECC 最小導入への切り替え 設計

- 日付: 2026-09-24
- 状態: 承認済み(対話で合意)

## 背景と目的

`ecc@ecc`(affaan-m/ECC 2.2.2)を native plugin として丸ごと有効化しており、skill 292 / command 94 / agent 68 / hook 24 系統が常に読み込まれている。

直近 30 日のトランスクリプト(1,555 ファイル)の実測:

| 観点 | 実測値 |
|---|---|
| ECC skill/command の利用 | `ecc:code-review` 354 回(無人ループ `pr-review-automation-loop` 経由)。それ以外は各 2 回以下 |
| ECC agent の利用 | `vue-reviewer` / `php-reviewer` / `security-reviewer` / `pr-test-analyzer` が各 1 回 |
| hook エラー | `hook_non_blocking_error` 33,545 件。ほぼ全件 `/bin/sh: node: command not found` |
| 有害な注入 | SessionStart の `Active instincts:`(`session-start.js`)が、2026-07 に廃止した学習パイプラインの残骸として「`dangerouslyDisableSandbox: true` を常に付けよ」等をコンテキストに入れ続けている |

`pluginUsage["ecc@ecc"].usageCount`(16 万超)は hook の発火回数であり、利用実績ではない。

目的: ECC の hook を全廃し、skill/agent 一覧によるコンテキスト圧迫を解消する。実際に使っているものだけを残し、無人ループは壊さない。

## 選択的インストールの選択肢と不採用理由

| 方式 | 不採用理由 |
|---|---|
| plugin を残し `userConfig.hooks_enabled=false` | hook は止まるが、`plugin.json` が `skills/` `commands/` をディレクトリごと読み込むため一覧の圧迫が残る |
| ECC の `install.sh`(`--skills` / `--modules` / `--config` / `--no-hooks`) | 粒度が module 単位。dry-run で `--skills tdd-workflow` が skill 48 個・113 ファイルを書き込んだ。command は `commands-core` で 94 個一括。`~/.claude/` への直接書き込み・独自 `install-state.json`・node 依存があり、chezmoi の宣言的管理と衝突する |
| ローカル plugin「ecc」で名前を維持 | 外部変更は不要になるが、marketplace の手動登録と plugin cache へのコピーが挟まり、仕組みが一段増える |

採用: `.chezmoiexternal.toml` で ECC リポジトリを SHA 固定の archive として取り込み、必要なファイルだけを配置する(既存の gstack と同じ方式、Renovate で自動更新)。

## 残すもの

| 配置先(`~/` 相対) | 取り込み元(archive 内) | 方式 |
|---|---|---|
| `.claude/commands/ecc-code-review.md` | `commands/code-review.md` | `type = "archive-file"`(1 ファイルを抽出してリネーム) |
| `.claude/agents/{vue-reviewer,php-reviewer,security-reviewer,pr-test-analyzer}.md` | `agents/` の同名 4 ファイル | `type = "archive"` + `include` + `stripComponents` |
| `.claude/rules/typescript/*.md`(5 ファイル) | `rules/typescript/` | 同上 |
| `.claude/rules/web/*.md`(7 ファイル) | `rules/web/` | 同上 |

- URL は 4 エントリとも `https://github.com/affaan-m/ECC/archive/<sha>.tar.gz` にそろえ、直後に `# renovate: branch=main` を置く(`.claude/rules/renovate-external.md` の隣接契約)。`renovate.json` の regex は変更しない。
- `ecc-code-review` にリネームする理由: user command を `code-review` にすると組込みの `code-review` skill と名前が衝突するため。また、plugin を外すと `ecc:` 名前空間は消える。
- `code-review.md` は他ファイルへの参照を持たない。`vue-reviewer` は `skills/vue-patterns` を参照するが、参照先が無くても動作する。
- `rules/typescript` と `rules/web` は `../common/*.md` を extends とリンクしている。common を撤去するとリンク切れになるが、中身は各ファイルで自己完結しているので許容する。

## 撤去するもの

- `dot_claude/settings.json.tmpl`
  - `enabledPlugins["ecc@ecc"]` と `extraKnownMarketplaces.ecc`
  - env の `ECC_DISABLED_HOOKS` / `ECC_CONTEXT_MONITOR_COST_WARNINGS` / `CLV2_CONFIG` と、それぞれの説明コメント
- `dot_claude/continuous-learning-config.json`(`CLV2_CONFIG` の参照先)
- `.chezmoiscripts/run_onchange_after_install-ecc-rules.sh.tmpl` と `dot_claude/ecc-rules-languages.txt`
- 配置済みで chezmoi 管理外のコピーを `.chezmoiremove` に**bare entry**で追加する(`path/**` は socket で apply が落ちる既知の落とし穴)
  - `.claude/rules/common/` の ECC 由来 10 ファイル: `agents.md` `code-review.md` `coding-style.md` `development-workflow.md` `git-workflow.md` `hooks.md` `patterns.md` `performance.md` `security.md` `testing.md`
  - `.claude/rules/golang`(現在使っていない)
  - `.claude/continuous-learning-config.json`
  - 自前の `documentation-language.md` / `github-actions.md` / `harness-engineering.md` / `shell-scripting.md` は Source 管理なので残る
- `~/.local/share/ecc-homunculus`(instinct データ)は plugin を外せば読まれなくなる。chezmoi 管理外のランタイムデータなので本変更では触らず、手動削除はユーザー判断とする

## ドキュメントの追従

- `harness/modules/` 内の ECC 記述を更新し、`just harness-sync` を実行する(`CLAUDE.md` / `AGENTS.md` は生成物)
  - `35-key-patterns.md` の「Global agent instructions」の段落: ECC rules を apply 時にコピーしているという説明
  - `50-pitfalls.md`: ecc plugin 改名の例
- `.claude/rules/renovate-external.md`: 「Existing Entries」の記述(gstack のみ)
- `dot_claude/rules/common/` は変更しないので、`dot_codex/AGENTS.md.tmpl` の `include` 列挙と 32 KiB 制約は影響を受けない

## 他リポジトリとの連動(順序制約)

`<work-org>/sandbox` の `skills/ai-code-review/SKILL.md` と QA 項目系 skill の `SKILL.md`、および `automation/pr-review-automation-loop/README.md` が `ecc:code-review` の名前で呼んでいる。これを `/ecc-code-review` に書き換える PR を別途作る。

**その PR がマージされるまで、本変更をマージ後に `chezmoi apply` しない。** 先に apply すると無人ループのレビューが失敗する。逆順(sandbox 側を先にマージ)でも、apply するまでは名前が一致しない。したがって「両 PR をマージ → 直後に apply」を 1 つの手順として扱う。

## 検証

1. `chezmoi managed --source "$(pwd)"` と `chezmoi apply --dry-run --source "$(pwd)"` で、external の配置予定が 1 + 4 + 5 + 7 = 17 ファイルちょうどであることを確認する。ECC の他ファイルが混入していないことも見る(ブランチは `--source` なしだと main を見て空振りする)
2. `archive-file` の `path` と `stripComponents` の組み合わせは実測で確定する(archive のトップディレクトリ名 `ECC-<sha>` が SHA 更新で変わっても壊れない指定にする)
3. `just lint`(`check-instructions` / `scan-sensitive` / `test-global-instructions` を含む)
4. apply 後に新しいセッションを開き、対照ペアで確認する(変更前の数値は上表)
   - `hook_non_blocking_error` の `node: command not found` が 0 件
   - `Active instincts:` が注入されない
   - skill 一覧に `ecc:` が無く、`/ecc-code-review` と agent 4 つが見える
5. `claude -p "/ai-code-review <PR URL>"` 相当で、無人ループの 1 件が完走する(sandbox 側 PR マージ後)
