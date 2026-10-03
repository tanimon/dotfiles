# 参考指摘の修正(deliver / review-verify)

レビューループで修正必須にならない指摘(参考指摘)も、修正エージェントに渡して直させる。判断は `superpowers:receiving-code-review` に委ねる。決定と理由は [ADR 0014](../../adr/0014-advisory-findings-go-to-the-fixer.md)、現行のループは [deliver ワークフロー設計](2026-09-25-deliver-workflow-design.md) の「フロー」3。

## 目的と成功条件

- 修正する価値のある参考指摘が、報告に並ぶだけで残らない。
- 修正必須の契約(検証者付きの見送り、収束条件、上限での Unresolved)は変えない。
- 参考指摘を直したコミットも、必ず checks と再レビューを通ってからループを抜ける。

適用範囲は `mode: "deliver"` と `mode: "review-verify"` の両方(判定を mode で分けない。ADR 0010)。

## 用語

`CONTEXT.md` の「Autonomous delivery」節に次の2語を足し、Review Finding の定義(「修正されるか Deferred Finding になるかのどちらかで閉じる」)を、参考指摘の閉じ方も含むよう改める。

- **Advisory Finding**: 修正必須の重大度を含まない Review Finding。修正エージェントに渡すが、収束条件には数えない。
- **Declined Advisory Finding**: 修正エージェントが直さないと判断した Advisory Finding。検証者を通さずに閉じ、理由付きで最終報告に載る。

## 判定(コードで行う)

- 修正必須かどうかの表(`REVIEWERS[].blocking`)は変えない。ecc の `note`(機械的な Code Quality 指摘を MEDIUM 以下で報告させる指示)も残す。役割は「修正必須にしない」ことに変わり、修正に回すかどうかとは無関係になる。機械的な指摘も Advisory Finding として修正に回す(ユーザーの判断)。
- 修正エージェントの出力スキーマ `FIX_SCHEMA` は変えない(`action: "fixed" | "propose-defer"`)。結果の振り分けは、その key を修正必須として渡したか Advisory として渡したかでコードが決める。
  - 修正必須 key の `propose-defer` → 現行どおり検証者へ。
  - Advisory key の `propose-defer` → 検証者を通さず Declined Advisory Finding として閉じる。
  - Advisory key の `fixed` → 「修正した参考指摘」に記録し、閉じる。
  - Advisory key で結果が返らなかった → 閉じずに残す(次の修正ラウンドで再送してよい)。
- 回答済み(`fixed` / `propose-defer`)の Advisory key は閉じた集合に入れ、以後のラウンドで同じ key が出ても修正に回さない。再出現した nit がラウンドを消費し続けるのを防ぐため。閉じた Advisory key に統合された指摘が修正必須の重大度を含む場合は、Advisory 扱いを引き継がず、通常の修正必須として判定する(直したはずの箇所に重大な問題が出たことを意味するため)。

## ループ

各ラウンドの判定後、次のように進む(`reviewRounds`)。

1. `requirementsBreaking` があれば現行どおり停止する。
2. 修正必須が0件で、未回答の Advisory も0件ならループを終える。
3. 修正ラウンドの上限 `maxReviewRounds` に達していれば、修正必須を Unresolved にしてループを終える。**未回答の Advisory は Unresolved にせず、参考指摘として報告に残す。**
4. それ以外は、修正必須と未回答の Advisory をまとめて1回の修正に回す(修正必須が0件なら Advisory だけ)。修正の後は必ず次のラウンド(checks → レビュー)に進む。

Advisory だけの修正ラウンドも `maxReviewRounds` を1つ消費する。上限の意味(修正のたびに再レビューするので、レビューは最大で上限+1回)は変わらない。

再レビューの前に止まった場合(checks 失敗、レビュアー全滅、予算、例外)、修正に回した修正必須指摘は現行どおり Unresolved にする。Advisory は Unresolved にせず、「修正に回した後、再レビューされていない参考指摘」として報告に出す(修正のコミットは残っているため、人間が見る必要がある)。

## 修正エージェントの prompt

`fixPrompt` に次を足す。

- 指摘を、修正必須(`blocking`)と参考(`advisory`)の2つのリストで渡す。
- Skill ツールで `superpowers:receiving-code-review` を読み込み、その手順で各指摘を評価してから対応する。
- この実行は非対話で、人間に質問できない。skill が「人間に聞く」「止まって相談する」とする場面(指摘が不明確、人間の過去の判断や要件文書と衝突する、アーキテクチャに関わる)では、`propose-defer` とし、その旨を理由に書く。
- 参考指摘は、技術的に正しく、要件文書と衝突しないなら直す側に倒す。直さないのは、偽陽性・この差分の範囲外・要件文書との衝突・上記の非対話の読み替えに当たる場合で、理由を具体的に書く。
- 修正必須の指摘についての現行の指示(直すのが大変という理由で見送らない、等)は変えない。

実装前に、Workflow のエージェントから Skill ツールで `superpowers:receiving-code-review` の本文を読み込めることを1エージェントで実測する(fork 型の skill は読み込めない。ADR 0007)。frontmatter に `context: fork` は無い。2026-10-03 に実測し、Workflow のエージェントから本文を読み込めた。

## 報告と ledger

- Advisory の修正による変更も `fixChanges` に入れる。review-verify の手順8と deliver の入口 skill が jq で突き合わせる配列(`checksChanges` / `fixChanges` / `verifyFixChanges`)は変えない。
- 報告の節を次のように改める(現行の 6〜7 の位置)。
  - 「参考指摘(修正必須ではない)」→ 未回答のまま残った Advisory と、`fixed` と回答した後に再レビューで再指摘された Advisory(その旨を注記する)。同じラウンドで修正必須にもなった key は含めない。
  - 「見送った参考指摘」を新設し、理由を付ける。
  - 「修正した指摘」に Advisory の `fixed` も含め、修正必須か参考かを区別できる形で出す。再レビューで再指摘された Advisory は、直ったと確かめていないので含めない(修正必須で直したと申告した key が再出現したときと同じ扱い)。
  - 「修正に回した後、再レビューされていない参考指摘」(ある場合だけ)。
- 統計のラウンドごとの行に、Advisory の件数(修正必須と重なった key を除く)、そのうち修正に回した件数、修正件数・見送り件数を出す。
- ledger にも上記の新しい配列を保存する。

## テスト(`just test-deliver`)

既存のテストの形に合わせ、次を足す。

1. 修正必須0件・Advisory あり → Advisory だけの修正ラウンドが回り、その後に checks とレビューがもう1回走る。
2. 上限到達時に Advisory だけが残る → Unresolved にならず、参考指摘として報告される。
3. 一度 `propose-defer` / `fixed` を返した Advisory key が次のラウンドで再出現 → 修正に回らない。
4. Advisory の修正後のラウンドで、新しい修正必須指摘が出る → 通常どおり修正に回る。
5. Advisory key の `propose-defer` → 検証者が起動されず、「見送った参考指摘」に理由付きで載る。
6. Advisory を修正に回した後、checks 失敗で止まる → Unresolved にならず、「再レビューされていない参考指摘」に載る。

## 変更するファイル

- `dot_claude/workflows/deliver.js`(判定・ループ・prompt・報告)
- `test/` の deliver のテスト
- `CONTEXT.md`(用語)
- `docs/adr/0014-advisory-findings-go-to-the-fixer.md`
- `dot_claude/skills/deliver/SKILL.md` / `dot_claude/skills/review-verify/SKILL.md`(報告の節の説明に触れている箇所があれば)
