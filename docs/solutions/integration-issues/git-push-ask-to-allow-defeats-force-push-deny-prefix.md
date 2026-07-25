---
title: "ask から allow への移動は deny のプレフィックスが捕らえる範囲を超えて広がる"
date: 2026-07-25
category: docs/solutions/integration-issues
module: dot_claude/settings.json.tmpl
problem_type: integration_issue
component: tooling
symptoms:
  - "`Bash(git push:*)` を ask から allow へ移した結果、`git push origin main --force` が承認プロンプトなしで実行可能になっていた"
  - "deny の force-push 3 件はプレフィックスルールのため、フラグが `git push` の直後に来る綴りにしかマッチしない"
  - "`git push origin +main` / `git push --delete origin foo` / `git push origin :foo` / `git push --mirror` も deny を素通りする（後者 3 つは append-only ですらない）"
  - "deny 配列はバイト単位で不変だったため、diff 上は防御が減っていないように読めた。実際に効いていたのは広い ask だった"
root_cause: config_error
resolution_type: config_change
severity: high
tags: [claude-code, permissions, prefix-matching, git-push, force-push, ask, allow, deny, risk-tier-model, settings-json]
---

# ask から allow への移動は deny のプレフィックスが捕らえる範囲を超えて広がる

## Problem

`dot_claude/settings.json.tmpl` の `permissions` に対し、git/gh の書き込みコマンドを 4 段階の
リスク Tier モデル（Tier 0 ローカルかつ可逆 / Tier 1 既存コンテナへの append-only / Tier 2
共有オブジェクトの状態を変更 / Tier 3 破壊的または履歴書き換え）で再分類し、Tier 0・Tier 1 と
判定した 6 件を `ask` から `allow` へ移す変更を行った（PR #240、本稿執筆時点で open・未マージ）。

その 6 件のうち `Bash(git push:*)` を **Tier 1（append-only）** と分類し、根拠をこう書いた
（PR #240 の初期状態の `CLAUDE.md`。当該コミットの SHA は squash merge で書き換わるため PR 番号で参照する）:

> All three force-push forms (`--force`, `--force-with-lease`, `-f`) stay in `deny` — that
> `deny` is precisely what makes `push` append-only and therefore Tier 1.

**この根拠は誤りだった。** Claude Code の `permissions` は `deny > ask > allow` の優先順で
**プレフィックスマッチ**により評価され、最初にマッチしたルールが勝つ。`deny` に置かれた
force-push 3 件（`dot_claude/settings.json.tmpl:102-104`）は
`Bash(git push --force-with-lease:*)` / `Bash(git push --force:*)` / `Bash(git push -f:*)` で
あり、フラグが `git push` の**直後に来る綴りにしかマッチしない**。`git push` を `allow` に
置いた瞬間、以下はすべて `deny` を回避して `Bash(git push:*)` にマッチし、プロンプトなしで
実行される状態になっていた。

| コマンド | 実効 | deny を回避する理由 |
|---|---|---|
| `git push origin main --force` | force overwrite | フラグが末尾で、`git push` の直後ではない |
| `git push origin main -f` | force overwrite | 同上 |
| `git push origin +main` | force overwrite | `+` refspec — 対応する綴りが `deny` に一つも無い |
| `git push --delete origin foo` | リモートブランチ削除 | append-only ですらない。対応する `deny` 無し |
| `git push origin :foo` | リモートブランチ削除 | 同上（旧綴り） |
| `git push --mirror` / `--prune` | リモート ref の一括削除 | 同上 |

変更前は広い `Bash(git push:*)` が `ask` に座っており、**すべての綴り**を捕らえていた。これを
`allow` へ移したことで、force-push とリモートブランチ削除が「プロンプトあり」から「無言実行」へ
変わった。`deny` 配列はバイト単位で変更前後同一である。にもかかわらず**実効的な防御は低下した**。

さらにこの誤った主張は、レビューで捕捉されるまでに `CLAUDE.md`・設計仕様
（`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`）・新規に書いた
solutions ドキュメントの 3 箇所へ伝播していた。

