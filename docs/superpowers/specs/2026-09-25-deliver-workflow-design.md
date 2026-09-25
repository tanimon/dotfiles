# deliver ワークフロー設計

plan を受け取り、実装、レビュー修正ループ、動作確認を経て draft PR と人間への報告までを agent が自律で行う。方式の選定理由は [ADR 0007](../../adr/0007-deliver-workflow-enforces-review-loop-in-code.md)、用語(Review Finding / Deferred Finding / Unresolved Finding / Plan Concern)は `CONTEXT.md` の「Autonomous delivery」節を参照。本書は 2026-09-25 の grilling セッションで合意した内容を記録する。

## 適用範囲

- 対象は個人リポジトリと仕事リポジトリの両方。リポジトリごとに違うもの(動作確認 skill、テスト/lint コマンド)は起動時の引数で受け取る。
- 入力は実装計画(タスクに分解済みの plan)だけ。spec や PRD しか無い場合は受け付けない。plan 化は判断の塊なので、自律実行の範囲に入れない。
- 作業場所は、既にある feature ブランチ(worktree)に限る。`main` / `master` / `development`、または detached HEAD であれば、入口の skill がその場で中止する。worktree とブランチはワークフロー自身では作らない。

## 構成

| 部品 | 置き場所 | 役割 |
|---|---|---|
| 入口 skill | `dot_claude/skills/deliver/SKILL.md` → `~/.claude/skills/deliver/` | ブランチと plan を検査する。動作確認 skill・テスト/lint コマンド・上限回数を集め、未指定のものは `AskUserQuestion` で聞いてから Workflow を起動する |
| Workflow | `dot_claude/workflows/deliver.js` → `~/.claude/workflows/deliver.js` | ループ・判定・報告の組み立てをコードで行う。入口 skill は `Workflow({scriptPath: "~/.claude/workflows/deliver.js", args})` で呼ぶ |

Workflows は実行中に人間へ質問できないので、質問は必ず入口 skill で済ませる。ユーザーが skill を起動し、その skill の指示で Workflow を呼ぶ形が、Workflow ツールの認める明示的な opt-in になる。

## フロー

1. **plan の分解**: plan からタスク一覧を抽出する。
2. **実装**: タスクごとに新しい実装エージェントを順に起動する。各エージェントは TDD で進め、テスト/lint コマンドを通してからコミットする。この段ではレビューをしない。タスクが続行不能になったら、その場で停止して報告する。
3. **レビューループ**(修正ラウンドの上限 `maxReviewRounds`、既定 3。修正のたびに再レビューするので、レビューは最大で上限+1回。上限はループに入るたびに数え直す)。各ラウンドは次の順で進む。
   1. テスト/lint コマンドを通す。落ちていれば修正してから進む(落ちたままレビューすると、指摘が lint エラーの言い換えで埋まるため)。
   2. 2本のレビュアーを並列に実行する: `ecc-code-review`、`superpowers:requesting-code-review`。built-in の `code-review` も合意時点では含めていたが、Workflow のエージェントからは使えないと実測で分かったため外した(下の「試作で実測すること」)。
   3. 統合エージェントが重複をまとめ、指摘ごとに識別子(ファイル・位置・種類)を振る。統合エージェントに任せるのは重複をまとめることだけで、判定の入力(重大度・code か plan か・planBreaking)は元の指摘からコードが導く。統合エージェントがどの cluster にも入れなかった指摘は、単独の cluster として扱う。Deferred / Unresolved 済みの識別子に統合された修正必須指摘は、判定からは外すが、元の指摘の内容を報告に残す。
   4. 判定はコードで行う。修正必須になるのは、ecc の CRITICAL/HIGH、requesting の Critical/Important のいずれかを含む指摘。それ以外は参考扱いとし、報告にだけ載せる。
   5. plan 自体に向けた指摘は Plan Concern とし、修正しない。そのうち「plan どおりに作ると壊れる」ものがあれば即座に停止する。
   6. 修正必須がゼロになったらループを終える。
   7. 前のラウンドと同じ識別子の修正必須指摘が再び出たら、その指摘は修正対象から外して Unresolved Finding にする。
   8. 修正エージェントは、指摘ごとに「修正した」か「見送りを提案する」を返し、ラウンドごとに1コミットする。見送りの提案は、実装の経緯を渡さない新しい検証エージェントが同意した場合だけ Deferred Finding になる。同意しなければ修正必須に戻り、次のラウンドでは再出現として扱わずに、却下理由を添えてもう1回だけ修正に回す(2回目も見送りが却下されて再出現すれば Unresolved Finding になる)。
   9. 上限に達した時点で残っている修正必須指摘は Unresolved Finding にする。修正した後、再レビューで確かめる前に止まった場合(テスト/lint の失敗、レビュアーの全滅、予算、例外)も、その指摘は Unresolved Finding にする。
   10. 最後のラウンドで結果を返さなかったレビュアーがいれば、報告の先頭で警告する(収束の根拠が不完全なため)。
