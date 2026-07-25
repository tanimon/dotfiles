---
title: "ディレクトリ単位で ask 権限を緩めることはできない"
date: 2026-07-25
category: docs/solutions/integration-issues
module: dot_claude/settings.json.tmpl
problem_type: integration_issue
component: tooling
symptoms:
  - "特定リポジトリだけ git/gh の更新系コマンドを allow にしたいが、project の .claude/settings.json に allow を書いても承認プロンプトが出続ける"
  - "リポジトリ群の親ディレクトリに .claude/settings.json を置いても配下に適用されない"
  - "PreToolUse フックで permissionDecision: allow を返してもプロンプトが消えない"
root_cause: config_precedence
resolution_type: config_change
severity: medium
tags: [claude-code, permissions, ask, allow, precedence, settings-scope, hooks, per-directory]
---

# ディレクトリ単位で ask 権限を緩めることはできない

## Problem

user scope の `dot_claude/settings.json.tmpl` は `permissions.ask` で git/gh の更新系コマンド
（`git push`、`gh pr merge` など）を承認プロンプト付きにゲートしている。この制約は全リポジトリに
一律適用されるが、特定の 1 リポジトリ（信頼度が高く、自動化ループで動かしたい等）だけプロンプトを
省きたいという要望があった。狙いは「その 1 リポジトリの中でだけ `ask` を `allow` 相当に緩める」
ことであり、user scope の設定自体を書き換える意図はなかった。

## Symptoms

- project scope（対象リポジトリの `.claude/settings.json`）に `permissions.allow` で該当コマンドを
  追加しても、承認プロンプトは消えず出続けた。
- 対象リポジトリ群をまとめる親ディレクトリに `.claude/settings.json` を置いて配下のリポジトリに
  一括適用しようとしても、配下のリポジトリには一切反映されなかった。
- `PreToolUse` フックで対象コマンドを検出し `hookSpecificOutput.permissionDecision: "allow"` を
  返すようにしても、プロンプトは消えなかった。

## What Didn't Work

### project scope の `allow`

一見もっともらしい理由: `settings.json` はスコープ（user/project/local）ごとにマージされるので、
project scope で `allow` を追加すれば同じキーの user scope 設定を上書き・追加できるはずだと考えた。
実際には `deny > ask > allow` という優先順位はスコープをまたいでも保たれる。公式ドキュメントは
次のように明記している:

> "The same precedence applies between ask and allow: a matching ask rule prompts even when a more specific allow rule also matches the same call." および "The same holds across settings scopes."

つまり user scope の `ask` は project scope のどんな `allow` よりも優先される。project scope は
`allow` を「追加」できても、既存の `ask` を「上書き」することはできない。

### 親ディレクトリへの settings 配置

一見もっともらしい理由: skills / subagents / slash commands は親ディレクトリを遡って発見される
ため、`.claude/settings.json` も同様に親ディレクトリからの継承やフォールバックがあると誤解しやすい。
実際には settings の読み込みはこの探索方式に乗っていない。公式ドキュメントは次のように明記している:

> "Hooks and other `.claude/settings.json` keys load from the current working directory's `.claude/` folder with no parent-directory fallback."

つまり `permissions` を含む `settings.json` のキーは、実行時の作業ディレクトリの `.claude/` から
しか読み込まれず、親ディレクトリへのフォールバックは存在しない。skills / subagents / slash commands
が親ディレクトリ探索の対象になっているのとは非対称であり、この非対称性こそが「親に置けば配下に効く
はずだ」という誤った類推を生む。なお `.claude/settings.local.json` は v2.1.211 以降 git リポジトリの
ルートから読み込まれるようになったが、これは「そのリポジトリ全体」への拡張であって「そのリポジトリを
含む複数リポジトリの木構造全体」への拡張ではない。あくまで repo 単位のスコープであり、tree 単位の
スコープではない。

### PreToolUse フックで `"allow"` を返す

一見もっともらしい理由: `PreToolUse` フックの `permissionDecision` はツール呼び出しの可否を制御する
仕組みなので、フック側で `"allow"` を返せば通常の許可判定より優先されるはずだと考えた。実際には
`deny`/`ask` ルールはフックの戻り値と無関係に評価される。公式ドキュメントは次のように明記している:

> "Claude Code evaluates deny and ask rules regardless of what a PreToolUse hook returns: a matching deny rule blocks the call, and a matching ask rule still prompts even when the hook returned \"allow\" or \"ask\"."

フックが `"allow"` を返しても、静的な `ask`/`deny` ルールがマッチする限りその判定が優先される。
フックは判定を「足す」ことはできても、既存の `ask`/`deny` を「打ち消す」ことはできない。

### `bypassPermissions` モード

一見もっともらしい理由: `bypassPermissions` はセッション全体の承認プロンプトをスキップするモードで
あり、これを対象リポジトリでの作業時だけ有効にすれば `ask` も含めて素通りできるはずだと考えた。実際
にはこのモードにも例外があり、公式ドキュメントは次のように明記している:

> "Skips permission prompts, except those forced by explicit `ask` rules"

