---
status: accepted
date: 2026-10-09
---

# Verdict は LLM が直接書かず、harness-verdict.sh を通してだけ記録する

自己改善ループの選別は、queue の項目に Verdict(adopted / rejected / handoff / merged)を付けて判定の記録(`~/.claude/harness/queue-archive.md`)へ移す。Verdict の書式を知っている箇所は、書き手(harness-review skill の散文を読んで Edit する LLM と、週次ジョブの prompt に埋め込んだ採用の印)、読み手(週次ジョブの 5 つの関数と Rule Ledger のスクリプトの grep / awk)、テスト(prompt から印を正規表現で抜き出す偽の claude)に散らばっていた。書式を 1 つ変えるのに 4 ファイルを同時に直す必要があり、項目の移動と Verdict 行の付与が LLM の別々の操作なので片方だけが済んだ状態も起こりえた。

そこで、Verdict の書き込みと読み取りを 1 本の CLI(`dot_claude/scripts/executable_harness-verdict.sh`)に集める。LLM・週次ジョブ・Rule Ledger のスクリプトは、どれもこの CLI を子プロセスとして呼んで Verdict を扱う。判定の記録は今の Markdown のまま変えず、唯一の正本とする。

- **読み取りは寛容にする。** 項目ごとに最初の Verdict 行と Source 行を使い、過去の手書きの行(括弧の無い rejected、Verdict 行の無い項目)は `kind: "unknown"` として生の文字列付きで返す。既存の記録は移行しない。
- **書き込みは厳格にする。** kind は enum で、必須の引数を持ち、Verdict 行の構文を壊す文字(改行、閉じ括弧)を含む引数は書き込む前に拒む。採用の印は週次ジョブが渡す環境変数から CLI 自身が付け、prompt には現れない。
- **印の文面は変えない。** `adopted (<branch> run <id>)` と `adopted (PR <URL>)` を保ち、過去の失敗した run が残した印もそのまま読めるようにする。
- **CLI は Guarded Path に置く**(ADR 0011)。判定の解釈を書き換えると、Rule Ledger が記録する採用や、週次ジョブが未公開とみなす採用を選び替えられるため。

サブコマンドの一覧と書式の解釈の正本は CLI のヘッダにある。全体の設計は親の spec(#490)にある。

## Considered Options

- **source して使う lib にする** — 却下。呼び出し側の adapter が 1 つしかない seam になり、LLM は lib を source できないので、書き手を同じ interface に揃えられない。
- **判定の記録を JSON Lines に移す** — 却下。過去の記録の移行が要るうえ、人が読んで直す記録としての読みやすさを失う。読み取りの寛容さで過去の行を扱えば移行は要らない。
- **LLM に書式を守らせたまま、読み手だけを 1 か所にまとめる** — 却下。書き手の綴りの誤り(印の書き写しの誤り、移動と付与の片方だけ)が残り、prompt の文言とテストの結合も解けない。

## Consequences

- 読み手は `kind` と `pr_url` / `run` / `arg` で選び、Verdict 行を文字列で照合しない。
- 括弧の中が `PR ` で始まる採用は常に `pr_url` として読み、`run` には入れない(未公開の採用とみなさない)。括弧の無い `adopted` は unknown になり、採用として扱われない。
- CLI が無いか失敗したとき、読み手は「Verdict が無い」とは読まずに失敗する。
