---
title: "APMのSkill/プラグイン管理をネイティブClaude Codeマーケットプレイスに巻き戻し、名前空間分離を回復"
date: 2026-08-10
category: tooling-decisions
module: "Claude Codeプラグイン/Skill管理(APM vs ネイティブmarketplace)"
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "Claude Code の Skills/Plugins を複数マーケットプレイスから配布・管理する必要があるとき"
  - "同名Skillの衝突やプラグインごとの名前空間分離が必要なとき"
  - "chezmoi等のdotfiles管理でsettings.jsonの所有権が競合する構成を検討するとき"
  - "APM(microsoft/apm)のdependencies.apmでSkill/Pluginを管理するかどうかを判断するとき"
symptoms:
  - "APM経由でインストールしたSkillが~/.claude/skills/<name>/SKILL.mdにフラットに展開され、プラグイン間で名前空間が分離されない"
  - "同名Skillがプラグイン間で衝突し、どちらのプラグイン由来か判別できない"
root_cause: config_error
resolution_type: config_change
related_components: [development_workflow, documentation]
tags: [apm, claude-code, plugins, marketplace, skills, chezmoi, renovate]
---

# APMのSkill/プラグイン管理をネイティブClaude Codeマーケットプレイスに巻き戻し、名前空間分離を回復

> **実装状況について**: この決定に基づくファイル変更は `dot_apm/apm.yml` / `dot_claude/settings.json.tmpl` / `.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl`（`run_after_apm-install.sh.tmpl`からリネーム）/ `renovate.json` / `.claude/rules/renovate-external.md` / `CLAUDE.md` の6ファイルに対し、このリポジトリの機能ブランチ `investigate-apm-marketplace-plugin`（worktree: `~/orca/workspaces/chezmoi/escolar`）上で実施済み。ただし本ドキュメント作成時点ではまだコミット・PRのいずれも作成されていない、作業ツリー上の未コミット変更である。

## Context

このリポジトリは APM（microsoft/apm）を使い、`dot_apm/apm.yml` の `dependencies.apm` に git-shorthand 参照（`owner/repo[/subpath]#ref`）を列挙することで Claude Code の Skill/プラグインを宣言的に管理していた（2026-08-03 のコミット `1d96d00`「APM(microsoft/apm)によるSkill/MCP管理の一本化」#260 で導入）。この方式は `apm install --global --target claude` を通じて Skill を `~/.claude/skills/<name>/SKILL.md` に**フラットに**展開する。実際に `ls ~/.claude/skills` を確認すると、`accessibility`・`agent-eval`・`ai-code-review` のように、どのプラグインが提供した Skill なのかを示すディレクトリ階層は存在せず、すべて単一階層に並ぶ。

ユーザーはこのフラットな配置を「不便」と感じていた。Skill 名が衝突しうるうえ、あるSkillがどのプラグイン由来かが名前からしか分からない。ここで最初に立てた仮説は「`apm.yml` の `dependencies.apm` の宣言形式を git-shorthand からマーケットプレイス形式（`name`/`marketplace` オブジェクト）に変えれば、プラグインごとに名前空間分離されるのではないか」というものだった。

この仮説は誤りだった。`docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md` の「Claude Code ターゲットへの展開先」節は次のように明記している。

```
- Claude Code ターゲットへの展開先:
  - skills → ~/.claude/skills/<name>/SKILL.md
```

この展開先は宣言形式（git-shorthand か marketplace 形式か）に関わらず無条件に適用される。つまり `dependencies.apm` の書き方を変えても、APM が Skill をフラット配置する挙動そのものは変わらない。この点は、APM のマーケットプレイス形式参照がインストール時にエラーになるという別の制約（`1d96d00` のコミットログに記録されている実機検証結果）とは独立した、別の理由でボツになった仮説である。

一方、Claude Code 自身が持つネイティブのプラグイン/マーケットプレイス機構（APM とは無関係に、`~/.claude/plugins/cache/`・`~/.claude/plugins/marketplaces/`・`~/.claude/plugins/installed_plugins.json`・`~/.claude/plugins/known_marketplaces.json` として今も存在する。いずれもホームディレクトリ配下のランタイム状態で、このリポジトリのファイルではない）は、プラグインごとに Skill を名前空間分離する。実機で確認したところ、`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/` という階層でプラグイン単位に Skill が配置されており（例: `~/.claude/plugins/cache/compound-engineering-plugin/compound-engineering/3.21.0/skills`、`~/.claude/plugins/cache/claude-plugins-official/superpowers/6.2.0/skills`）、Skill ツール自体の呼び出し規約も `plugin:skill`（例: `/commit-commands:commit`）とプラグイン名を含む形式になっている。

## Guidance