これは設計として意図されたものである。`ask` は無人実行（自動ループ、スケジュール実行など）の下でも
確実にゲートを機能させるための仕組みであり、その存在意義は「どのセッションモードでも生き残る」こと
にある。`bypassPermissions` で `ask` まで消えてしまえば、そもそも `ask` に置く理由がなくなる。

## Solution

位置依存の権限制御を表現できる形は次の 2 通りだった。

- **(A) 許容的なベースライン + user scope の `PreToolUse` フック**: `permissions` 全体を緩め
  （＝ベースラインを `allow` 寄りにし）、user scope の `PreToolUse` フックがフック stdin JSON の
  `cwd` フィールドを見て、緩めたいディレクトリ群の外では `hookSpecificOutput.permissionDecision: "ask"`
  を返して締め直す。
- **(B) 単一のグローバルな宣言的ポリシーをリスクで調整する**: ディレクトリで分岐せず、コマンドご
  との破壊性・可逆性で `allow`/`ask`/`deny` を割り振る一つのポリシーとして表現する。

今回は **(B) を採用**した。(A) を却下した理由は 3 点ある。

1. ゲートの実体が宣言的な設定ファイルから shell script（フック本体）に移る。フックが誤って
   `"allow"` を返せば `ask` は復元できないため、このスクリプトの正しさそのものがセキュリティ
   クリティカルになる。
2. `cwd` 判定だけでは不十分で、コマンド文字列側の複合構文（`env FOO=1 git push`、
   `foo && git push` など）まで自前でパースしないと、意図しないディレクトリでコマンドが素通り
   する「fail open」を防げない。
3. Claude Code のフックが呼び出しをブロックするには **exit 2** を返す必要があるが、この
   リポジトリの `.claude/rules/shell-scripts.md` が定める exit code contract は
   `exit 0` = 意図的スキップ、`exit 1` = アクション可能なエラー、という 2 値の意味付けしか
   持たない。ブロック用に exit 2 を新たに割り当てると既存の contract と衝突する。

(B) の実装として、`dot_claude/settings.json.tmpl` の `permissions` を 4 段階のリスク Tier モデル
（Tier 0: ローカルで完全に可逆、Tier 1: 既存のコンテナへの追記のみで新しい作業項目を作らず誰かの
キューも変えない、Tier 2: 共有オブジェクトの状態を変える、Tier 3: 破壊的・不可逆・履歴書き換え）で
再編した。この Tier モデルに沿って、`git commit` / `git merge` / `git revert` / `git push` /
`gh pr comment` / `gh issue comment` の 6 件を `ask` から `allow` へ移した。いずれも Tier 0 または
Tier 1（`push` は既存ブランチへの追記であり、`--force`/`--force-with-lease`/`-f` の 3 表記が
すべて `deny` に残っているために「追記専用」という Tier 1 の前提が成立する）であり、ディレクトリ
ではなくコマンドの性質で緩めている。

## Why This Works

**`ask` は床（floor）であって既定値（default）ではない。** どのスコープからも床を上げる（制限を
足す）ことはできるが、床を下げる（制限を外す）ことはできない。`allow` ルールも `PreToolUse`
フックの `"allow"` 判定も、この床より**下**に位置する — つまりどちらも既存の `ask`/`deny` を
上書きする力を持たない。

したがって位置依存の権限制御は、「制限の強い床を選んでそこから例外を切り出す」形では実現できない。
実現できるのは「許容的な床を選び、その上に制限を積み増す」形だけである。`## What Didn't Work` の
4 件はいずれも前者の方向 — 既存の `ask` という床の上から緩和を試みた — を取ったために失敗した。
(A) はこの正しい方向（許容的な床 + 上乗せの制限）に沿った実装であり方向としては成立するが、
`## Solution` で述べた実装コスト（フック自体がセキュリティクリティカルになる、複合コマンド構文の
自前パース、exit code contract との衝突）を理由に採用を見送った。(B) は最初から床の位置そのものを
コマンドの性質に応じて設計し直すことで、同じ正しい方向をより低コストに実現している。

## Prevention

- ディレクトリ単位の権限制御を設計する前に、対象のルールが `ask`/`deny` に属していないか確認する。
  属していれば project scope では対処できない。
- `settings.json` の解決が skill / agent / command の解決と同じだと想定しない。親ディレクトリを
  遡って発見されるのは後者だけである。
- フックは権限を締めることしかできず、緩めることはできない。それを前提に設計する。
- 宣言的なゲートをスクリプト化したゲートに置き換える場合、そのスクリプトは fail closed
  （`exit 2`）でなければならず、必ずスモークテストを書く。

## Related Issues

- `docs/solutions/integration-issues/claude-code-defaultmode-auto-gh-command-gating.md` — 同じ
  権限モデルの先行事例。`defaultMode: auto` 下では「`allow` への非掲載 = ゲートではなく自動承認」を
  確立しており、それゆえ `allow` への列挙はメカニズムではなくドキュメンテーションに過ぎないという
  本ドキュメントの前提を裏付ける。
- `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md` — 本
  変更が緩めた git の `ask` ゲートを最初に導入したドキュメント。Task 2 が書き換えを迫られた
  `excludedCommands` のトレードオフ記述もここにある。
- `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` — 本変更の設計。
- Issue #225 — `gh api` のプレフィックスゲート残留課題。本変更の対象外で、状態も変わっていない。
