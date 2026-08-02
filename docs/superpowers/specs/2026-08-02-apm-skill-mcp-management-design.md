# APM (microsoft/apm) による Skill/MCP サーバー管理の一本化 — Design

**Date:** 2026-08-02
**Status:** Approved (pending user review of this document)

## Context

このリポジトリには現在、Claude Code の「拡張機能」を宣言的に管理する仕組みが3つ並存している。

1. **MCPサーバー管理** — `dot_claude/mcp-servers.json`（`codex`, `deepwiki` の2エントリ）を
   `dot_claude/modify_claude.json` が `jq` で読み込み、`~/.claude/claude.json` の
   `mcpServers` キーだけを部分所有・上書きする（他のキーは温存）。
2. **マーケットプレイス登録** — `dot_claude/plugins/marketplaces.txt` に列挙した
   `owner/repo` を `run_onchange_after_add-marketplaces.sh.tmpl` が
   `claude plugin marketplace add` で登録する。ハッシュ変化時のみ再実行。
3. **プラグイン有効化 / マーケットプレイス詳細** — `dot_claude/settings.json.tmpl` の
   `enabledPlugins`（プラグインごとの true/false）と `extraKnownMarketplaces`
   （マーケットプレイスのソースリポジトリ）を直接JSON として宣言。