セッション中に `claude-code-guide` サブエージェントへ独立調査を依頼し、公式ドキュメントを引きながら次の2点を確認した。

1. Skill の名前空間分離は APM の宣言形式の問題ではなく、**Skillのデプロイ先の仕組みそのもの**の違いによる。APM は常にフラット展開、ネイティブのプラグインローダーは常にプラグイン単位のディレクトリに展開する。
2. `extraKnownMarketplaces` を `settings.json` に書くだけではマーケットプレイスは自動フェッチ・クローンされない。`claude plugin marketplace add <owner/repo>`（または project-scoped-trust 文脈でのインタラクティブな trust プロンプト）を、マーケットプレイスごとに最低1回明示的に実行する必要がある。これは「`enabledPlugins`/`extraKnownMarketplaces` を宣言するだけで自己完結する」というユーザーの当初の想定と直接矛盾する事実だった。

この2つの調査結果を踏まえ、Skill/プラグイン管理をネイティブのマーケットプレイス機構に巻き戻す作業を行った。以下が実際に変更された内容。

- **`dot_apm/apm.yml`**: `dependencies.apm` セクション（9件の git-shorthand プラグイン参照）を全削除。残るのは `dependencies.mcp` のみ（`code-review-graph` / `codex` / `deepwiki` の3 MCP サーバー定義）。
- **`dot_claude/settings.json.tmpl`**: `permissions` ブロックの直後に `enabledPlugins` と `extraKnownMarketplaces` のブロックを新設。
- **`.chezmoiscripts/run_after_apm-install.sh.tmpl`**（このセッションでリネームにより削除済み、現在は存在しない）→ **`.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl`** にリネーム。ファイル先頭のコメントも「毎回のapplyで実行する（run_onchange_ではない）」という旧説明から、「apm.yml hash: {{ include "dot_apm/apm.yml" | sha256sum }}」というハッシュゲート方式の説明に置き換えた。
- **`renovate.json`**: `dependencies.apm` 用の3つの custom regex manager（`git-refs` ベースの digest 追跡・`compound-engineering-v*` prefix 追跡・`v*` タグ追跡）と、対応する `packageRules` エントリを削除。残るのは `.chezmoiexternal.toml` 用の1つの custom manager のみ。
- **`.claude/rules/renovate-external.md`**: 「Renovate Contract — dot_apm/apm.yml (`dependencies.apm`)」節の見出しに「廃止済み（2026-08-10）」を追記し、歴史的記録として残した旨の注記を追加。
- **`CLAUDE.md`**: `dot_apm/apm.yml` の Key Patterns 説明、ディレクトリレイアウト表、Known Pitfalls の該当項目を、この巻き戻し後の状態に合わせて全面的に書き直した。

## Why This Matters

このセッションで最終的に受け入れたトレードオフは次の通りである。

**得たもの**: Skill のプラグイン単位の名前空間分離。`plugin:skill` という呼び出し名により、どのプラグインが提供する Skill かが常に明確になり、Skill 名の衝突も原理的に起きなくなる（衝突するとしても `plugin` 単位までスコープが絞られる）。

**再び受け入れたリスク**: `enabledPlugins` の `plugin@marketplace` キーは、上流でプラグインまたはマーケットプレイスの名前が変わると静かにマッチしなくなり、エラーも警告もなく Hook・Agent が動かなくなる。これは実際に一度発生した既知の障害モード（ecc ↔ everything-claude-code のリネーム、[harness-silent-failures-scheduled-workflows-and-plugin-rename.md](../integration-issues/harness-silent-failures-scheduled-workflows-and-plugin-rename.md) に詳細記録あり）であり、まさにこれが理由で 2026-08-03 の #260 で APM への一本化が行われた。ユーザーはこのリスクを「知った上で再度受け入れる」という選択をした。

**あえて自動化しなかったもの**: マーケットプレイス登録の自動化。#260 以前は `marketplaces.txt` + `run_onchange_after_add-marketplaces.sh.tmpl` という自動登録スクリプトが存在した（[chezmoi-declarative-marketplace-sync-over-bidirectional.md](../integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md) 参照）。今回の巻き戻しではこれを復元せず、新規マシンでの `claude plugin marketplace add <owner/repo>` を**手動・一度だけ**行う運用にした。

判断の決め手になったのは、Skill の名前空間分離そのものよりも「**3ファイル/仕組みの並存から1ファイルへの単純化**」がユーザーの明示的な要望だった点である。#260 が APM 一本化を選んだ理由の一つも「MCP サーバー管理・マーケットプレイス登録・プラグイン有効化が3つの別々のファイル/仕組みに分散していたこと」への対応だった。今回の巻き戻しでも同じ単純化の軸は守られており、「マーケットプレイス登録の自動化スクリプトを追加しない」という判断は、名前空間分離の対価として複雑さを増やさないための選択である。つまりこれは「フラットだが自動で名前空間分離されず安全」から「名前空間分離されるが既知のリネーム破損モードと新規マシンでの手動ブートストラップコストを持つ、ただしファイルは1つ」への交換である。

