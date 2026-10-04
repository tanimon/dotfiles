---
status: accepted
date: 2026-10-04
---

# Deliver は push も PR の作成もせず、Review-Verify と同じ形で人間に報告する

Deliver は、実装・レビュー修正ループ・動作確認を終えた後に push と draft PR の作成をしていた。今後はそれをやめ、コミットはローカルのブランチに残し、報告(`report.md` / `ledger.json`)を Review-Verify と同じ形で人間に渡す。公開するかどうかは人間が報告とローカルのコミットを確かめてから決める。理由は2つある。PR の作成はレビュワーへの通知や `pull_request` トリガーの bot を起動する外向きの操作で、人間が中身を確かめる前に起こしたくない。また、仕事用のリポジトリでは PR 本文を `.github/pull_request_template.md` の節構成で書く決まりがあり、Workflow が組み立てる報告はその構成に合わない。

これにより Deliver と Review-Verify の違いは「実装から始めるか」だけになる。`dot_claude/workflows/deliver.js` から公開の機能(`publish` 列、Publish フェーズ、引数 `prBase`、返り値の `prUrl` / `published` / `publishError`、PR のタイトルにしか使わなかった plan エージェントの `title`)を取り除く。

## Considered Options

- **push だけして PR を作らない** — 却下。push も外向きの操作であり、公開の機能を「push」と「PR」に割ることになって、[ADR 0010](0010-review-verify-is-a-mode-of-the-deliver-workflow.md) が退けた独立したフラグに近づく。
- **`publish` 列を残して全 mode で `false` にする** — 却下。どの mode も使わない経路のコードとテストを保守し続けることになる。必要になれば git の履歴から戻せる。

## Consequences

- 入口 skill `/deliver` の結果の後処理を `/review-verify` に揃える。起動前の SHA を控え、`<起動前の SHA>..HEAD` を Workflow が足したコミットとして示す。履歴の書き換えと要件文書の書き換えを確かめる。ledger に記録の無い変更の突き合わせだけは揃えず、`git diff --stat` を示す。実装エージェントは変えたファイルを申告しない(ledger にはコミットしか残らない)ので、突き合わせると実装の差分がすべて記録の無い変更に見えるため。報告の書き出し先は `deliver/report.md` / `ledger.json`(Review-Verify の `deliver/review-verify/` とは分けたまま)。
- 報告には PR 向けの帰属行も「公開しない mode」の注記も付けない。どの mode で走ったかは統計の節の `mode` 行で分かる。
- Workflow はファイルを書き出さなくなる。報告と ledger は常に入口 skill が Write ツールで書き出す。
