# rulesync の一次ソース調査(#308 harness 同期との比較)

日付: 2026-09-16
対象: [dyoshikawa/rulesync](https://github.com/dyoshikawa/rulesync) の checkout `af9187f4bc16907a01530746633fa4b9992a9d04`(v16.33.0、2026-09-15 リリース)
比較先: `harness/`(#308 / #309 / #310)、`docs/adr/0001-harness-semantic-core-with-runtime-adapters.md`、`docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md`、`docs/superpowers/specs/2026-09-12-project-instruction-sync-design.md`

本書は**事実のみ**を記録する。推奨・判断は含めない。引用は `(path:L範囲 @ af9187f4)` の形で、rulesync リポジトリ内の相対パスを指す。一次ソースで確認できなかった事項は「未検証」と明記し、末尾の節に集約した。

## 調査の問い

1. Claude Code / Codex CLI / Cursor の機能サポート行列(rules / mcp / commands / subagents / skills / permissions / hooks)。project モードと `--global` モードを分け、出力ファイルパスを確定する。「Codex の project モードは rules / ignore のみ」という表と、「Codex permissions は `.codex/config.toml` + `.codex/rules/rulesync.rules` を書く」という主張の矛盾を解く。
2. permissions の翻訳セマンティクス。`.rulesync/permissions.jsonc` のスキーマ、3 製品それぞれで何が落ちる・弱まるか。Cursor は `ask` を捨てるか、Codex に `ask` はあるか、`deny` はハード deny のままか、project 側が global 側を緩められるか。
3. hooks の翻訳。`.rulesync/hooks.jsonc` のスキーマ、イベント名の対応表、対応が無いイベントの扱い、`preserveUnownedHooks` と `.rulesync-hooks-lock.json`、stdin/stdout 契約の翻訳有無。
4. 共有ファイルの所有。`~/.claude/settings.json` / `.claude/settings.json` / `~/.codex/config.toml` で rulesync が書くキー、merge か overwrite か、未管理キーとコメントの保持、chezmoi テンプレートとの相互作用、書き込みの原子性、途中失敗時の部分書き込み。
5. rules の出力順序と `AGENTS.md`。連結順の制御、`root: true` の意味、特定モジュールを **末尾** に固定できるか、Cursor の `.mdc` frontmatter をファイル単位で制御できるか。
6. drift / CI モード。`rulesync generate` のフラグ、`--check` の終了コードと違反ファイルの名指し、`--delete` が rulesync 由来でないファイルを消すか。
7. ツールのバージョン / capability 検査の有無。
8. MCP。source 形式、3 製品の出力先(project / global)、`~/.claude.json` へのマージの有無(APM との衝突)。
9. プロジェクト健全性。直近 6 か月のコミッター数、リリース頻度、open issue 数、semver / 安定性ポリシー、Node 要件、依存数、ライセンス。
10. `import` コマンド(参考のみ)。

## 1. 機能サポート行列(Claude Code / Codex CLI / Cursor)

**結論:** 現在の checkout では、Codex の project モードは rules / mcp / subagents / skills / hooks / permissions を**サポートする**(commands は global のみ、ignore は非対応)。「Codex project は rules/ignore のみ」という表は本 checkout の生成表と一致せず、一次ソースからは確認できない(未検証)。permissions の Codex 出力が `.codex/config.toml` と `.codex/rules/rulesync.rules` の 2 ファイルであることはコードで確定した。

- サポート表は各 processor の `getToolTargets()` / `getToolTargets({ global: true })` から**生成**される。手書きではない (scripts/generate-supported-tools-tables.ts:L42-L51 @ af9187f4)。
- 生成された表の Codex 行: rules ✅🌏 / ignore 空 / mcp ✅🌏🔧 / commands 🌏 / subagents ✅🌏 / skills ✅🌏 / hooks ✅🌏 / permissions ✅🌏(✅ = project、🌏 = global) (docs/reference/supported-tools.md:L16, L59-L63 @ af9187f4)。
- Codex commands は `supportsProject: false, supportsGlobal: true`。`getSettablePaths` は global 以外で throw する (src/features/commands/commands-processor.ts:L309-L319 @ af9187f4; src/features/commands/codexcli-command.ts:L71-L78 @ af9187f4)。
- Codex permissions は processor が `CodexcliPermissions`(config.toml)と `createCodexcliBashRulesFile`(rulesync.rules)の**2 つの ToolFile** を返す (src/features/permissions/permissions-processor.ts:L717-L726 @ af9187f4)。
- Cursor rules は `supportsGlobal: false`。Cursor に global の rules 出力は無い (src/features/rules/rules-processor.ts:L644-L652 @ af9187f4)。

### 出力パス(outputRoot が project では cwd、global では `~`)

| 機能 | Claude Code | Codex CLI | Cursor |
|---|---|---|---|
| rules(root) | project: `CLAUDE.md` / global: `~/.claude/CLAUDE.md` (src/features/rules/claudecode-rule.ts:L76-L112) | project: `AGENTS.md` / global: `~/.codex/AGENTS.md` (src/features/rules/codexcli-rule.ts:L52-L64) | root 概念なし。全 rule が `.cursor/rules/<name>.mdc` (src/features/rules/cursor-rule.ts:L53-L64, L310-L322) |
| rules(non-root) | `.claude/rules/*.md`(project / global とも) (src/features/rules/claudecode-rule.ts:L83-L111) | root ファイルに**連結(fold)** (src/features/rules/rules-processor.ts:L535-L544) | `.cursor/rules/*.mdc`(project のみ) |
| mcp | project: `.mcp.json` / global: **`~/.claude.json`** (src/features/mcp/claudecode-mcp.ts:L51-L62; src/constants/claudecode-paths.ts:L46-L47) | `.codex/config.toml` の `mcp_servers`(project / global 同じ相対パス) (src/features/mcp/codexcli-mcp.ts:L504-L511) | `.cursor/mcp.json`(project / global 同じ相対パス) (src/features/mcp/cursor-mcp.ts:L55-L60) |
| commands | `.claude/commands/*.md` (src/features/commands/claudecode-command.ts:L62-L66) | global のみ `~/.codex/prompts/*.md` (src/features/commands/codexcli-command.ts:L71-L78) | `.cursor/commands/*.md` (src/features/commands/cursor-command.ts:L65-L69) |
| subagents | `.claude/agents/*.md` (src/features/subagents/claudecode-subagent.ts:L72-L76) | `.codex/agents/*.toml` (src/features/subagents/codexcli-subagent.ts:L76-L80; src/features/subagents/subagents-processor.ts:L278-L288) | `.cursor/agents/*.md` (src/features/subagents/cursor-subagent.ts:L57-L61) |
| skills | `.claude/skills/<name>/SKILL.md` (src/features/skills/claudecode-skill.ts:L434-L443) | `.agents/skills/<name>/`(global は `~/.agents/skills/`) (src/features/skills/codexcli-skill.ts:L188-L198) | `.cursor/skills/<name>/` (src/features/skills/cursor-skill.ts:L86-L94) |
| permissions | `.claude/settings.json`(project / global 同じ相対パス) (src/features/permissions/claudecode-permissions.ts:L921-L926) | `.codex/config.toml` + `.codex/rules/rulesync.rules` (src/features/permissions/codexcli-permissions.ts:L121-L126, L341-L353) | project: `.cursor/cli.json` / global: `~/.cursor/cli-config.json` (src/features/permissions/cursor-permissions.ts:L358-L368) |
| hooks | `.claude/settings.json` の `hooks` (src/features/hooks/claudecode-hooks.ts:L78-L82) | `.codex/hooks.json`、加えて `.codex/config.toml` の `features` テーブルも触る (src/features/hooks/codexcli-hooks.ts:L145-L147, L82-L114, L150-L153) | `.cursor/hooks.json`(project / global 同じ相対パス) (src/features/hooks/cursor-hooks.ts:L41-L51) |

(表内の引用はいずれも `@ af9187f4`)

- 各 processor の project / global 可否は factory の `meta.supportsProject` / `meta.supportsGlobal` で宣言される。permissions は Claude / Codex / Cursor とも両方 true (src/features/permissions/permissions-processor.ts:L139-L150, L161-L172, L246-L257 @ af9187f4)。hooks も 3 製品とも両方 true (src/features/hooks/hooks-processor.ts:L310-L322, L324-L338, L354-L366 @ af9187f4)。mcp も同様 (src/features/mcp/mcp-processor.ts:L212-L222, L264-L274, L362-L372 @ af9187f4)。
- global モードの outputRoot は `getHomeDirectory()`(`HERMES_HOME` 等の tool home 環境変数があるツールのみ上書き。Claude / Codex / Cursor には該当なし) (src/utils/tool-home.ts:L11-L21 @ af9187f4; docs/reference/cli-commands.md:L266-L270 @ af9187f4)。

## 2. permissions の翻訳セマンティクス

**結論:** source は `permission.<category>.<glob>: allow|ask|deny` の 3 値。Claude Code は 3 値を `permissions.allow/ask/deny` の配列にそのまま写す。Codex は bash を `prefix_rule(decision = allow|prompt|forbidden)` に 3 値で写すが、filesystem(read/edit/write)は `deny < read < write` の 1 軸に潰され(`ask` は deny 側に倒れる)、network の `ask` は**警告付きで捨てる**。Cursor は `allow` / `deny` のみで、**`ask` は警告付きで捨てる**。project が global を緩めることを止める機構は無い(両モードは独立した実行で、相互参照コードが無い)。

### source スキーマ

- アクションは `z.enum(["allow", "ask", "deny"])` (src/types/permissions.ts:L9 @ af9187f4)。
- 形は `permission: { <category>: { <pattern>: <action> } }`。空白のみの category / pattern は reject (src/types/permissions.ts:L32-L62 @ af9187f4)。
- category は `bash`, `read`, `edit`, `write`, `webfetch`, `websearch`, `grep`, `glob`, `notebookedit`, `agent`, 全ツール `*`, `mcp__<server>__<tool>` (docs/reference/file-formats.md:L1478 @ af9187f4)。
- ツール別 override `{toolname}.permission` は category 単位で共有ブロックを**丸ごと置換**する (src/features/permissions/rulesync-permissions.ts:L177-L234 @ af9187f4)。
- `claudecode` override は `permissions`(`defaultMode`, `additionalDirectories` 等)と `sandbox`、さらに任意の settings.json トップレベルキーを passthrough する。ただし `hooks` / `$schema` と、コマンドを実行するキー(`statusLine`, `apiKeyHelper` 等)は書かない (src/types/permissions.ts:L216-L260 @ af9187f4; src/features/permissions/claudecode-permissions.ts:L647-L658 @ af9187f4)。
- `codexcli` override は `approval_policy`, `sandbox_mode`, `sandbox_workspace_write`, `apps`, `approvals_reviewer`, `tui` のみ許可。それ以外のキー(`permissions`, `mcp_servers` 含む)は警告付きで skip (src/constants/codexcli-paths.ts:L24-L31 @ af9187f4; src/features/permissions/codexcli-permissions.ts:L901-L912 @ af9187f4)。
- `cursor` override は `approvalMode` と `sandbox` で、global 限定(project では警告付き skip) (src/types/permissions.ts:L296-L326 @ af9187f4)。

### Claude Code への翻訳

- category → ツール名(`bash→Bash`, `read→Read`, `edit→Edit`, `write→Write`, `webfetch→WebFetch`, `websearch→WebSearch`, `grep→Grep`, `glob→Glob`, `notebookedit→NotebookEdit`, `agent→Agent`)。エントリは `Tool(pattern)` 形 (src/features/permissions/claudecode-permissions.ts:L44-L55, L888 @ af9187f4)。
- `allow` / `ask` / `deny` はそれぞれの配列にそのまま入る。落ちるアクションは無い (src/features/permissions/claudecode-permissions.ts:L1233-L1243 @ af9187f4)。
- 全ツール `*` category は `*(pattern)` として書かれるが Claude Code はどのツールにも一致させないので**実質無効**。警告が出る (src/features/permissions/claudecode-permissions.ts:L1213-L1221, L1248-L1254 @ af9187f4)。
- 既存 `settings.json` とのマージ: 管理対象ツール名のエントリは置換、管理対象外ツール名のエントリは保持。同名エントリが別リストにあれば今回のリストへ移動 (src/features/shared/shared-config-gateway.ts:L2119-L2157 @ af9187f4)。

### Codex CLI への翻訳

- `bash`: `.codex/rules/rulesync.rules` に `prefix_rule(pattern=[tokens], decision=..., justification=...)`。decision は `allow→"allow"`, `ask→"prompt"`, `deny→"forbidden"`。**3 値とも保持** (src/features/permissions/codexcli-permissions.ts:L1123-L1175 @ af9187f4)。
- `read` / `edit` / `write`: `[permissions.rulesync]` プロファイルの `filesystem` テーブル。Codex は `deny < read < write` の 1 軸で `ask` を持たない。同一パターンに複数アクションがあれば厳しい方(`deny > ask > allow`)が勝ち、`read: allow` 以外はすべて `"deny"` になる。「書けるが読めない」は表現できず `"deny"` に落として警告 (src/features/permissions/codexcli-permissions.ts:L1027-L1032, L1037-L1068, L1108-L1118 @ af9187f4)。
- `webfetch`: `network.domains` に `allow|deny`。**`ask` は警告を出して skip**。`*: deny` も Codex が config 読み込みで reject するため skip (src/features/permissions/codexcli-permissions.ts:L362-L380 @ af9187f4)。
- 生成プロファイルは常に `extends` で `:workspace`(既定)または `:read-only` を継承し、`default_permissions = "rulesync"` を書く。`:danger-full-access` を選ぶとプロファイル自体を生成せず filesystem / network ルールは無視される (docs/reference/file-formats.md:L1606, L1619 @ af9187f4)。
- `approval_policy` と `approvals_reviewer` が override にも既存ファイルにも無い場合、**`on-request` / `auto_review` を既定値として config.toml に書き込む** (src/features/permissions/codexcli-permissions.ts:L925-L937 @ af9187f4)。
- `rulesync init` が雛形として書く `codexcli` ブロックは `base_permission_profile: ":danger-full-access"` (docs/reference/file-formats.md:L1468 @ af9187f4)。

### Cursor への翻訳

- category → `Shell` / `Read` / `Write`(`edit` も `Write` に統合)/ `WebFetch` / `Mcp`。`cli.json` の `permissions` は `allow` / `deny` のみの型 (src/features/permissions/cursor-permissions.ts:L47-L54, L161-L173 @ af9187f4)。
- **`ask` は警告を出して skip する**(「Cursor CLI permissions do not support the "ask" action. Skipping …」) (src/features/permissions/cursor-permissions.ts:L561-L586 @ af9187f4)。
- 既存ファイルとのマージ: 管理対象 type のエントリは置換、それ以外の type のエントリと `permissions` 配下の未知キーは保持 (src/features/permissions/cursor-permissions.ts:L412-L459 @ af9187f4)。

### deny の強度と「tighten only」

- Claude: `permissions.deny` 配列。Codex: bash は `forbidden`、filesystem は `"deny"`、network は `domains.<host> = "deny"`。Cursor: `permissions.deny`。いずれも各製品のネイティブな deny 表現であり、rulesync 側で approval prompt に格下げする分岐は無い(前掲各引用)。
- project と global の比較・「緩めることを拒否する」コードは permissions-processor / generate に**存在しない**。`grep -rnE 'tighten|relax|globalConfig|loosen|widen' src/features/permissions/permissions-processor.ts src/lib/generate.ts` は 0 件。`getToolTargets` も `global` フラグで独立に分岐するだけ (src/features/permissions/permissions-processor.ts:L733-L742 @ af9187f4)。
- Kilo 向けには「project は tighten のみ」という**製品側の制約**を rulesync が模倣するコメントがあるが、Claude / Codex / Cursor 向けにそのような処理は無い (src/types/permissions.ts:L195-L202 @ af9187f4)。

## 3. hooks の翻訳

**結論:** source は canonical な camelCase イベント名をキーにした `hooks: { <event>: [HookDefinition] }` で、ツール別 `{toolname}.hooks` override を持つ。翻訳は**イベント名の写像とフィールドの選別**のみで、stdin JSON / 終了コード / stdout の契約は一切翻訳しない。対応の無いイベントは**警告を出して出力から落とす**(エラーにはならない)。`preserveUnownedHooks` は既定 false で、false のときは対象ファイルの `hooks` キーを**生成内容で丸ごと置換**する。true にすると `.rulesync-hooks-lock.json` に前回生成分を記録し、そこに無いハンドラは第三者のものとして残す。

### source スキーマ

- トップレベル `hooks` のキーは `HOOK_EVENTS`(52 種)に限定され、未知のイベント名は parse 時に reject (src/types/hooks.ts:L159-L215, L1314-L1323, L1327-L1329 @ af9187f4)。
- ツール別 override(`claudecode.hooks`, `codexcli.hooks`, `cursor.hooks` 等)は緩いスキーマで、イベント名の検証は行わない (src/types/hooks.ts:L1297, L1330-L1339 @ af9187f4)。
- `HookDefinition` は `command`, `type`(`command|prompt|http|agent|mcp_tool|function`), `timeout`, `matcher`, `enabled`, `prompt`, `async`, `env`, `shell`, `failClosed` 等の looseObject (src/types/hooks.ts:L32-L70 @ af9187f4)。
- source と Cursor のイベント名は同一(camelCase)。Claude / Codex は PascalCase へ写像 (src/types/hooks.ts:L1376, L1489, L1717 @ af9187f4)。

### イベント対応表(canonical → 各製品。— は非対応)

| canonical | Claude Code | Codex CLI | Cursor |
|---|---|---|---|
| `sessionStart` | `SessionStart` | `SessionStart` | `sessionStart` |
| `sessionEnd` | `SessionEnd` | `SessionEnd` | `sessionEnd` |
| `preToolUse` | `PreToolUse` | `PreToolUse` | `preToolUse` |
| `postToolUse` | `PostToolUse` | `PostToolUse` | `postToolUse` |
| `postToolUseFailure` | `PostToolUseFailure` | — | `postToolUseFailure` |
| `beforeSubmitPrompt` | `UserPromptSubmit` | `UserPromptSubmit` | `beforeSubmitPrompt` |
| `stop` | `Stop` | `Stop` | `stop` |
| `stopFailure` | `StopFailure` | — | — |
| `stopCancelled` | — | `Interrupt` | — |
| `subagentStart` / `subagentStop` | `SubagentStart` / `SubagentStop` | 同左 | `subagentStart` / `subagentStop` |
| `preCompact` / `postCompact` | `PreCompact` / `PostCompact` | 同左 | `preCompact` のみ |
| `permissionRequest` | `PermissionRequest` | `PermissionRequest` | — |
| `notification` | `Notification` | — | — |
| `setup`, `worktreeCreate`, `worktreeRemove`, `messageDisplay`, `instructionsLoaded`, `userPromptExpansion`, `postToolBatch`, `permissionDenied`, `taskCreated`, `taskCompleted`, `teammateIdle`, `configChange`, `cwdChanged`, `fileChanged`, `directoryAdded`, `elicitation`, `elicitationResult` | あり | — | — |
| `beforeShellExecution`, `afterShellExecution`, `beforeMCPExecution`, `afterMCPExecution`, `beforeReadFile`, `afterFileEdit`, `afterAgentResponse`, `afterAgentThought`, `beforeTabFileRead`, `afterTabFileEdit`, `workspaceOpen` | — | — | あり |

- 表の根拠: 公式の event × tool 行列 (docs/reference/file-formats.md:L293-L420 @ af9187f4)、および定数 `CLAUDE_HOOK_EVENTS` / `CODEXCLI_HOOK_EVENTS` / `CURSOR_HOOK_EVENTS` (src/types/hooks.ts:L248-L282, L565-L588, L218-L240 @ af9187f4)。
- このリポジトリの `dot_claude/settings.json.tmpl` が使う `Notification` と `StopFailure` は Claude Code のみ対応。Codex / Cursor へは写せない(上表)。

### 非対応イベントと非対応 hook type の扱い

- processor が `supportedEvents` に無いイベント名を集め、`Skipped hook event(s) for <tool> (not supported): …` の**警告**を出す。エラーにはならず、そのイベントは出力に含まれない (src/features/hooks/hooks-processor.ts:L154-L165, L1070-L1078 @ af9187f4)。
- Cursor は `command` と `prompt` 以外の type を落とす。Codex は `command` のみ (src/features/hooks/cursor-hooks.ts:L80-L110 @ af9187f4; src/features/hooks/hooks-processor.ts:L320, L364 @ af9187f4)。

### 入出力契約

- hooks ディレクトリで `tool_input` / `hook_event_name` / `stdin` を扱うのは Cline 用の生成器だけ。Claude / Codex / Cursor 向けにはペイロードや終了コードの翻訳は無い (`grep -rnE 'tool_input|hook_event_name|stdin' src/features/hooks` の非テスト該当は `cline-hooks-generator.ts` と `cline-hooks.ts` のみ @ af9187f4)。
- 翻訳されるのはイベント名と、`command` / `matcher` / `timeout` / `async` 等のフィールド名(ツール別 converter config) (src/features/hooks/codexcli-hooks.ts:L41-L66 @ af9187f4; src/features/hooks/cursor-hooks.ts:L98-L114 @ af9187f4)。

### `preserveUnownedHooks` と lock ファイル

- 設定キーは `rulesync.jsonc` の `preserveUnownedHooks`(既定 false) (src/config/config.ts:L130 @ af9187f4; src/features/hooks/hooks-processor.ts:L942 @ af9187f4)。
- false のときは `hooks: generatedHooks` をそのまま返す。つまり既存の `hooks` キーは**生成内容で置換**される (src/features/hooks/preserve-unowned-hook-commands.ts:L58-L75 @ af9187f4)。
- true のとき、前回生成分を `<dir>/.rulesync-hooks-lock.json`(`.claude/`, `.codex/`, `.cursor/` それぞれ)に `{ lockfileVersion: 1, owned: [{event, matcher, identity}] }` で記録し、lock に無いハンドラは第三者として保持、lock にあって今回生成されないものは撤回する。lock が無い初回は何も撤回しない (src/features/hooks/hooks-ownership-lock.ts @ af9187f4; src/features/hooks/settings-json-hooks.ts:L156-L186 @ af9187f4; src/features/hooks/codexcli-hooks.ts:L192-L215 @ af9187f4)。
- Claude の `settings.json` では `hooks` キーは gateway の `replace-owned-keys` として宣言されている (src/features/shared/shared-config-gateway.ts:L1322 @ af9187f4)。

## 4. 共有ファイルの所有

**結論:** rulesync は共有ファイルを**read-modify-write** する(既存内容を読み、所有キーだけ差し替え、他のキーは保持)。JSON(`.claude/settings.json`)と TOML(`.codex/config.toml`)は**再シリアライズ**されるため**コメントは失われ、キー順も rulesync のシリアライザに従う**(コメント保持は JSONC の一部ファイルのみで、Claude / Codex は対象外)。書き込みは `fs.writeFile` の**直接書き込み**で temp+rename ではない。生成は feature 単位・target 単位に逐次書き込み、途中で throw した場合は以降のステップが走らず、書いた分はそのまま残る(ロールバックは無い)。

### `.claude/settings.json` / `~/.claude/settings.json`

- 宣言された writer と所有キー: `ignore`(custom、`permissions.deny` の `Read(...)`)、`hooks`(`hooks` キー置換)、`permissions`(custom `applyPermissions`)、`rules`(`language` キー置換)。加えて gateway が `$schema` を必ず付与する(`ensuredKeys`) (src/features/shared/shared-config-gateway.ts:L1309-L1326 @ af9187f4)。
- permissions は既存ファイルを読み(無ければ `{}`)、`JSON.parse` → マージ → `serializeSharedConfigFile`。`claudecode` override の `permissions` 非リスト項目は既存 `permissions` に shallow merge、`sandbox` は deep merge、その他トップレベルキーは deep merge (src/features/permissions/claudecode-permissions.ts:L945-L1000, L1066-L1082 @ af9187f4)。
- `allow` / `ask` / `deny` 配列: 管理対象ツール名のエントリは置換、それ以外は保持、空配列はキー削除、結果はソート (src/features/shared/shared-config-gateway.ts:L2119-L2157 @ af9187f4)。
- コマンド実行系キー(`statusLine` 等)は rulesync が override から**書かない**だけである。既存ファイル側の同キーはフィルタの対象外で、`settings = deepMergeRecords(settings, scopedTopLevel)` のベースとして残る(フィルタ `stripUnhonoredTopLevelKeys` は override 側にしか掛からない) (src/features/permissions/claudecode-permissions.ts:L647-L658, L952-L956, L1035-L1054 @ af9187f4)。
- 形式は `json`。コメント保持の対象(`.vscode/settings.json`, `.amp/settings.json`, `opencode.json` 等)に `.claude/settings.json` は**含まれない**。「JSON, YAML, TOML は従来どおり再シリアライズされる」 (docs/reference/cli-commands.md:L278-L282 @ af9187f4; src/features/shared/shared-config-gateway.ts:L1309-L1312 @ af9187f4)。
- 空ペイロードなら新規作成しない(既存があれば常に書き直す) (docs/reference/cli-commands.md:L272-L276 @ af9187f4; src/types/feature-processor.ts:L97-L108 @ af9187f4)。

### `~/.codex/config.toml` / `.codex/config.toml`

- writer と所有キー: `hooks` → `features`、`mcp` → `mcp_servers`、`permissions` → `permissions`, `default_permissions`, `approval_policy`, `sandbox_mode`, `sandbox_workspace_write`, `apps`, `approvals_reviewer`, `tui`。形式 `toml` (src/features/shared/shared-config-gateway.ts:L1783-L1793 @ af9187f4)。
- `smol-toml` で parse → patch → stringify。コメントは残らない (src/features/mcp/codexcli-mcp.ts:L549-L556, L627-L635 @ af9187f4; docs/reference/cli-commands.md:L282 @ af9187f4)。
- permissions は `[permissions.rulesync]` を既存プロファイルとマージし(未管理キーは保持)、`default_permissions = "rulesync"` を設定する。ファイルは削除対象外(`isDeletable` false) (src/features/permissions/codexcli-permissions.ts:L128-L130, L226-L262 @ af9187f4)。
- hooks feature も同じ `config.toml` に触り、`features.codex_hooks` を消す (src/features/hooks/codexcli-hooks.ts:L82-L114 @ af9187f4)。

### chezmoi 再レンダリングとの関係(事実のみ)

- rulesync は毎回 live ファイルを読み直してベースにする(前掲 L952, L549)。したがって chezmoi が live を再レンダリングして rulesync の書いたキーを消しても rulesync 側はエラーにせず、次の `generate` で再度差し込む。逆に rulesync の書き込みは chezmoi から見ると target の drift になる。この相互作用を扱うコードは rulesync に無い(`grep -rni chezmoi src docs README.md` = 0 件 @ af9187f4)。

### 書き込みの原子性と途中失敗

- 書き込みは `ensureDir` → `writeFile(filepath, content, "utf-8")` の直接書き込み。temp+rename では無い (src/utils/file.ts:L346-L349 @ af9187f4)。
- `runWithDirectoryRollback`(バックアップ + 復元)は `src/lib/sources.ts`(`fetch` / `install` の取り込み)でのみ使われ、`generate` の書き込みには使われない (`grep -rn runWithDirectoryRollback src` 非テスト該当は `src/utils/file.ts` と `src/lib/sources.ts` のみ @ af9187f4)。
- `generate` はステップ(ignore → mcp → commands → subagents → skills → hooks → checks → permissions → rules)を**逐次実行**し、各ステップが target × outputRoot ごとに `writeAiFiles` で即時書き込む。あるステップの throw は以降のステップと削除 sweep をすべて止めるが、既に書いたファイルは残る (src/lib/generate.ts:L632-L660, L858-L867 @ af9187f4; src/types/feature-processor.ts:L86-L144 @ af9187f4)。
- 同じ共有ファイルを書く 2 ステップは `dependsOn` で順序を固定しなければ起動時に throw する(ステップ間の read-modify-write 競合の防止) (src/lib/generate.ts:L537-L560 @ af9187f4)。
- 単一ファイル feature(mcp / hooks / permissions / ignore)の source が壊れていると、その feature は出力せず、他の feature は走った上で非 0 終了。`rules` / `commands` / `skills` の frontmatter エラーは即 abort (docs/reference/cli-commands.md:L195-L218 @ af9187f4)。

## 5. rules の出力順序と `AGENTS.md`

**結論:** rule の読み込み順は `.rulesync/rules/**/*.md` の**パス文字列ソート**(`toSorted()`)で、frontmatter や設定で順序を指定する手段は無い。Codex(`codexcli`)は `collisionPolicy: "fold"` で、root rule を先頭に、残りの non-root rule をソート順で `\n\n` 連結して 1 つの `AGENTS.md` にする。**特定モジュールを末尾に置く指定は、ファイル名(パス)のソート順で作るしかない**。`root: true` は「その rule の本文が root ファイル(CLAUDE.md / AGENTS.md)になる」フラグ。同じ出力パスに複数の rule が集まった場合、fold / compose の target、または集まった rule が**すべて root** なら(Claude Code の `CLAUDE.md` に `root: true` が 2 つある場合を含む)ソート順で連結され、root と非 root が非 fold target の同一パスに衝突したときだけ reject される。Cursor の `.mdc` frontmatter は rule ごとに `cursor.alwaysApply` / `description` / `cursor.globs` で制御できる。

- 発見は `findFilesByGlobs("**/*.md", { cwd: <tree>/rules })`。結果は実ファイル単位で重複除去後 `representatives.toSorted()` で返る (src/features/rules/rules-processor.ts:L2121-L2124 @ af9187f4; src/utils/file.ts:L780-L863 @ af9187f4)。
- frontmatter: `root`, `localRoot`, `targets`(既定 `["*"]`), `description`, `globs`, ツール別ブロック(`agentsmd.subprojectPath`, `claudecode.paths`, `cursor.{alwaysApply,description,globs}` 等) (src/features/rules/rulesync-rule.ts:L30-L92 @ af9187f4; docs/reference/file-formats.md:L15-L80 @ af9187f4)。
- Codex は root / non-root を問わず**同じ出力パス**(`AGENTS.md`)に写す (src/features/rules/codexcli-rule.ts:L87-L103 @ af9187f4)。
- 同一出力パスに複数 rule が集まると `mergeRulesByOutputPath` が処理する。`fold` では root rule(あれば)を先頭、以降は入力順(= ソート順)で `trim()` 後に `"\n\n".join`。連結条件は `(fold || compose || 全員 root) && 全断片が frontmatter 無し`。この条件を満たさず、かつ衝突に source 側 `root: true` が含まれると throw する (src/features/rules/rules-processor.ts:L1600-L1670 @ af9187f4)。
- 後続 target が fold target の root ファイルを別内容で上書きしたことを検出する監視がある (src/lib/fold-root-overwrite-watch.ts:L1-L40 @ af9187f4)。
- Claude Code は `ruleDiscoveryMode: "auto"`: root は `CLAUDE.md`、non-root は `.claude/rules/<name>.md` に個別出力し、`claudecode.paths`(無ければ `globs`)を frontmatter `paths` として書く。CLAUDE.md への参照節は入らない (src/features/rules/rules-processor.ts:L120-L127, L474-L484 @ af9187f4; src/features/rules/claudecode-rule.ts:L236-L272 @ af9187f4)。
- Cursor `.mdc`: `alwaysApply` → `description`(YAML scalar)→ `globs`(引用符なし、カンマ区切り)の順で frontmatter を組む。`alwaysApply: true` かつ globs が `**/*` 等の全域なら `globs` 行を省く。frontmatter が無い `.mdc` は Cursor に無視されるという前提で必ず `---` ブロックを出す (src/features/rules/cursor-rule.ts:L90-L160, L269-L291, L294-L322 @ af9187f4)。
- 全 rule のパス衝突(大文字小文字無視)は警告 (src/features/rules/rules-processor.ts:L1680-L1700 @ af9187f4)。
- `project_doc_max_bytes` や 32 KiB 切り捨てに関する処理・言及は rulesync のソースおよび docs に**存在しない**(`grep -rn project_doc_max_bytes src docs README.md` = 0 件 @ af9187f4)。

## 6. drift / CI モード

**結論:** `rulesync generate` は `--targets` / `--features` / `--delete` / `--output-roots` / `--global` / `--input-roots` / `--dry-run` / `--check` / `--watch` / `--simulate-*` / `--config` を持つ。`--check` は `--dry-run` と同じ計算をし、差分があれば `Files are not up to date.` で**exit 1**。差分のあるファイルは `[DRY RUN] Would write: <path>` / `[DRY RUN] Would delete: <path>` の info ログで名指しされる。`--delete` は「生成ディレクトリにあって source から生成されないファイル」を消す。つまり rulesync が過去に作ったかどうかは見ず、その run で生成対象にならなかったファイルを orphan として消す(ただし hidden ファイル・symlink・共有設定ファイルは対象外)。`--base-dir` は存在せず(`grep -rn baseDir src/config src/cli` = 0 件)、`--output-roots`(出力側)と `--input-roots`(source 側)が別々にある。

- フラグ定義 (src/cli/program.ts:L276-L332 @ af9187f4; docs/reference/cli-commands.md:L145-L158 @ af9187f4)。
- `--check`: `config.getCheck()` が true かつ `result.hasDiff` なら `CLIError(GENERATION_FAILED)`。削除だけの差分でも fail する (src/cli/commands/generate.ts:L144, L227-L237 @ af9187f4; docs/guide/dry-run.md:L13-L19 @ af9187f4)。
- `--dry-run` と `--check` は併用不可、`--watch` とも併用不可 (docs/guide/dry-run.md:L24 @ af9187f4; src/cli/program.ts:L320-L323 @ af9187f4)。
- 差分判定は `fileContentsEquivalent` で、既存ファイルと生成内容の等価比較。dry-run 時は `[DRY RUN] Would write: <path>` を出してカウント (src/types/feature-processor.ts:L110-L142 @ af9187f4)。
- `--delete` の sweep は全ステップ完了後に遅延実行され、その run が書いた・書く予定のパスは除外。単一ファイル feature の source 読み込みに失敗した feature は sweep しない (src/lib/orphan-sweep.ts:L1-L45 @ af9187f4; src/lib/generate.ts:L140-L160, L863-L869 @ af9187f4)。
- orphan 判定は「`loadToolFiles({ forDeletion: true })` で列挙された既存ファイル」−「今回生成したファイル」。大文字小文字は同一視 (src/types/feature-processor.ts:L157-L185 @ af9187f4)。
- 公式説明: 「What is swept is unchanged: a file in a generated directory that no `.rulesync/` source produces」。skill ディレクトリ内の hidden ファイルと symlink は消さない (docs/reference/cli-commands.md:L160-L192 @ af9187f4)。
- 共有ファイル(`.claude/settings.json`, `.codex/config.toml`, global の `~/.claude.json`)は `isDeletable()` false で `--delete` の対象外 (src/features/permissions/codexcli-permissions.ts:L128-L130 @ af9187f4; src/features/mcp/claudecode-mcp.ts:L32-L41 @ af9187f4)。
- `rulesync doctor` は `rulesync.jsonc` の静的検査のみ(未知キー、非対応 target 名、`$schema` 等)。生成物の drift は見ない (docs/reference/cli-commands.md:L616-L635 @ af9187f4)。

## 7. ツールのバージョン / capability 検査

**結論:** rulesync は対象ツール(claude / codex / cursor)のインストール有無・バージョン・capability を**一切検査しない**。`minVersion` に相当する概念も無い。外部コマンドを起動するのは `git --version`(`fetch` 用の git クライアント検出)だけである。

- `child_process` / `execFile` の非テスト利用は `src/lib/git-client.ts` のみで、対象は `git` (src/lib/git-client.ts:L1, L75 @ af9187f4)。
- `--version` 文字列の出現は自身のバージョン表示と自己更新メッセージのみ (src/cli/program.ts:L48 @ af9187f4; src/lib/update.ts:L568 @ af9187f4)。
- 各ツールの挙動差(例: Codex `sessionEnd` は 0.145.0 で追加、`Interrupt` は 0.150.0)はソースコメントに記録されているが、実行時に確認する処理は無い (src/types/hooks.ts:L565-L588 @ af9187f4)。
- `doctor` の検査項目は設定ファイルの構造に限られる (docs/reference/cli-commands.md:L622-L635 @ af9187f4)。

## 8. MCP

**結論:** source は `.rulesync/mcp.jsonc` の `mcpServers`(+ `{toolname}.mcpServers` のツール別ブロック)。Claude Code は project で `.mcp.json`、**global で `~/.claude.json`** を read-modify-write し、`mcpServers` キーを**生成内容で丸ごと置換**する(他のトップレベルキーは保持)。Codex は `.codex/config.toml` の `mcp_servers` を置換(同名サーバーの `tools` テーブルだけ既存から引き継ぐ)。Cursor は `.cursor/mcp.json` の `mcpServers` を置換。

- source 形式 (docs/reference/file-formats.md:L1107-L1150 @ af9187f4)。
- Claude global の出力先は `.claude.json`(`relativeDirPath: "."` + outputRoot = `~`)。`~/.claude/.claude.json` は legacy として読み取りフォールバックのみ (src/features/mcp/claudecode-mcp.ts:L51-L62, L43-L49, L89-L100 @ af9187f4; src/constants/claudecode-paths.ts:L46-L47 @ af9187f4)。
- 書き込みは `{ ...json, mcpServers: rulesyncMcp.getMcpServers() }`。既存 `mcpServers` に rulesync 未定義のサーバーがあれば**消える** (src/features/mcp/claudecode-mcp.ts:L142 @ af9187f4)。
- global の `~/.claude.json` は削除対象外(`isDeletable` false)。「hooks, user settings, model selection 等を含む Claude 自身の設定」と認識されている (src/features/mcp/claudecode-mcp.ts:L32-L41 @ af9187f4)。
- Codex: `mcp_servers` は gateway の `replace-owned-keys`。既存サーバーの `tools`(承認状態)だけ引き継ぐ。サーバー名は `[a-zA-Z0-9_-]+` に正規化 (src/features/mcp/codexcli-mcp.ts:L600-L635 @ af9187f4; docs/reference/file-formats.md:L1238 @ af9187f4)。
- Cursor: `{ ...json, mcpServers: transformedServers }`(`${VAR}` を `${env:VAR}` に変換) (src/features/mcp/cursor-mcp.ts:L116-L128 @ af9187f4)。
- このリポジトリの `dot_apm/apm.yml`(APM)が書く先も `~/.claude.json` の `mcpServers` であり、rulesync の global mcp と**同一キーを 2 つの writer が置換する**関係になる(rulesync 側に APM を考慮する処理は無い)。

## 9. プロジェクト健全性

**結論:** 直近 6 か月(2026-03-16 以降)のコミットは約 3,300 件、コミッターは 54 アカウントだが、上位 2 アカウント(`dyoshikawa`, `cm-dyoshikawa`)が約 88% を占める。リリースは v16.x で**ほぼ毎日**(直近 30 日で 28 タグ)。open issue 44 件、open PR 4 件。semver / 互換性ポリシーを明文化した文書は見つからない。Node `>=22`、runtime 依存 18 個、unpacked 約 16.4 MB、MIT。

- コミッター(2026-03-16 〜 2026-09-16、`gh api repos/dyoshikawa/rulesync/commits?since=…`): `dyoshikawa` 1,466、`cm-dyoshikawa` 1,441、`saitota` 74、`dependabot[bot]` 42、`sirmacik` 34、その他。distinct 54、合計 3,312 コミット。`dyoshikawa` / `cm-dyoshikawa` / `dyoshikawa-claw` が同一人物の別アカウントかは**未検証**(GitHub API の `name` は前者が `dyoshikawa`、後者は null)。
- リリース: 2026-08-18 の v16.14.0 から 2026-09-15 の v16.33.0 まで 28 タグ(`gh api repos/dyoshikawa/rulesync/releases`)。`package.json` の version は `16.33.0` (package.json:L3 @ af9187f4)。
- open issue 44 / open PR 4 / stars 1,426 / created 2025-06-18 / license MIT(`gh api repos/dyoshikawa/rulesync`、`search/issues`)。
- semver / breaking change / 安定性の方針: `README.md`, `CONTRIBUTING.md`, `GOVERNANCE.md`, `SECURITY.md`, `docs/**/*.md` を `semver|breaking|stability|major` で grep して該当なし。`GOVERNANCE.md` は Owner が全決定権を持つ単独オーナー体制を明記 (GOVERNANCE.md:L1-L25 @ af9187f4)。CHANGELOG ファイルは無い(リポジトリ直下一覧 @ af9187f4)。
- `engines`: `node >=22.0.0`, `pnpm >=10` (package.json:L155-L158 @ af9187f4)。
- runtime `dependencies` 18 個(`zod`, `effect`, `fastmcp`, `@modelcontextprotocol/sdk`, `@octokit/rest`, `smol-toml`, `jsonc-parser`, `js-yaml`, `gray-matter`, `globby`, `commander` 等) (package.json:L87-L106 @ af9187f4)。
- npm の `dist.unpackedSize` = 16,427,540 bytes、`dist.fileCount` = 18(`npm view rulesync@16.33.0`)。
- 表・docs の一部はコードから生成され CI で差分検査される(`check:supported-tools`, `check:docs-content`) (package.json:L52-L54 @ af9187f4)。

## 10. `import` コマンド(参考)

**結論:** `rulesync import --targets <tool>` は各ツールのネイティブ設定(`CLAUDE.md`, `.claude/settings.json`, `.codex/config.toml`, `.cursor/rules/*.mdc` 等)を読んで `.rulesync/` の canonical 形式に**逆変換**する双方向機能。本リポジトリは ADR 0001 で一方向(Source → Target)を採用しているため使用しない。

- `import` は `--global` と `--targets` を取り、各 processor の `loadToolFiles` → `convertToolFilesToRulesyncFiles` を呼ぶ (src/cli/program.ts:L175-L200 @ af9187f4; src/lib/import.ts:L1-L30 @ af9187f4)。
- 逆変換は非可逆な箇所がある(Codex のサーバー名正規化、Codex の `.git/**` 既定ルールは import しない、Cursor の `edit` は `write` に統合、fold 済み root の再 import は重複を生む) (docs/reference/file-formats.md:L1238 @ af9187f4; src/features/permissions/codexcli-permissions.ts:L60-L86 @ af9187f4; src/features/permissions/cursor-permissions.ts:L56-L67 @ af9187f4; src/features/rules/rules-processor.ts:L2407-L2425 @ af9187f4)。

## #308 との対応表

`gh issue list --repo tanimon/dotfiles --search harness` の #311〜#325。判定は本書の事実に基づく機能面の対応のみ(採否の判断ではない)。

| Issue | タイトル | 判定 | 理由 |
|---|---|---|---|
| #311 | feat(harness): synchronize global instructions for Claude Code and Codex | 部分的 | `--global` で `~/.claude/CLAUDE.md` + `~/.claude/rules/*.md` と `~/.codex/AGENTS.md` を生成できる(§1)。ただし連結順はパスソート固定で、Codex 32 KiB 切り捨てを意識した「特定モジュールを末尾」はファイル名で作る必要がある(§5)。Cursor の global rules は非対応(§1) |
| #312 | feat(harness): distribute MCP dependencies to three explicit APM targets | rulesync では不可 | rulesync の Claude global MCP は `~/.claude.json` の `mcpServers` を丸ごと置換し、APM と同一キーを競合する(§8)。APM を Dependency Plane とする ADR 0001 の前提(lock / provenance / audit)を rulesync は持たない |
| #313 | feat(harness): distribute collision-free standalone Skills through APM | 部分的 | rulesync は `.rulesync/skills/*/SKILL.md` を `.claude/skills/`, `.agents/skills/`, `.cursor/skills/` に配布できる(§1)が、APM 経由ではなく、名前衝突の検査は rulesync 内の出力パス衝突警告に限られる |
| #314 | refactor(harness): expand Claude permissions into shared Risk Tier policy | 部分的 | canonical `permission` は allow/ask/deny × category × glob で、Claude へは無損失に写る(§2)。ただし Risk Tier / Enforcement Grade の概念は無く、`permissions.ask` に「留めるべき」という不変条件を表現・検査する機構も無い(§2「tighten only」) |
| #315 | feat(harness): enforce shared Risk Tier policy in Codex | 部分的 | bash は `prefix_rule` で 3 値保持、filesystem は `ask` が deny 側へ潰れ、network の `ask` は捨てられる(§2)。Codex の `approval_policy` 既定値を rulesync が書き込む副作用がある(§2) |
| #316 | feat(harness): enforce shared Risk Tier policy in Cursor | 部分的 | Cursor は `allow` / `deny` のみで **`ask` を警告付きで捨てる**(§2)。「Safety Invariant は同等以上の Enforcement Grade にしか写せない」(ADR 0001)を rulesync は検査しない |
| #317 | refactor(harness): contract legacy permission ownership | 部分的 | `.claude/settings.json` の `permissions.allow/ask/deny` は管理対象ツール名のエントリだけ置換し、それ以外は保持する(§4)。所有の境界は「ツール名」単位で、Target Owner 1 つの原則(ADR 0001)とは粒度が異なる |
| #318 | feat(harness): verify Isolation Boundaries and credential handling | rulesync では不可 | nono / native sandbox の境界検証に相当する機能は無い。`claudecode.sandbox` の passthrough は設定の書き込みであって検証ではない(§2) |
| #319 | feat(harness): deliver notifications through one Portable Hook | rulesync では不可 | `notification` / `stopFailure` イベントは Claude Code のみ対応で Codex / Cursor へは写せない(§3)。stdin / 終了コードの契約翻訳も無い(§3) |
| #320 | feat(harness): share post-edit formatting and secret checks | 部分的 | `postToolUse` は 3 製品とも対応(§3)。ただし matcher の意味・stdin ペイロードは翻訳されず、Cursor は `afterFileEdit` という別イベントも持つ(§3) |
| #321 | feat(harness): unify the self-improvement lifecycle across runtimes | rulesync では不可 | `sessionEnd` は 3 製品対応だが(§3)、`~/.claude/harness/` の状態管理・briefing・queue は rulesync の範囲外 |
| #322 | feat(harness): enroll a new Managed Project explicitly | 部分的 | `rulesync init` が `rulesync.jsonc` と `.rulesync/` を作るが、ターゲット自動検出を伴い、「明示登録のみ・未登録リポジトリを走査しない」(ADR 0001)の enroll 記録・drift 承認 state は無い(§6) |
| #323 | feat(harness): make APM dependency updates reviewable | rulesync では不可 | APM の lock / provenance を扱わない。rulesync 自身の `sources` lock(`rulesync install`)は skill / rule の取り込み用で MCP は対象外(§8, §10) |
| #324 | feat(harness): integrate atomic global synchronization with chezmoi apply | rulesync では不可 | 書き込みは直接 `writeFile`、ロールバック無し、feature 単位の逐次書き込みで部分書き込みが起こる(§4)。Atomic Sync(staging → 全体検証 → 置換)の要件を満たさない |
| #325 | test(harness): enforce the full three-runtime Semantic Sync release gate | 部分的 | `generate --check` は生成物の drift を exit 1 で報告できる(§6)が、runtime の存在・バージョン・capability は検査しない(§7)。「製品が無い CI で成功を主張しない」の検査は別途必要 |

## 未検証・矛盾

- **「Codex project は rules / ignore のみ」という表**: 本 checkout の生成表 (docs/reference/supported-tools.md:L16 @ af9187f4) と README (README.md:L96 @ af9187f4) はいずれも Codex project で mcp / subagents / skills / hooks / permissions を ✅ としている。問いにあった表は旧版か別ソースと思われるが、一次ソースでは確認できない(未検証)。
- **Codex が project レベルの `.codex/rules/rulesync.rules` と `.codex/hooks.json` を実際に読むか**: rulesync は project モードでこれらを書く (src/features/permissions/codexcli-permissions.ts:L341-L353 @ af9187f4; src/features/hooks/codexcli-hooks.ts:L145-L147 @ af9187f4) が、Codex 本体がその場所を読む挙動は rulesync のリポジトリ外であり未検証。
- **Codex の `PermissionRequest` / `SubagentStart` 等の実在**: `CODEXCLI_HOOK_EVENTS` に含まれ (src/types/hooks.ts:L565-L588 @ af9187f4)、公式行列でも ✅ だが、Codex 側の実装は未検証。
- **コミッターの同一性**: `dyoshikawa` / `cm-dyoshikawa` / `dyoshikawa-claw` の関係は GitHub API から確定できない(未検証)。
- **hooks 行列の `postCompact`**: 公式行列では Cursor が — だが、`CURSOR_HOOK_EVENTS` にも含まれない (src/types/hooks.ts:L218-L240 @ af9187f4) ので矛盾は無い。ただし Cursor の `preCompact` は定数にあるが Cursor 側の実装は未検証。
- **Claude Code `permissions.ask` の順序**: rulesync は 3 配列をソートして書く (src/features/shared/shared-config-gateway.ts:L2153-L2157 @ af9187f4)。このリポジトリの `dot_claude/settings.json.tmpl` の並び(コメント付き・意図した順序)は保てない。テンプレートの JSON はコメントを含まないため JSON parse 自体は通る前提だが、実ファイルでの検証はしていない。
- **`--check` が名指しするパス**: `[DRY RUN] Would write: <path>` は info ログで、`--silent` では抑制される (src/types/feature-processor.ts:L132-L134 @ af9187f4)。`--json` 出力に含まれるかは `featureResults.paths` の経路までしか追っていない(部分的に未検証)。
- **rulesync の docs にある Kilo の「project は tighten のみ」**: Kilo 固有の製品制約の模倣であり、rulesync の一般方針ではない (src/types/permissions.ts:L195-L202 @ af9187f4)。
