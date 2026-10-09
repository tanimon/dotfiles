---
status: accepted
date: 2026-10-09
---

# Verdict は LLM が直接書かず、harness-verdict.sh を通してだけ記録する

自己改善ループの選別は、queue の項目を `queue-archive.md` へ移して Verdict 行を付ける。これまでは LLM が SKILL.md の散文の書式に従って Markdown を直接書き、週次ジョブと rule-ledger はその行を grep と awk の 6 箇所で別々に解析していた。週次ジョブの採用の印(`adopted (<branch> run <id>)`)は prompt に埋め込んで LLM に書き写させており、テストの偽の claude はその印を prompt の文章から正規表現で抜き出していた。そこで、Verdict の書き込みと読み取りを `harness-verdict.sh` の 1 本の CLI に集め、LLM は `settle` サブコマンドを呼んで記録する。印は週次ジョブが渡す環境変数 `HARNESS_REVIEW_RUN` から CLI が付け、prompt には現れない。記録は今の Markdown のまま残し、読み取りは過去の手書きの行も読める寛容な形、書き込みは enum と必須の引数を持つ厳格な形にする。

## Considered Options

- **LLM に Edit で書かせたまま、読み取りだけを module にまとめる** — 却下。印の書式が prompt と偽の claude に漏れたまま残る。項目の移動と Verdict 行の付与も別々の操作のままなので、「Verdict 行の無い項目」や「queue に残ったままの採用」が起こりうる。
- **機械向けの JSONL を記録の正本にし、Markdown をそこから生成する** — 却下。既存の archive の移行が必要になる。形式の知識が CLI の内側に閉じていれば、Markdown のままでも解析の脆さは 1 箇所に収まる。
- **印を環境変数ではなく、prompt が指す manifest のファイルで渡す** — 今回は採らない。`claude -p` の Bash ツールが親の環境変数を引き継ぐことを実測で確かめたため、環境変数で足りる。結果ファイルなどのパスを manifest で渡す変更は、別に検討する。

## Consequences

- harness-review の SKILL.md の Bookkeeping は、Markdown の書式ではなく CLI の呼び出しを指す。手動の `/harness-review` も同じ CLI を通る。
- CLI とその bats は Guarded Path に載る。ループの PR からは Verdict の書式も解釈も変えられない。
- 過去の手書きの行のうち読めないものは `kind: "unknown"` として出し、移行はしない。
- 読み手は `kind` と `pr_url` / `run` / `arg` で選び、Verdict 行を文字列で照合しない。CLI が無いか失敗したとき、読み手は「Verdict が無い」とは読まずに失敗する。
- 括弧の中が `PR ` で始まる採用は常に `pr_url` として読み、`run` には入れない(未公開の採用とみなさない)。`pr_url` は閉じ括弧の手前までをそのまま返すので、URL の後ろに補足を書いた採用(`adopted (PR <URL>, 補足)`)は Rule Ledger の照合にも URL の検査にも当たらない。括弧の無い `adopted` は unknown になり、採用として扱われない。
- CLI へは読み手と書き手を 1 つずつ移す。週次ジョブの印の書き込みと照合、harness-review skill の Bookkeeping は、`settle` などのサブコマンドに移すまで CLI の外にも書式を持つ(移す範囲は #490)。
