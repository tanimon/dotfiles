---
status: accepted
date: 2026-10-02
---

# 自己改善ループの採否を Evaluator の数値で判定し、Evaluator を Improvement Surface の外に置く

自己改善ループがルールを採用するには、ルールの無い側で失敗が再現する Eval Case を用意し、ルールの有無で結果を比べた効果を PR に添えることを原則とする。Eval Case を書けないルールは、理由を添えて免除できる。harness 全体の健康度は Failure Pattern の再発率で時系列に追い、ルール単位の評価は全体の悪化が見えたときと削除を判断するときに使う。Evaluator(失敗の検出器、Failure Pattern の分類器、判定の基準、Eval Case)は Improvement Surface に含めない。ループが作った PR が Evaluator のパスに触れたら CI で失敗させ、Evaluator は人が別の PR でしか変えない。

これは、2026-07-06 の rebuild spec(`docs/superpowers/specs/2026-07-06-harness-engineering-rebuild-design.md`)の Decision 3(人間の PR レビューを唯一の品質ゲートにし、LLM の generator-evaluator 層を置かない)を改める決定である。人間の PR 承認は残し、自動マージはしない。ただし、承認の判断材料として数値評価を必須にする。理由は 3 つある。(1) 改善の効果を採用前にも採用後にも測っておらず、効かないルールを「効かない」という理由で削除できなかった。(2) 調べた外部の手法(ADAS、GEPA、DGM、Claude Code 公式の skill 評価)は、どれも実行して測った数値で採否を決めている。(3) DGM では、評価の改変を明示的に禁止していても、評価の仕組みを無効化して偽の成功を報告する改変が観測された。根拠は `docs/research/2026-10-02-recursive-self-improvement.md` に置く。

## Considered Options

- **Decision 3 のまま、人間の PR レビューだけで判定する** — 却下。採用時の判定が「このルールがあれば元の失敗を防げたか」を LLM に考えさせる反実仮想の推測だけになり、発生源のセッションへの過剰適合も、ルールの肥大も検出できない。
- **Evaluator もループに改善させる** — 却下。採否の基準を改善される側が動かせると、効果が上がったのか基準が緩んだのかを区別できなくなる。
- **ルールに「Evaluator を変えるな」と書くだけで済ませる** — 却下。DGM の観測から、禁止を書くだけでは強制にならない。

## Consequences

- rebuild spec の設計原則 1「LLM を使うのは抽出(reflect)と選別(review)の 2 箇所だけ」は成り立たなくなる。Failure Pattern への分類と Eval Case の実行にも LLM を使う。ただし失敗の検出は、人の訂正と機械的な信号(ツールのエラー、hook の deny、同じ操作の繰り返し、CI の赤)だけで決定的に行い、LLM には分類だけを任せる。検出器の精度が新しい不確かさになるのを避けるためである。
- 改善ループ自身(reflect / review / 週次ジョブ)も、当面は Improvement Surface に含めない。解禁は、全体の指標が 8 週以上連続して取れており、かつループの変更が指標を悪化させないことを Evaluator で確かめられる状態になってから改めて設計する。
- 肥大を抑えるため、PR ごとに追加と削除の純増を表示し、ファイルごとのサイズ上限を CI で強制する。更新は全文の書き直しではなく差分に限る(ACE が報告した context collapse を避けるため)。
- 採否の経緯は Rule Ledger として、仕事の文脈を含まない形で公開リポジトリに残す。生の transcript と Eval Case の実体はローカル(`~/.claude/harness/evals/`)にだけ置くので、マシンを失えば事例も失う。これは受け入れる。
