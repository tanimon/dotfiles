---
title: "feat: Cross-Project Harness Engineering Infrastructure"
type: feat
status: completed
date: 2026-03-28
---

# feat: Cross-Project Harness Engineering Infrastructure

## Overview

Claude Code環境に対して、複数プロジェクトで機能する体系的なハーネスエンジニアリング基盤を構築する。ハーネスエンジニアリングとは、AIコーディングエージェントを取り巻く環境・ツール・制約・フィードバックシステムを設計・改善する分野であり、「エージェントが失敗するたびに、その失敗を二度と起こさないよう仕組みを工学的に解決する」というアプローチである。

## Problem Frame

現在のClaude Code設定は、chezmoi管理下で以下を提供している：
- グローバルCLAUDE.md、言語別ルール（Go, TypeScript, common）、フック（フォーマット、通知）、MCPサーバー、エージェント定義、プラグイン

しかし、ハーネスエンジニアリングの観点から以下のギャップがある：
1. **プロジェクトドメイン固有ルール生成の仕組みがない** — 失敗からルールを自動抽出・提案するパイプラインが不在
2. **プロジェクト固有CLAUDE.mdのスキャフォールディングがない** — 新規プロジェクトで毎回ゼロからCLAUDE.mdを書く必要がある
3. **フックが限定的** — フォーマットと通知のみで、検証フィードバックやループ検出がない
4. **複数プロジェクト横断のハーネス共有が弱い** — プロジェクト間で学んだ教訓やルールを伝播する仕組みがない
5. **エージェント行動の品質フィードバックループがない** — 成功/失敗パターンの蓄積と活用が体系化されていない

## Requirements Trace

- R1. 新規プロジェクトに対してCLAUDE.mdとルールのスキャフォールドを生成できる
- R2. エージェントの失敗パターンからルール候補を提案できる
- R3. 複数プロジェクトに共通するハーネス知識を共有できる
- R4. 既存のchezmoi管理パターンと整合する
- R5. フックを拡張し、検証フィードバックを強化する
- R6. プロジェクト固有のドメインルールを管理できる

## Scope Boundaries

- Claude Code本体の変更は行わない（設定・ルール・フック・スクリプトのみ）
- 既存のchezmoi管理パターン（modify_, run_onchange_, .chezmoiignore）を尊重する
- LLMを使ったルール自動生成は今回スコープ外（手動フローのみ）
- ブラウザ自動テスト統合は今回スコープ外

## Context & Research

### Relevant Code and Patterns

- `dot_claude/settings.json.tmpl` — hooks, permissions, env, plugins の定義
- `dot_claude/rules/{common,golang,typescript}/` — 言語別ルール
- `dot_claude/CLAUDE.md` — グローバル指示
- `dot_claude/agents/` — 専門エージェント定義（10個）
- `dot_claude/commands/simplify.md` — カスタムコマンド
- `CLAUDE.md` (リポジトリルート) — プロジェクト固有指示
- `docs/solutions/` — 過去の解決策（25件）
- `.chezmoiignore` — `~/.claude/` 動的ディレクトリの除外

### Institutional Learnings

- `docs/solutions/` に25件の解決策が蓄積されており、これは事実上ハーネスエンジニアリングの「失敗→修正」ループの成果物
- modify_スクリプトでランタイム変更ファイルを部分管理するパターンが確立済み
- chezmoi外のファイル（marketplace, plugin JSON）は.chezmoiignore + run_onchange_で管理

### External References (Harness Engineering Principles)

- **OpenAI/Martin Fowler**: 厳格なアーキテクチャパターン + カスタムlinterで制約を機械的に強制
- **Anthropic**: Generator-Evaluator分離、コンテキストリセット > コンテキスト圧縮
- **Mitchell Hashimoto**: 失敗のたびにハーネスを改善する複利的ループ。CLAUDE.mdは「エージェント行動のバグトラッカー」
- **LangChain**: ハーネス改善のみでベンチマーク30位→5位。モデル変更なし
- **Ignorance.ai**: 4つの柱 — アーキテクチャ、ツール、ドキュメント、フィードバックループ

## Key Technical Decisions

- **chezmoi管理のテンプレートとスクリプトで実装**: 新しい外部ツールを導入せず、既存のchezmoi + シェルスクリプトパターンを活用する。理由：dotfilesリポジトリの哲学と整合し、依存関係を最小限に保つ
- **グローバルルール vs プロジェクトルール の2層構造を明確化**: `~/.claude/rules/` にグローバルルール、プロジェクトの `.claude/rules/` にプロジェクト固有ルール。理由：Claude Codeのルール解決順序（グローバル→プロジェクト）に従う
- **スキャフォールドはカスタムコマンド（`dot_claude/commands/`）として実装**: 理由：Claude Codeの`/`コマンドとしてユーザーが呼び出せる自然なインターフェース
- **ハーネスの知識共有は `dot_claude/rules/common/` のルール拡充で実現**: 理由：chezmoi applyで全マシン・全プロジェクトに伝播する既存メカニズムを活用
- **フック拡張はsettings.json.tmplへの追加で実装**: 理由：既存パターンとの整合性