4. **動作確認**: 指定された skill を実行する。失敗したら、修正エージェントに失敗内容を渡して直させ、その修正を含めてレビューループに入り直す(再挑戦の上限は `maxVerifyRetries`、既定 2)。上限に達しても失敗していれば、失敗として報告する。
5. **公開**: push して draft PR を作る。本文は下記「報告」の構成で、コードが組み立てる。同じ内容を ledger に保存し、Workflow の `return` でセッションにも返す。

作業中に気づいたスコープ外の問題は、どのエージェントにも出力スキーマの `observations` として返させ、報告にまとめる。外部(Notion、GitHub Issue)への起票はしない。

## 報告

人間の判断が要るものほど上に置く。

1. Unresolved Finding
2. Plan Concern
3. 閉じた指摘に統合された修正必須指摘(ある場合だけ)
4. 動作確認の結果(失敗していれば、このリストの先頭に上げる)
5. Deferred Finding(検証者が同意した理由を付ける)
6. 参考指摘(修正必須ではない指摘)
7. observations
8. 統計

エージェントの例外(予算の上限到達など)で途中終了しても、その時点の状態で報告を組み立て、公開を試みる。公開に失敗しても報告は返す。(ラウンド数、ラウンドごとの修正必須指摘の件数、消費トークン)

## 状態(ledger)

`$(git rev-parse --git-dir)/deliver/ledger.json` に最終状態を保存する。この場所は worktree ごとに分かれ、git の追跡対象にならず、`.gitignore` への追記も要らない。スクリプト自身はファイルに触れないので、書き込みは公開の段のエージェントが行う。書き写しの欠落・要約を検出するため、書き出しと push / PR 作成を別のエージェントに分け、書き出したファイルの行数とバイト数をスクリプトが元の文字列と突き合わせる。一致しなければ1回だけ書き直させ、それでも合わなければ PR を作らない。ledger から途中を再開する機能は、試作の範囲に含めない。

## コスト

`budget.total` が設定されている場合は、各ラウンドの開始前に残量を確認し、足りなければ次のラウンドに入らずに公開の段へ進む。既定の上限値は、試作を数回実行して計測してから決める。試作の段階では、統計に `budget.spent()` を記録するだけにとどめる。

## 試作で実測すること

| 項目 | 結果 |
|---|---|
| Workflow のエージェントから Skill ツールで `ecc-code-review` / `code-review` / `superpowers:requesting-code-review` を読み込めるか | 2026-09-25 実測。`ecc-code-review` と `superpowers:requesting-code-review` は本文を読み込めた。built-in の `code-review` は fork 型の skill で、呼ぶと本文が返らず別エージェント(`@code-review`)として起動し、その結果は Workflow のエージェントではなく親セッションに届いた。このため deliver のレビュアーからは外す |
| workflow エージェントが `$(git rev-parse --git-dir)/deliver/` に書き込めるか(この repo の worktree と、仕事リポジトリの worktree の両方) | 2026-09-25 実測。両方とも書き込めた(chezmoi の worktree の `.git/worktrees/<name>`、仕事リポジトリの worktree の `.git/worktrees/<name>`)。ledger は git-dir に置く |