### 同じ段落が同じ原理を 2 箇所で正しく適用していた

本件で最も教訓的なのはここである。誤った `push` の根拠を書いた時点の `CLAUDE.md`
は、**まったく同じ段落の中で**同じフラグ位置の問題を他の 2 コマンドについては正しく診断して
いた。

- `git reset` — `Bash(git reset --hard:*)` を `ask`、`Bash(git reset:*)` を `allow` に分割
  する案を、「`git reset HEAD~1 --hard` がプレフィックスマッチを破る」ため不採用と明記して
  いた。
- `gh api` — write 意図が固定プレフィックスではなく `--method` フラグに宿るためプレフィックス
  ではゲート不能、と明記していた（この指摘自体は #224 由来で、
  `docs/solutions/integration-issues/claude-code-defaultmode-auto-gh-command-gating.md` に既出）。

つまり著者は同一段落内で原理を 2 回適用し、3 回目で外した。**原理を知っていることと、それを
一貫して適用することは別である。** そして「append-only」という魅力的な物語を持つ Tier モデルは、
すでに自分で書き下した原理を上書きしうる。

## Symptoms

- `Bash(git push:*)` が `allow` にある状態で、`git push origin main --force` が承認プロンプト
  なしに実行可能だった（`deny` の 3 件はいずれもマッチしない）。
- `git push --delete origin foo` / `git push origin :foo` によるリモートブランチ削除が同様に
  無ゲート。これらは append-only ですらないため、Tier 1 の定義そのものに反していた。
- `deny` 配列は変更前後で同一だったため、diff を見る限り「防御は何も減っていない」ように読めた。
  実際に減っていたのは `ask` 側であり、そこが本当に効いていた。
- 変更に付随する `jq` アサーション（`docs/superpowers/plans/2026-07-25-permission-tier-model.md`
  Step 1）は **PASS していた**。配列メンバーシップと件数しか検査しておらず、マッチャの意味論を
  検査していなかったため。

## What Didn't Work

### Tier モデルの物語をマッチャの意味論より優先した

「push は既存ブランチに追記する」は**典型的な起動形の性質としては真**だが、**コマンド表面全体の
性質としては偽**である。Tier は概念から割り当てられたのであって、マッチャが実際に強制できる
ものから割り当てられていなかった。分類の単位はコマンドの意味ではなく、権限ルールが表現できる
文字列パターンでなければならない。

### `deny` が不変であることを防御が不変であることと同一視した

`deny` は変更前後でバイト単位に同一だった。しかしリグレッションは、`deny` ではなく広い `ask` を
外したことから 100% 発生している。狭い `deny` 3 件は、広い `ask` の隣ではほぼ装飾でしかなかった。
**`deny` 差分がゼロであることは、実効防御が不変であることの証拠にならない。**

### フラグ単位への分割（代替案として検討し、却下）

`Bash(git push --delete:*)` / `--mirror:*` / `--prune:*` を `deny` に追加して穴を塞ぐ案を検討し、
**却下した**。理由は `reset` を分割しなかったのと同一で、引数順がプレフィックスマッチを破るから
である。この追加は先頭フラグの綴りしか閉じない一方、末尾フラグ形（`git push origin foo --delete`）
と `+refspec` 形は開いたまま残る。結果として**防御が実際より強く見える**という、元の欠陥と同型の
状態を作る。将来の読者はほぼ確実にこの案を提案するため、却下の事実と理由をここに残す。

### 配列メンバーシップのアサーション

実装計画は `chezmoi execute-template` の出力に対し `jq -e` で「移動対象 6 件が `allow` に在る」
「`ask` に残っていない」「`allow`/`ask`/`deny` の件数が期待値と一致する」等を検証していた
（`docs/superpowers/plans/2026-07-25-permission-tier-model.md:66-100`）。これは意図どおり動作し
**PASS した**。しかし検査していたのは配列の中身であって、マッチャの挙動ではない。この欠陥クラスは
メンバーシップのアサーションでは原理的に検出できない。

## Solution

