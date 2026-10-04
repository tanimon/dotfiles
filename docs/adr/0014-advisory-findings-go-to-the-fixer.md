---
status: accepted
date: 2026-10-03
---

# 参考指摘も修正エージェントに渡し、`receiving-code-review` で判断させる

Deliver / Review-Verify のレビューループでは、修正必須にならない指摘(ecc の MEDIUM/LOW、requesting の Minor)は報告に載せるだけだった。そのため、直す価値のある指摘も人間の手作業として残った。今後は、これらの指摘(Advisory Finding)も修正エージェントに渡す。修正エージェントは `superpowers:receiving-code-review` で各指摘を評価し、直すか、理由を付けて見送る。修正必須の契約は [ADR 0007](0007-deliver-workflow-enforces-review-loop-in-code.md) のまま変えない。Advisory を見送るのに検証者は要らず、Advisory は収束条件にも上限到達時の Unresolved にも数えない。結果を修正必須と参考のどちらとして扱うかは、エージェントの申告ではなく、その key をどちらとして渡したかでコードが決める。設計は `docs/superpowers/specs/2026-10-03-review-advisory-fix-design.md`。

## Considered Options

- **修正必須の重大度を MEDIUM / Minor まで広げる** — 却下。nit はラウンドごとに出直すので、上限に達して Unresolved が増える。見送りのたびに検証者も起動することになる。
- **トリアージ専用のエージェントを置き、直す価値のあるものだけを修正必須に昇格させる** — 却下。エージェントが1体増えるうえ、昇格させた指摘が収束条件に入るので、上の案と同じ問題が残る。
- **ecc の機械的な Code Quality 指摘(行数・ネスト・console.log・TODO・JSDoc)は報告だけに残す** — 却下(ユーザーの判断)。ADR 0007 がこれらを MEDIUM に下げたのは「修正必須にしない」ためで、その役割は残す。そのうえで直すかどうかは修正エージェントの判断に委ねる。

## Consequences

- `receiving-code-review` が判定するのは「指摘が正しいか」で、「直す価値があるか」は判定しない。正しい nit はほぼ直されるので、指示していないリファクタリングが人間のブランチにコミットされやすくなる。報告の「修正した指摘」と `fixChanges` で追えるようにしておく。
- この skill は人間に質問する前提で書かれている。非対話の Workflow では、「人間に聞く」場面を理由付きの見送りに読み替えるよう、prompt で指示する。
- Advisory だけを直すラウンドも `maxReviewRounds` を1つ消費し、修正の後には必ず再レビューを通す。修正必須が無くても、ラウンド数とエージェント数が増える。修正に回す範囲は、最初のラウンドで出た Advisory に狭めてある([ADR 0016](0016-only-first-round-advisory-findings-go-to-the-fixer.md))。