3つの仕組みがそれぞれ別のファイル・別の適用タイミング・別の対象ファイルに書き込んでおり、
「Skill/MCPを1箇所で宣言して1つのコマンドで反映する」体験にはなっていない。また
[microsoft/apm](https://github.com/microsoft/apm)（Agent Package Manager, 以下 APM）という、
`package.json` 相当の単一マニフェスト（`apm.yml`）で Skill・プラグイン・MCPサーバーを宣言し、
Claude Code を含む複数のコーディングエージェント間で使い回せる依存管理CLIが登場している。
これを使い、上記3つの仕組みを1つに統合する。

### APM の技術的性質（調査で確認した事実）

- **インストール方法**: Homebrew (`brew install microsoft/apm/apm`) 対応。既存の
  `darwin/Brewfile` パターンにそのまま乗る。
- **グローバル（ユーザー）スコープに対応**: マニフェストは `~/.apm/apm.yml`、
  `apm install --global`（`-g`）でユーザースコープに解決される。解決済み依存は
  `~/.apm/apm_modules/` に配置される（chezmoiの管理対象外でよい、生成物）。
- **Claude Code ターゲットへの展開先**:
  - skills → `~/.claude/skills/<name>/SKILL.md`
  - agents → `~/.claude/agents/<name>.md`
  - MCPサーバー（グローバル） → `$CLAUDE_CONFIG_DIR/.claude.json`（未設定時 `~/.claude.json`）の
    トップレベル `mcpServers` キーに直接書き込み
- **手作業ファイルを保護する**: APMが生成したファイルには専用マーカーが付与され、
  マーカーのない「手作業ファイル」は再実行時も上書きされない。これにより
  `dot_claude/skills/chezmoi-adopt-drift` 等の自作Skillは、APM管理下に含めなくても
  安全に共存できる。
- **既存マーケットプレイスをそのまま読める**: APMは Claude Code 標準の
  `.claude-plugin/marketplace.json` フォーマットをネイティブに理解する。現在
  `marketplaces.txt` に列挙している `anthropics/claude-plugins-official` 等のリポジトリは
  変換不要でAPMの依存解決対象になる。
- **MCPサーバーはインラインの非レジストリ定義に対応**:
  ```yaml
  - name: codex
    registry: false
    transport: stdio
    command: codex
    args: ["-m", "gpt-5.2-codex", "mcp-server"]
  ```
  のように、レジストリ未掲載の独自コマンド／URLもそのまま宣言できる。
- **依存モデルは明示的ピン留め型** — `package.json` と同じ思想。マーケットプレイスを
  登録しても、使うSkill/プラグインは `apm.yml` に個別に列挙する必要がある
  （Claude Code純正の「登録して後からトグル」という対話的モデルとは異なる）。
  ただし現状の `settings.json.tmpl` の `enabledPlugins` も実質同じ粒度で
  true/false を宣言済みのため、移行によるワークフローの実質的な変化は小さい。

## Decisions

1. **2段階で移行し、既存3仕組みは完全撤去する。** 並行稼働はさせない
   （後述「競合の防止」参照）。
   - **フェーズ1: MCPサーバー移行** — `dot_apm/apm.yml` を新設し
     `dependencies.mcp` に `codex` / `deepwiki` を宣言。
     `run_onchange_after_apm-install.sh.tmpl` を新設して `apm install --global` を
     自動実行する。動作確認後、`dot_claude/mcp-servers.json` と
     `modify_claude.json` のMCPマージ処理を削除する。
   - **フェーズ2: Skill/プラグイン移行** — `apm.yml` の `dependencies.apm` に、
     現在 `enabledPlugins: true` になっているプラグインを列挙する。動作確認後、
     `marketplaces.txt` / `add-marketplaces.sh.tmpl` と、
     `settings.json.tmpl` の `enabledPlugins` / `extraKnownMarketplaces` を削除する。
2. **実行タイミングは自動（`run_onchange_after_`）。** 既存の
   `add-marketplaces.sh.tmpl` と同じパターンを踏襲し、`apm.yml` のハッシュが
   変化したときだけ `chezmoi apply` 内で `apm install --global` を実行する。
   ユーザーが手動でコマンドを打つ運用は採らない。
3. **APM自体は Homebrew でインストールする。** `darwin/Brewfile` に
   `brew "microsoft/apm/apm"` を追加し、`scripts/update-brewfile.sh` の対象に含める
   （通常の brew パッケージなので特別扱い不要）。
4. **自作Skill（`dot_claude/skills/*`）はAPM管理に含めない。** APMが手作業ファイルを
   上書きしない性質を利用し、現状どおりchezmoiがファイルとして直接管理する。
   将来的にAPMのローカルパス依存として取り込む選択肢はあるが、YAGNIとして現時点では
   スコープ外とする。

## Architecture

```
dot_apm/apm.yml (chezmoi管理・source of truth)
        │ chezmoi apply でデプロイ
        ▼
~/.apm/apm.yml (グローバルマニフェスト)
        │ run_onchange_after_apm-install.sh.tmpl がハッシュ変化を検知
        ▼
apm install --global
        │
        ├─→ ~/.claude/skills/<name>/SKILL.md   (Skill/プラグイン展開、APM生成マーカー付き)
        ├─→ ~/.claude/agents/<name>.md
        └─→ ~/.claude.json の mcpServers キー   (MCPサーバー、直接上書き)

(既存の dot_claude/skills/* は chezmoi がファイルとして直接管理し続ける。
 APM生成マーカーがないため apm install の再実行で消えることはない)
```

## File Changes

| ファイル | 変更 |
|---|---|
| `dot_apm/apm.yml` | 新設。`~/.apm/apm.yml` にデプロイ。`dependencies.mcp` / `dependencies.apm` を宣言 |
| `.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl` | 新設。`apm.yml` のハッシュをコメントで追跡し、変化時に `apm install --global` を実行。`add-marketplaces.sh.tmpl` と同じ骨格 |
| `darwin/Brewfile` | `brew "microsoft/apm/apm"` を1行追加（アルファベット順） |
| `dot_claude/mcp-servers.json` | フェーズ1完了後に削除 |
| `dot_claude/modify_claude.json` | フェーズ1完了後、MCPマージ処理を削除（役割がそれのみのためスクリプト自体を削除する可能性が高い。削除前に他の用途がないか要確認） |
| `dot_claude/plugins/marketplaces.txt` | フェーズ2完了後に削除 |
| `.chezmoiscripts/run_onchange_after_add-marketplaces.sh.tmpl` | フェーズ2完了後に削除 |
| `dot_claude/settings.json.tmpl` | フェーズ2完了後、`enabledPlugins` / `extraKnownMarketplaces` ブロックを削除 |

## Migration Mapping

### MCPサーバー（フェーズ1）

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
```

### Skill / プラグイン（フェーズ2）

現在 `enabledPlugins` で `true` になっている9件を対象とする（`false` のものは
移行せず、必要になったら個別に `apm.yml` へ追加する）。

対象: `nono@nolabs-ai`, `superpowers@claude-plugins-official`,
`commit-commands@claude-plugins-official`,
`compound-engineering@compound-engineering-plugin`,
`ralph-loop@claude-plugins-official`,
`claude-md-management@claude-plugins-official`, `ecc@ecc`,
`skill-creator@claude-plugins-official`, `sentry@claude-plugins-official`

正確な `apm.yml` 上のパッケージパス表記（例:
`anthropics/claude-plugins-official/plugins/superpowers` のような形式になる見込み）は、
実装フェーズの最初に1件だけ試験導入して `apm install` の実際の解決結果を確認し、
残りに機械的に適用する。

## Conflict Prevention（重要）

MCPサーバーについては、chezmoi(jq経由の`modify_claude.json`) と APM が
**同じファイル・同じキー**（`~/.claude.json` の `mcpServers`）に書き込む。
両者を同時に稼働させると、`chezmoi apply` の実行順序次第でどちらか一方の設定が
消える競合が起きる。そのため:

- フェーズ1のPRでは「`apm.yml` 追加」と「`mcp-servers.json` / `modify_claude.json` の
  MCP処理削除」を**同一PR内**で行い、新旧メカニズムが並行稼働する期間を作らない。
- マージ後、初回の `chezmoi apply` 直後に `~/.claude.json` の `mcpServers` が
  期待通り（codex, deepwiki の2件のみ）になっているか手動確認する。

## Testing

- `apm.yml` はGo templateを使わない想定（`.tmpl`拡張子は不要）だが、YAML構文の妥当性は
  `make oxfmt` の対象に含められるか確認する。含められない場合は最小限の
  `yq`/`python -c "import yaml"` によるパース検証をテストに追加する。
- `run_onchange_after_apm-install.sh.tmpl` は既存の `add-marketplaces.sh.tmpl` と同様、
  `make test-scripts` 相当のスモークテストを追加する（実際に `apm` コマンドを叩かず、
  ハッシュ変化検知ロジックのみを対象にする — 既存の `test-modify` / `test-scripts` が
  外部コマンド呼び出しをどうスタブしているかに倣う）。
- CIには持ち込まない（既存の `test-nono-profile` と同様、ローカル環境に `apm` CLIが
  存在する場合のみ実行するスキップガードを設ける）。

## Out of Scope

- 自作Skill（`dot_claude/skills/*`）をAPMのローカルパス依存として取り込むこと
- APMの `apm audit` / `apm lock export`（SBOM）などのセキュリティ・ガバナンス機能の活用
- Claude Code以外のエージェント（Cursor, Copilot等）向けのAPM設定
- `apm.yml` の `marketplace:` ブロックを使って自リポジトリを配布側マーケットプレイス化すること