- **`Bash(git push:*)` を `permissions.ask` へ戻した**（`dot_claude/settings.json.tmpl:175`。
  `Bash(git cherry-pick:*)` `Bash(git filter-branch:*)` `Bash(git rebase:*)` `Bash(git reset:*)`
  と並ぶ）。移動する entry は 6 件から **5 件**（`git commit` / `git merge` / `git revert` /
  `gh pr comment` / `gh issue comment`）になった。
- **force-push 3 件は `deny` に据え置き**（`dot_claude/settings.json.tmpl:102-104`）。削除する
  理由は無いが、これらが担う範囲を過大評価しない。実際に force-push とリモートブランチ削除を
  止めているのは `ask` の `Bash(git push:*)` である。
- **誤った append-only 主張を全ドキュメントから撤回**した。`CLAUDE.md:69` の governance 段落は
  「`push` は意図的に Tier 1 と分類**しない** — プレフィックスマッチでは append-only 性を確立
  できない」と述べ、evade する綴りを列挙する記述に置き換えた。設計仕様の冒頭には訂正ノートを
  置き（`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md:7-18`）、`push` を
  「not Tier 1」として理由付きで表に残した（同 :129）。
- **Tier モデル自体は維持**した。Tier の定義は変更していない。`push` が Tier 1 の**メンバーでは
  ない**だけである。
- **Tier 1 の要件を追加**した: Tier 1 への所属は、append-only 性が単に一般的な起動形について
  真であるだけでは足りず、**マッチャによって強制可能**でなければならない。フラグをプレフィックスの
  外へ動かすことで破壊的な綴りに到達できるコマンドは Tier 1 になれない
  （`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md:98-100`）。
- **再利用可能な落とし穴として `CLAUDE.md:172` に記載**した（Known Pitfalls）。
- **`ask` 配列直上のコメント**（`dot_claude/settings.json.tmpl:132`）にも、`push` が `ask` に
  留まる理由（force-push の `deny` はプレフィックスのみ、末尾フラグ・`+refspec`・`--delete`/
  `:branch` が回避する）を設定ファイル内に埋め込んだ。ドキュメントを読まずに配列だけを編集する
  読者に届く位置に置くことが目的である。

## Why This Works

`ask` は `allow` より優先され、`bypassPermissions` 下でも発火する。そして重要なのは**広さ**で
ある。`Bash(git push:*)` は `git push` で始まるあらゆる呼び出しにマッチするため、引数がどこに
どう並ぼうと関係なく捕らえる。狭い `deny` はプレフィックス位置に依存するが、広い `ask` は
依存しない。これが「狭い `deny` は広い `ask` の代替にならない」の技術的な中身である。

このリポジトリは `permissions.defaultMode: "auto"`（`dot_claude/settings.json.tmpl:179`）で
動作するため、**未列挙 = 自動承認**である
（`docs/solutions/integration-issues/claude-code-defaultmode-auto-gh-command-gating.md` 参照）。
この前提の下では、あるコマンドの危険な綴りをゲートする方法は「その綴りにマッチするルールを
`ask` か `deny` に置く」ことしかない。`deny` にプレフィックス的な部分集合しか置けないなら、
その補集合をカバーするのは広い `ask` の役目になる。

`git push` は `sandbox.excludedCommands` にも含まれ（`dot_claude/settings.json.tmpl:469`）、
サンドボックス外で実行される。したがって承認ゲートが唯一の統制であり、`ask` を外すことは
「サンドボックス境界も承認ゲートも無い」状態を作ることを意味した。

`push` を Tier 1 から外しても Tier モデルは壊れない。Tier 1 に残る `gh pr comment` /
`gh issue comment` は、コマンド表面のどこにもフラグで破壊的挙動へ切り替わる経路が無く、
append-only 性がマッチャのレベルで成立している。追加した「強制可能性」要件は、Tier 1 の
判定を概念的な妥当性からマッチャの表現力へ接地させるもので、モデルを弱めるのではなく
適用条件を明示している。

## Prevention

### 一般化されたルール

