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

### Profiles

**Machine Profile**:
1台のマシンの用途区分（`work` / `personal`）を表すテンプレート変数。dotfiles のレンダリングを分岐させる。
_Avoid_: profile（無限定）、プロファイル

**Sandbox Profile**:
Isolation Boundary が何を許可するかを定義するポリシー文書。
_Avoid_: profile（無限定）、プロファイル