## Open Questions

### Resolved During Planning

- **ルール自動生成にLLMを使うか？**: No。手動フロー（claudeception skill + 手動ルール追加）で十分。LLM自動生成は将来の拡張として検討
- **プロジェクト固有ルールの保存場所は？**: `.claude/rules/` (プロジェクトルート)。Claude Codeが自動的に読み込む

### Deferred to Implementation

- **PostToolUseフックの具体的な追加パターン**: 実際のフック挙動テストが必要
- **スキャフォールドテンプレートの最適な粒度**: 実際にいくつかのプロジェクトで試してフィードバックを得る必要がある

## Implementation Units

- [x] **Unit 1: ハーネスエンジニアリングのグローバルルール追加**

**Goal:** 全プロジェクト共通のハーネスエンジニアリング原則をルールとして定義し、chezmoi管理下に置く

**Requirements:** R3, R4

**Dependencies:** None

**Files:**
- Create: `dot_claude/rules/common/harness-engineering.md`

**Approach:**
- ハーネスエンジニアリングの核心原則をClaude Codeが読むルールとして記述
- 「失敗パターンからルールを追加する」ワークフロー、「CLAUDE.mdをエージェント行動のバグトラッカーとして扱う」指針を含める
- 既存の `common/` ルール（coding-style.md, security.md等）と同じフォーマットに従う

**Patterns to follow:**
- `dot_claude/rules/common/coding-style.md` のフォーマット

**Test scenarios:**
- Happy path: `chezmoi apply` 後に `~/.claude/rules/common/harness-engineering.md` が配置される
- Happy path: Claude Codeセッションで当該ルールがコンテキストに読み込まれる

**Verification:**
- `chezmoi managed | grep harness-engineering` でファイルが管理対象に含まれる
- ルール内容がClaude Codeのシステムプロンプトに反映される

---

- [x] **Unit 2: プロジェクトCLAUDE.mdスキャフォールドコマンドの作成**

**Goal:** 新規プロジェクトに対してCLAUDE.mdの骨格を生成するClaude Codeカスタムコマンドを作成する

**Requirements:** R1, R6

**Dependencies:** None

**Files:**
- Create: `dot_claude/commands/scaffold-claude-md.md`

**Approach:**
- Claude Codeの `/scaffold-claude-md` コマンドとして実装
- プロンプトで以下を指示：プロジェクトの構造を分析し、適切なCLAUDE.mdを生成
- テンプレートの主要セクション：プロジェクト概要、共通コマンド、アーキテクチャ、既知の落とし穴、テスト要件
- Mitchell Hashimotoの知見を反映：CLAUDE.mdの各エントリは「過去にエージェントが犯した悪い行動」を記録するもの

**Patterns to follow:**
- `dot_claude/commands/simplify.md` のカスタムコマンドフォーマット

**Test scenarios:**
- Happy path: `/scaffold-claude-md` を実行すると、現在のプロジェクトを分析してCLAUDE.mdの骨格を生成する
- Edge case: 既にCLAUDE.mdが存在するプロジェクトでは、既存の内容を保持しつつ不足セクションを提案する

**Verification:**
- `chezmoi apply` 後に `~/.claude/commands/scaffold-claude-md.md` が配置される
- Claude Codeで `/scaffold-claude-md` が呼び出し可能

---

- [x] **Unit 3: ハーネスフィードバックキャプチャコマンドの作成**

**Goal:** エージェントの失敗や問題行動から、ルール候補やCLAUDE.mdエントリを提案するコマンドを作成する

**Requirements:** R2, R3

**Dependencies:** None

**Files:**
- Create: `dot_claude/commands/capture-harness-feedback.md`

**Approach:**
- `/capture-harness-feedback` コマンドとして実装
- 現在のセッションの問題行動を分析し、以下を提案：
  - CLAUDE.mdに追加すべきエントリ（プロジェクト固有）
  - `~/.claude/rules/` に追加すべきルール（全プロジェクト共通）
  - フック追加の必要性
- claudeceptionスキルとの差別化：claudeceptionは汎用的な学習抽出、このコマンドはハーネス改善に特化

**Patterns to follow:**
- `dot_claude/commands/simplify.md`

**Test scenarios:**
- Happy path: エージェントが間違ったアプローチを取った後に `/capture-harness-feedback` を実行すると、具体的なルール追加案が生成される
- Happy path: 提案が「プロジェクト固有」か「グローバル」かを区別して出力する

**Verification:**
- コマンドが呼び出し可能で、構造化された出力を生成する

---

- [x] **Unit 4: プロジェクト固有ルールテンプレートの作成**

**Goal:** プロジェクトの `.claude/rules/` に配置するドメイン固有ルールのテンプレートセットを提供する

**Requirements:** R1, R6

**Dependencies:** Unit 2

**Files:**
- Create: `dot_claude/commands/scaffold-project-rules.md`

**Approach:**
- `/scaffold-project-rules` コマンドとして実装
- プロジェクトの技術スタックを検出し、適切なルールテンプレートを生成
  - Web (React/Next.js): コンポーネント設計、状態管理、API呼び出しパターン
  - CLI (Go): コマンド設計、フラグ管理、エラーハンドリング
  - API (Rails/Express): エンドポイント設計、認証パターン
  - 汎用: テスト戦略、デプロイメント、コードレビュー基準
