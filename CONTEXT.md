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

**Widening Hook**:
Approval Gate を土台に残したまま、読み切れて安全と判定できたコマンドだけを承認不要に緩めるフック。フックが不在・故障・判定不能のときは何も言わず Approval Gate が発火するので、失敗は常に承認を求める側に倒れる。破壊的な綴りの拒否は、緩める判定とは独立に追加してよい。現行版の Claude Code では、フックの緩める判定が Approval Gate に負けるので成り立たない(ADR 0008、0009)。
_Avoid_: allow フック、ガード（緩める向きか塞ぐ向きかが特定できない）

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

### Self-improvement

**Improvement Surface**:
自己改善ループが書き換えてよい Harness Asset の範囲。指示・ルール・Skill・フック・スクリプトを含む。改善ループ自身と Evaluator は含まない。
_Avoid_: 改善対象(無限定)、学習対象

**Evaluator**:
改善が効いたかを判定する仕組みと、その判定に使う基準と事例。失敗の検出と Failure Pattern への分類も含む。Improvement Surface の外に置き、自己改善ループとは別の経路でしか変更しない。
_Avoid_: 評価(無限定)、doctor(稼働検査と混同する)

**Failure Pattern**:
同じ根本原因から繰り返し起こりうる、エージェントの失敗の類型。個々の失敗事例ではなく類型で数え、harness 全体の健康度はその再発率で測る。
_Avoid_: 失敗(無限定)、学び、エラー

**Eval Case**:
1つのルールの有無で結果が分かれるかを確かめる、Evaluator の事例。ルールの無い側で失敗が再現することを確かめたものだけが有効で、どちらの側でも成功するものは効果の証拠にならない。
_Avoid_: テストケース(bats と紛らわしい)、評価(無限定)

**Rule Ledger**:
自己改善ループが採否を判定したルールごとの記録。Failure Pattern、Eval Case、効果、採否の経緯を、仕事の文脈を含まない形で公開リポジトリに残す。生の証拠はローカルにだけ置く。
_Avoid_: queue-archive(ローカルの作業記録と混同する)、履歴

**Dropped Change**:
自己改善ループが採用したが、commit フックや lint を通せずに commit しなかった変更。失敗ではなく、queue に戻して次の選別にかけ直す。commit が1件も無く Dropped Change がある週だけを、ループの失敗として扱う(陳腐化の修正などの commit があれば PR を作り、Dropped Change はその本文に載せる)。
_Avoid_: 却下(採否の判定と混同する)、失敗した採用

**Deploy-only Fix**:
リポジトリへの commit では直らず、人が適用して初めて効く修正。PR の有無にかかわらず、人が適用し終えるまで知らせ続ける。
_Avoid_: 手動修正、apply 待ち

### Profiles

**Machine Profile**:
1台のマシンの用途区分（`work` / `personal`）を表すテンプレート変数。dotfiles のレンダリングを分岐させる。
_Avoid_: profile（無限定）、プロファイル

**Sandbox Profile**:
Isolation Boundary が何を許可するかを定義するポリシー文書。
_Avoid_: profile（無限定）、プロファイル

### Autonomous delivery

**Deliver**:
plan を受け取り、実装からレビュー修正ループ・動作確認を経て人間への報告までを agent が自律で行うプロセス。push も PR の作成もせず、コミットはローカルのブランチに残して、公開するかどうかは人間に委ねる。
_Avoid_: 自律実装(無限定)

**Review-Verify**:
既にコミットされたブランチに、Requirements Document を基準にしたレビュー修正ループと動作確認だけをかけ、人間へ報告するプロセス。Deliver とは、実装から始めないことだけが違い、どちらも公開しない。
_Avoid_: レビューだけモード、deliver の後半

**Review Finding**:
レビューが返す個々の指摘。重大度を持つ。修正必須のものは修正されるか Deferred Finding になるかで閉じ、修正に回された Advisory Finding は修正されるか Declined Advisory Finding になるかで閉じる。
_Avoid_: コメント、issue(GitHub Issue と紛らわしい)

**Deferred Finding**:
修正しないと決めた Review Finding。実装した agent 単独では決められず、別の検証者が偽陽性またはスコープ外と同意したものに限る。必ず人間への最終報告に載る。
_Avoid_: 見送り(無限定)、スキップした指摘、却下

**Unresolved Finding**:
修正必須なのに、ループの上限に達するか収束しなかったために修正されずに残った Review Finding。Deferred Finding と違い誰も見送りに同意していないため、最終報告で最優先に扱う。
_Avoid_: 見送り、残課題(無限定)

**Advisory Finding**:
修正必須の重大度を含まない Review Finding。最初のレビューラウンドで出たものだけを修正エージェントに渡し、ループの収束条件にも上限到達時の Unresolved Finding にも数えない。
_Avoid_: nit(重大度を問わず使われる)、参考指摘(報告の節名としては使う)

**Declined Advisory Finding**:
修正エージェントが直さないと判断した Advisory Finding。Deferred Finding と違い検証者の同意を要さず、理由付きで最終報告に載る。
_Avoid_: Deferred Finding(検証者の同意を経たものに限る)

**Requirements Document**:
何を作るつもりかを人間が書いた、レビュー・修正・動作確認が意図の正本として読む文書。plan(タスク分解を持つもの)と spec のどちらもこの一種で、実装から始めるには plan が要る。
_Avoid_: 仕様書(無限定)、入力

**Requirements Concern**:
実装ではなく Requirements Document そのものに向けられた Review Finding で、何を作るかを agent は決めないため修正せずに人間への最終報告に回す。Requirements Document どおりに作ると壊れるものに限り、その場で作業を止める理由になる。
_Avoid_: Plan Concern(旧称)、仕様バグ、plan 修正