**狭い `deny` は広い `ask` の代替にならない。** これは git に限らない。`ask` から entry を
外す前に、**残る `deny` ルールがマッチ*しない*引数の綴りを列挙する**こと。write 意図がフラグ位置や
引数へ移動しうるなら（`--force` の後置、`+refspec`、`--method POST`、`-X DELETE`）、
プレフィックスルールが与える防御は見かけ倒しであり、その entry は `ask` に留める。

### チェックリスト（`ask` → `allow` の移動を提案する前に実行する）

1. 対象コマンドの man / `--help` を開き、**破壊的な挙動へ切り替えるフラグと引数形**をすべて
   列挙する（後置フラグ、短縮形、`+`/`:` のような refspec 記法、旧綴りを含む）。
2. 列挙した各綴りについて、`deny` のどのルールがマッチするかを実際に照合する。マッチしない
   綴りが 1 つでもあれば、その entry は `allow` に移せない。
3. 「典型的な起動形では安全」を根拠にしない。**コマンド表面全体**で判定する。
4. `deny` の diff が空であることを安全性の根拠に使わない。実効防御が変化したかは、`ask` から
   何が消えたかで決まる。
5. フラグ単位の `deny` 追加で穴を塞ぐ案が出たら、その追加が**先頭フラグ位置の綴りしか閉じない**
   ことを確認する。閉じきれないなら、防御が強く見えるだけ悪化する。
6. 同じ変更セットの中で、同種の原理を他コマンドに適用している記述が無いか探す。あるなら、
   その原理を対象コマンドにも当てはめる。

### 検証手法のギャップ

**配列メンバーシップのアサーションはマッチャの意味論を検査しない。** 本件の `jq` アサーションは
設計どおり動作して PASS したが、それは「`git push` が `allow` 配列に在る」ことを確認したに
すぎない。この欠陥クラスを捕らえるのは次の形の検査である:

> `git push origin main --force` は `deny` のいずれかにマッチするか?

現時点でこのリポジトリにこれを検査する仕組みは無い。マッチャ意味論のテストは、Claude Code の
プレフィックスマッチ規則を外部で再実装せずに書くのが難しく、本 PR のスコープでは追加していない
（既知のギャップとして記録する）。当面は上記チェックリストによる人手のレビューに依存する。

### 運用上の注意

- 権限配列に手を入れる際は `dot_claude/settings.json.tmpl:132` の `ask` 直上コメントを必ず読む。
  ここに `push` を `ask` に留める理由が埋め込まれている。
- レンダリング検証は `make check-templates` と
  `chezmoi execute-template --config <test toml> --source "$(pwd)"` を用いる
  （`--init --promptString` では `.data` が埋まらない — `CLAUDE.md` の既知の落とし穴）。

## Related Issues

- `docs/solutions/integration-issues/claude-code-defaultmode-auto-gh-command-gating.md` —
  `defaultMode: auto` 下では「未列挙 = 自動承認」であることを確立し、`gh api` の write 意図が
  `--method` フラグに宿るためプレフィックスゲート不能である点をすでに記録していた先行文書。
  本件は**その同じ制約を見落とした**ケースである。
- `docs/solutions/integration-issues/claude-code-ask-rule-cannot-be-relaxed-per-directory-2026-07-25.md`
  — 同じ作業から生まれた対になる学び（`ask` はディレクトリ単位で緩められない「床」であり、
  既定値ではない）。本件は「その床を外すと何が落ちるか」の側面を扱う。
- `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` — Tier モデル本体。
  冒頭の訂正ノート、`push` を not Tier 1 とする根拠、および本件の結果として追加された
  Tier 1 の強制可能性要件を含む。
- `docs/superpowers/plans/2026-07-25-permission-tier-model.md` — 実装計画。PASS したが本欠陥を
  捕らえられなかった `jq` アサーションを含む。
- `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md` —
  `git push` が `sandbox.excludedCommands` に入っている経緯（承認ゲートが唯一の統制になる理由）。
- PR #240 — 本変更。本稿執筆時点で open・未マージ。
