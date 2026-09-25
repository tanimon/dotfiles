# Dotfiles

macOS 向けの chezmoi 管理 dotfiles リポジトリ。ホームディレクトリの設定ファイル群をバージョン管理下の Source から生成し、エージェントが実行されるときの権限・隔離・検証の方針もここで定義する。

## Language

### Managed files

**Source**:
リポジトリが所有・編集するバージョン管理下のファイル。管理対象ファイルが何を含むべきかの権威であり、Target への対応と Target が受け取る権限はファイル名の命名規約から導かれる。
_Avoid_: 元ファイル、テンプレート（テンプレートは Source の一形態にすぎない）

**Target**:
Source からレンダリングされてホームディレクトリに配置される生成物。直接編集は次回の apply で上書きされ、バージョン管理もされない。
_Avoid_: 配置先、デプロイ済みファイル、実ファイル

### Permission policy

**Risk Tier**:
書き込みコマンドを、効果の可逆性と効果の到達範囲で分類した4段階。Tier 0 はローカルかつ完全に可逆、Tier 1 は既存コンテナへの追記のみ、Tier 2 は共有オブジェクト状態の変更、Tier 3 は破壊的・不可逆・履歴改変。
_Avoid_: リスクレベル、危険度

**Approval Gate**:
コマンドの実行前に操作者の承認を要求するルール。一括許可より先に評価され、プロンプトを省略する設定下でも発火する。
_Avoid_: 確認プロンプト、ask ルール

### Isolation boundary

**Isolation Boundary**:
コマンドがその内側で実行される、OS が強制し既定では拒否する境界。どの実装が境界を提供するかはエージェントの起動経路で決まり、経路ごとに有効なものは常に1つだけ。
_Avoid_: サンドボックス（無限定に使うと起動経路が特定できない）

**Boundary Exclusion**:
名前を指定した1コマンドを Isolation Boundary の外・ホスト側で実行する例外指定。隔離を外すだけで、追加の権限も追加の承認も伴わない。
_Avoid_: ホスト実行許可、bypass、除外リスト

### Verification

**Contrast Pair**:
fail open で無効化されうる仕組みを検証する手法。対象の許可や設定を1つだけ取り除いた実行で結果が反転することまで確認して、初めて仕組みが機能している証拠になる。
_Avoid_: 対比ペア、対照検証

### Agent harness

**Harness Asset**:
エージェントの行動を決める、Source が所有する宣言的な資産。指示、ルール、権限方針、フック、Skill、コマンド、MCP・プラグインの宣言を含み、UI 設定や Runtime State は含まない。
_Avoid_: 設定（範囲が曖昧）、ハーネス設定

**Semantic Sync**:
異なるエージェント製品の Target 間で、表現形式ではなく意図と実行時の効果が一致している状態。
_Avoid_: 同期（文字列一致や双方向同期と区別できない）、設定コピー

**Harness Policy**:
製品固有の設定形式から独立して、複数のエージェントに共通する意図と制約を表す Harness Asset。
_Avoid_: 共通設定、Claude 設定

**Harness Manifest**:
対象製品の存在・バージョン・必要機能の検査条件と、生成する Target の一覧を記述する構造化された Source。自然言語の指示本文は Content Module として分離する。
_Avoid_: 共通 JSON、設定一覧

**Content Module**:
複数のエージェント製品またはプロジェクトで再利用する、自然言語の指示やルールを記述した Markdown の Source。
_Avoid_: 共通プロンプト、文章テンプレート

**Dependency Plane**:
外部から取得する Harness Asset と MCP を解決、固定、監査し、対象製品へ配布する領域。何をインストールできるかを統制するが、エージェントが実行時に何を行えるかは統制しない。
_Avoid_: ハーネス全体、実行権限管理

**Runtime Adapter**:
Harness Policy を各エージェント製品が解釈できる Target へ写像する境界。製品ごとの設定形式や機能差をこの境界の内側へ閉じ込める。
_Avoid_: 変換スクリプト（実装方式に限定される）、同期処理

**Target Owner**:
1つの Target を生成・更新する責任を単独で持つ仕組み。部分更新を行う Target でも、merge 処理を実行する Target Owner は1つに限定する。
_Avoid_: writer、共同所有

**Runtime Extension**:
1つのエージェント製品だけが持つ機能を利用する、その製品専用の Harness Asset。Harness Policy の代替ではなく、共通化できない追加の振る舞いを表す。
_Avoid_: 例外設定、固有設定

**Runtime State**:
エージェント製品自身が実行中に生成・更新する可変データ。履歴、キャッシュ、利用統計、インストール済みプラグインの記録などが該当し、Source の所有対象外とする。
_Avoid_: 自動生成設定、動的ファイル

**Capability Probe**:
対象製品のバージョン表記ではなく、必要な設定、イベント、強制機構が実際に利用可能であることを確認する検査。
_Avoid_: バージョンチェック、対応確認

**Atomic Sync**:
すべての Target を一時領域で生成・検証し、全体が成功した場合だけ既存 Target と入れ替える同期。失敗時は同期前の Target を維持する。
_Avoid_: 一括生成、順次反映

**Project Harness**:
対象プロジェクト自身が所有する、そのプロジェクト固有の Harness Asset。共通基盤と生成機構は dotfiles が提供するが、プロジェクトの知識はコードと同じリポジトリに残す。
_Avoid_: プロジェクト設定、dotfiles 側のプロジェクト定義

**Managed Project**:
明示的に登録され、Project Harness の Source と生成済み Target をバージョン管理し、Semantic Sync の検証対象になっているプロジェクト。未登録のリポジトリは同期・変更の対象にならない。
_Avoid_: 対応プロジェクト、設定済みリポジトリ

### Profiles

**Machine Profile**:
1台のマシンの用途区分（`work` / `personal`）を表すテンプレート変数。dotfiles のレンダリングを分岐させる。
_Avoid_: profile（無限定）、プロファイル

**Sandbox Profile**:
Isolation Boundary が何を許可するかを定義するポリシー文書。
_Avoid_: profile（無限定）、プロファイル

### Autonomous delivery

**Review Finding**:
レビューが返す個々の指摘。重大度を持ち、修正されるか Deferred Finding になるかのどちらかで閉じる。
_Avoid_: コメント、issue(GitHub Issue と紛らわしい)

**Deferred Finding**:
修正しないと決めた Review Finding。実装した agent 単独では決められず、別の検証者が偽陽性またはスコープ外と同意したものに限る。必ず人間への最終報告に載る。
_Avoid_: 見送り(無限定)、スキップした指摘、却下

**Unresolved Finding**:
修正必須なのに、ループの上限に達するか収束しなかったために修正されずに残った Review Finding。Deferred Finding と違い誰も見送りに同意していないため、最終報告で最優先に扱う。
_Avoid_: 見送り、残課題(無限定)

**Plan Concern**:
実装ではなく入力された plan そのものに向けられた Review Finding。何を作るかを agent は決めないため修正対象にならず、人間への最終報告に回す。plan どおりに作ると壊れるものに限り、その場で作業を止める理由になる。
_Avoid_: 仕様バグ、plan 修正
