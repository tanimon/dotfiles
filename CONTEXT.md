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

### Harness sync

**Harness Manifest**:
runtime・必須 capability・Target とその Owner を機械検証可能に宣言する JSON(`harness/manifest.json`)。runtime は明示必須で、暗黙検出は reject される。
_Avoid_: 設定ファイル(無限定)、マニフェスト(無限定)

**Target Owner**:
ある Target の最終内容を書く唯一のコンポーネント。Harness Manifest では 1 target につき 1 つの adapter 名で指名し、同じ path を 2 つの owner が持つ manifest は無効。
_Avoid_: 生成元、担当

**Runtime Adapter**:
Harness Policy を製品固有の表現に render する実行体(`harness/adapters/<owner>.sh render <staging-file> <target-json>`)。Target Owner として指名される。
_Avoid_: ジェネレータ、プラグイン

**Atomic Sync**:
全 Target を staging に render し、全体が検証に通った後だけ live を置換する同期方式。1 つでも render に失敗すれば既存 Target は 1 つも変わらない。
_Avoid_: 一括同期、上書き

**Capability Probe**:
製品のバージョン文字列ではなく、実際の挙動(`--help` 出力等)で必須機能の有無を確かめる検査。存在しない・minVersion 未満・capability 欠落は FAIL、maxVerifiedVersion 超は WARN。
_Avoid_: バージョンチェック、互換性チェック

**Harness Policy**:
Harness Manifest に構造化して置く、機械検証可能なポリシー(runtime 要件、Target と Owner、後続チケットで権限・hook・MCP の意図)。自然言語の指示は含まない。
_Avoid_: 設定、ルール(無限定)

**Content Module**:
再利用可能な自然言語の指示を収めた Markdown。Runtime Adapter が製品ごとの指示ファイルに render する Source。
_Avoid_: テンプレート、指示ファイル(生成物と区別がつかない)

**Managed Project**:
`harness init` で明示的に登録され、プロジェクト固有の Source を自分で所有し、生成された Target を commit するリポジトリ。未登録のリポジトリは同期対象にならない。
_Avoid_: 対象リポ、管理対象(無限定)

### Profiles

**Machine Profile**:
1台のマシンの用途区分（`work` / `personal`）を表すテンプレート変数。dotfiles のレンダリングを分岐させる。
_Avoid_: profile（無限定）、プロファイル

**Sandbox Profile**:
Isolation Boundary が何を許可するかを定義するポリシー文書。
_Avoid_: profile（無限定）、プロファイル