副次的な単純化として、`dependencies.apm` が空になったことで、APM がchezmoi所有の `settings.json.tmpl` に Skill フックを直接書き込む競合が消滅した。`.chezmoiscripts/run_after_apm-install.sh.tmpl` が「`apm.yml` が変化しなくても毎 apply で無条件実行する」必要があったのは、まさにこの Hook 書き込み競合を解消するためだった（[run-after-vs-run-onchange-for-shared-config-ownership.md](../architecture-patterns/run-after-vs-run-onchange-for-shared-config-ownership.md) 参照）。今 `apm.yml` に残るのは MCP サーバー定義のみで、その展開先は `~/.claude.json`（chezmoi が `.tmpl` として所有していないファイル。ただし本リポジトリの CLAUDE.md Known Pitfalls が既に注記している通り、このファイルのトポロジー（symlink か通常ファイルか）は過去に変化しており、今回もその前提を検証済みの事実として扱わず、変化しうるものとして扱う）であるため、競合する完全所有テンプレートはもう存在しない。したがってスクリプトはハッシュゲート方式の `run_onchange_after_apm-install.sh.tmpl` に戻すだけで十分になった。

## When to Apply

この判断が再び関係してくる場面は次の通り。

- **新しいプラグインを追加するとき**: `dependencies.apm` に git-shorthand を足すのではなく、`dot_claude/settings.json.tmpl` の `enabledPlugins` に `<plugin>@<marketplace>` キーを追加し、そのマーケットプレイスが未知なら `extraKnownMarketplaces` にも source（`{"source": "github", "repo": "owner/repo"}` 形式）を追加する。
- **新規マシンをオンボードするとき**: `chezmoi apply` だけでは `extraKnownMarketplaces` に列挙したマーケットプレイスは自動的にはフェッチされない。各マーケットプレイスについて一度だけ `claude plugin marketplace add <owner/repo>` を手動実行する必要がある（例: `claude plugin marketplace add anthropics/claude-plugins-official`、`claude plugin marketplace add EveryInc/compound-engineering-plugin`）。これを忘れると `enabledPlugins` のキーは解決できずプラグインが有効化されない。
- **プラグインやマーケットプレイスが上流でリネームされたとき**: `enabledPlugins` のキーが静かにマッチしなくなる既知のリスクが発生する。`claude plugin list` または `~/.claude/plugins/installed_plugins.json` を見て、期待するプラグインが実際にアクティブか確認する。
- **APM の Skill デプロイ挙動が将来変わり、名前空間分離をサポートするようになった場合**: そのときは今回の判断（ネイティブマーケットプレイスへの巻き戻し）の前提そのものが崩れるため、再度 APM 一本化に戻す選択肢を検討し直す価値がある。今回「APM は宣言形式に関わらずフラット展開する」と確認したのは 2026-08-10 時点の挙動であり、恒久的な制約ではない。

## Examples

**`dot_apm/apm.yml` — `dependencies.apm` の削除（before/after）**

Before（`1d96d00` 時点、9件のプラグイン参照。以下のSHAはこのリポジトリではなく各プラグインの上流リポジトリ〔obra/superpowers、anthropics/claude-plugins-official、getsentry/plugin-claude、nolabs-ai/nono-packs〕上のコミットを指す、簡略表記のため末尾を省略している）:
```yaml
dependencies:
  mcp:
    - name: code-review-graph
      # ...
  apm:
    - obra/superpowers#v6.2.0
    - anthropics/claude-plugins-official/plugins/commit-commands#a473e6e8...
    - anthropics/claude-plugins-official/plugins/ralph-loop#a473e6e8...
    - anthropics/claude-plugins-official/plugins/claude-md-management#a473e6e8...
    - anthropics/claude-plugins-official/plugins/skill-creator#a473e6e8...
    - getsentry/plugin-claude#4b61acc2...
    - EveryInc/compound-engineering-plugin#compound-engineering-v3.21.0
    - affaan-m/everything-claude-code#v2.1.0
    - nolabs-ai/nono-packs/claude#58f77c73...
```

After:
```yaml
dependencies:
  mcp:
    - name: code-review-graph
      # ...
    - name: codex
      # ...
    - name: deepwiki
      # ...
  # dependencies.apm は完全に削除。MCPサーバー定義のみが残る。
```

**`dot_claude/settings.json.tmpl` — `enabledPlugins`/`extraKnownMarketplaces` の新設**

