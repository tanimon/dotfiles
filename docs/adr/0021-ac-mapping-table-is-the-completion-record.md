---
status: accepted
date: 2026-10-28
---

# 完了の記録は PR 本文の AC 対応表とし、close 済み issue の AC は同期しない

issue を解決したことの記録は、issue が close されたことと、それを解決した PR 本文の AC 対応表(issue の Acceptance criteria の各項目を、どの変更が満たしたか、満たさない理由は何か)の 2 つとする。issue 本文の AC のチェックボックスは作業中の目安にとどめ、close した後に `[x]` へそろえることはしない。チェックボックスをマージ後にそろえる照合を手動で起動する方式は、導入した後も誰も回さず、導入後に close された 34 件の issue で AC が `[ ]` のまま残った。一方の AC 対応表は PR を作るときに書かれ、PR Body Review が差分に合わせて最新に保つ。そのため close 済みの issue に `[ ]` が残っていても、未完了を意味しない。

## Considered Options

- **マージ時に自動で `[x]` にする(GitHub Actions、または週次の自己改善ジョブ)** — 却下。PR は主に GitHub の UI でマージするので、自動化するにはどちらかの経路が要る。どちらも、close した後に誰も読まないチェックボックスをそろえるためだけに、仕組みを 1 つ保守することになる。
- **手動の照合(`/ticket audit`)を続ける** — 却下。上に書いたとおり実際には回らなかった。照合は、このほかの種類(relationship の食い違い、close 漏れ)でも 0 件か雑音だったので、照合モードごと廃止した。

## Consequences

- close 済み issue の AC を読んで完了したかを判断してはいけない。AC 対応表は、その issue を閉じた PR の本文を見る。
- `Closes` による自動 close は既定ブランチへのマージでしか効かない。stacked PR の下の段がマージされたときの close 漏れは検出しない。起きうることは承知のうえで受け入れる。

## 追記: PR Body Review は当面、人が起動したときだけ走る(#698)

本文の「AC 対応表は PR を作るときに書かれ、PR Body Review が差分に合わせて最新に保つ」は、PR Body Review が自動では走らなくなったため、そのままでは成り立たない。対話版の `pr-body-review` スキルに `disable-model-invocation: true` を付けたので、AI は push の後に自分から本文を見直さず、人が `/pr-body-review` を打ったときだけ走る。無人で案を作る `pr-body-review-unattended` はあるが、それを呼ぶ無人の呼び出し元はまだ無い。

本文が却下した「手動で起動する方式は回らない」と同じ危険を、当面は承知のうえで受け入れる。そのため、マージされた PR の AC 対応表が、マージ時点の差分に追いついているとは限らない。

結論は変わらない。完了の記録は、issue を閉じた PR 本文の AC 対応表であり、close 済み issue の AC は同期しない。無人の呼び出し元が `pr-body-review-unattended` を呼ぶようになったら、この追記を更新する。