- `.claude/rules/` ディレクトリに直接配置

**Patterns to follow:**
- `dot_claude/rules/golang/` の構造（言語/ドメイン別ディレクトリ）

**Test scenarios:**
- Happy path: Go CLIプロジェクトで実行すると、Go固有 + CLI固有のルールテンプレートが生成される
- Happy path: 既存ルールがある場合は衝突せず追加される

**Verification:**
- コマンド実行後、プロジェクトの `.claude/rules/` に適切なルールファイルが配置される

---

- [x] **Unit 5: PostToolUseフックの拡張**

**Goal:** 検証フィードバックを強化するフックを追加し、エージェントの行動品質を向上させる

**Requirements:** R5

**Dependencies:** None

**Files:**
- Modify: `dot_claude/settings.json.tmpl`

**Approach:**
- 既存のPostToolUseフック（Edit|Write → lint/gofmt）に加えて以下を追加：
  - **Bash実行後の安全性チェック**: 危険なコマンドパターンの検出と警告
  - **Write後のsecretlintチェック**: 機密情報の漏洩防止
- フックコマンドはシンプルなシェルスクリプトとして `dot_claude/scripts/` に配置
- 失敗時にエージェントにフィードバックメッセージを返すことで自己修正を促す

**Patterns to follow:**
- 既存のフック構造（`settings.json.tmpl` の `hooks` セクション）
- `dot_claude/scripts/executable_notify-wrapper.sh` のスクリプトパターン

**Test scenarios:**
- Happy path: .envファイルにAPIキーを書き込もうとすると、フックが警告を返す
- Edge case: フックスクリプトが存在しない場合でもClaude Codeがクラッシュしない（`|| true` パターン）
- Error path: フックのexit code != 0でエージェントにフィードバックが伝わる

**Verification:**
- `chezmoi apply` 後にフックが正しく設定される
- 意図的に問題のあるファイルを書き込み、フックが反応することを確認

---

- [x] **Unit 6: ハーネスヘルスチェックコマンドの作成**

**Goal:** 現在のプロジェクトのハーネス状態を診断し、改善提案を行うコマンドを作成する

**Requirements:** R1, R3, R5

**Dependencies:** Unit 1, Unit 2

**Files:**
- Create: `dot_claude/commands/harness-health.md`

**Approach:**
- `/harness-health` コマンドとして実装
- 以下を診断：
  - CLAUDE.mdの存在と品質（セクション充足度）
  - `.claude/rules/` の存在と網羅性
  - プロジェクト固有の落とし穴が文書化されているか
  - テスト要件が明記されているか
  - 既知のパターンとのギャップ
- スコアカード形式で結果を表示し、具体的な改善アクションを提案

**Patterns to follow:**
- `dot_claude/commands/simplify.md`

**Test scenarios:**
- Happy path: CLAUDE.mdがないプロジェクトで実行すると「CLAUDE.md作成を推奨」と表示
- Happy path: 充実したハーネスのプロジェクトでは高スコアが表示される

**Verification:**
- コマンドが呼び出し可能で、診断結果を構造化された形式で出力する

## System-Wide Impact

- **Interaction graph:** 新規ルール・コマンドはClaude Codeのセッション開始時に自動読み込みされる。フック拡張はすべてのツール実行に影響する
- **Error propagation:** フックの失敗は `|| true` でラップし、Claude Codeセッションをクラッシュさせない。フックのstderrはエージェントへのフィードバックとして利用
- **State lifecycle risks:** chezmoi applyで設定が上書きされるため、ランタイムで変更したsettings.jsonが失われるリスク → settings.json.tmplのテンプレート化で対応済み
- **API surface parity:** カスタムコマンドはClaude Code CLIおよびIDEエクステンション共に利用可能
- **Unchanged invariants:** 既存のフック（Notification, Stop, PostToolUse lint/gofmt, UserPromptSubmit）は変更しない。既存のルールファイルも変更しない

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| フック追加によるClaude Codeのパフォーマンス低下 | フックコマンドを軽量に保つ。重い処理はバックグラウンドで実行 |
| スキャフォールドコマンドの過剰生成 | 既存ファイルの検出と保護。上書きではなく提案ベース |
| ルール肥大化による情報過多 | ルールに明確なスコープと適用条件を記述。定期的な棚卸しをharness-healthで促す |
| フックのstderr/exit codeの挙動がClaude Codeバージョンで変わる可能性 | docs/solutions/ の既存知見（claude-code-hook-exit-code-and-stderr-semantics.md）に従う |

## Sources & References

- Related code: `dot_claude/settings.json.tmpl`, `dot_claude/rules/`, `dot_claude/commands/`
- Related solutions: `docs/solutions/integration-issues/claude-code-hook-exit-code-and-stderr-semantics.md`
- External docs: Martin Fowler harness engineering article, Anthropic effective harnesses blog, Mitchell Hashimoto AI adoption journey