`permissions` ブロックの直後に追加されたブロック:
```jsonc
{{/* nono@nolabs-ai: the nono pack (nolabs-ai/nono-packs/claude) writes this key into
   ~/.claude/settings.json at install/pull time via its own directory-sourced
   marketplace registration (~/.claude/plugins/marketplaces/nolabs-ai), not via
   extraKnownMarketplaces below. ... Skills/plugins here are managed via Claude Code's
   native marketplace mechanism (not APM) — new machines require running
   `claude plugin marketplace add <owner/repo>` once per marketplace listed in
   extraKnownMarketplaces before enabledPlugins can resolve; this is a deliberate
   manual step, not automated. */ -}}
"enabledPlugins": {
  "nono@nolabs-ai": true,
  "superpowers@claude-plugins-official": true,
  "commit-commands@claude-plugins-official": true,
  "ralph-loop@claude-plugins-official": true,
  "claude-md-management@claude-plugins-official": true,
  "skill-creator@claude-plugins-official": true,
  "sentry@claude-plugins-official": true,
  "compound-engineering@compound-engineering-plugin": true,
  "ecc@ecc": true,
  "cclens@cclens": true
},
"extraKnownMarketplaces": {
  "claude-plugins-official": {
    "source": { "source": "github", "repo": "anthropics/claude-plugins-official" }
  },
  "compound-engineering-plugin": {
    "source": { "source": "github", "repo": "EveryInc/compound-engineering-plugin" },
    "autoUpdate": true
  },
  "ecc": {
    "source": { "source": "github", "repo": "affaan-m/everything-claude-code" },
    "autoUpdate": true
  },
  "cclens": {
    "source": { "source": "github", "repo": "lambdalisue/cclens" }
  }
}
```

`nono@nolabs-ai` に対応する `extraKnownMarketplaces` エントリが**存在しない**点に注意。これは意図的な仕様である。`~/.claude/plugins/known_marketplaces.json` の `nolabs-ai` エントリを確認すると `"source": {"source": "directory", ...}` となっており、GitHub リポジトリではなく `nono` CLI の `pull`/`update` コマンドが副作用として作るローカルディレクトリソースのマーケットプレイスであるため、`enabledPlugins` のフラグだけで十分に機能する。

**`run_after_` → `run_onchange_` へのリネーム理由**

Before（`.chezmoiscripts/run_after_apm-install.sh.tmpl` の先頭コメント）:
```bash
# 毎回のapplyで実行する(run_onchange_ではない): apmが書き込むSkillのフックは
# ~/.claude/settings.json内にあり、chezmoiがsettings.json.tmplで同ファイルを
# 完全管理しているため、apm.ymlが変化しないapplyでもフックが消えないよう
# 毎回再同期する必要がある。
```

After（`.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl` の先頭コメント）:
```bash
# apm.yml hash: {{ include "dot_apm/apm.yml" | sha256sum }}
#
# dependencies.apm (Skill/plugin管理)はネイティブmarketplace方式
# (settings.json.tmplのenabledPlugins/extraKnownMarketplaces)に移行済みのため、
# apm.ymlにはdependencies.mcpのみが残る。MCPサーバーの展開先は~/.claude.jsonの
# mcpServersキーで、chezmoiはこのファイルを.tmplとして所有していない(競合する
# 完全所有テンプレートが存在しない)ため、apm.ymlのハッシュ変化時のみ実行すれば
# 十分(run_after_ではなくrun_onchange_で問題ない)。
```

この2つのコメントの違いがこの決定の本質を要約している。「無条件で毎回実行しなければならない」という制約は、APM が Skill フックを chezmoi 完全所有ファイルに書き込むことに起因していた。`dependencies.apm` を削除した結果、その書き込み対象自体がなくなったため、`run_after_` から通常のハッシュゲート `run_onchange_` に戻すことができた。

## Related

- [harness-silent-failures-scheduled-workflows-and-plugin-rename.md](../integration-issues/harness-silent-failures-scheduled-workflows-and-plugin-rename.md) — `enabledPlugins`のリネーム破損リスクについての既存の実害記録。今回再受容したリスクの根拠
- [chezmoi-declarative-marketplace-sync-over-bidirectional.md](../integration-issues/chezmoi-declarative-marketplace-sync-over-bidirectional.md) — 今回あえて復元しなかった`marketplaces.txt`+`run_onchange_`自動登録パターンの記録
- [run-after-vs-run-onchange-for-shared-config-ownership.md](../architecture-patterns/run-after-vs-run-onchange-for-shared-config-ownership.md) — 同じPR #260系譜の隣接する教訓（`run_after_`/`run_onchange_`の選択基準）
- [ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md](../integration-issues/ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md) — ネイティブプラグインの3層ライフサイクル（登録/インストール/有効化）モデル
- `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md` — 今回部分的に巻き戻した元の移行設計
