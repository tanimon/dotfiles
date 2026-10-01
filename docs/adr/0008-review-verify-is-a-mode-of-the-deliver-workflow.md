---
status: accepted
date: 2026-10-01
---

# Review-Verify は別の Workflow にせず、`deliver.js` の mode として実装する

既存のブランチにレビュー修正ループと動作確認だけをかける Review-Verify を、Deliver の Workflow(`dot_claude/workflows/deliver.js`)に引数 `mode: "deliver" | "review-verify"` を足して実装する。入口だけは別の skill(`/review-verify`)にする。Workflow のスクリプトは自己完結で他のファイルを import できないため、別の Workflow にするとレビューループの判定(上限・収束・Deferred Finding の承認)と報告の組み立てを2本に複製することになり、[ADR 0007](0007-deliver-workflow-enforces-review-loop-in-code.md) が「判定をコードで強制する」と決めたその判定を2箇所で守り続けなければならなくなるためである。

## Considered Options

- **別の Workflow(`review-verify.js`)にする** — 却下。上記のとおり判定と報告の組み立てが複製され、テストも2系統になる。
- **実装の有無と PR 作成の有無を独立したフラグにする** — 却下。「spec から実装する」(実装にはタスク分解を持つ plan が要る)と「Review-Verify で PR を作る」はどちらも求められていない組み合わせで、2値の mode なら呼び出し側が覚える値が2つで済む。
- **`/deliver` に引数を足して入口を共有する** — 却下。起動前の確認(plan のタスク分解を検査するか、spec を受け付けるか、PR を作るか)が違い、1つの skill に分岐を持たせるより入口を分けたほうが各 skill が単純になる。

## Consequences

- 入力は plan と spec のどちらも受け付けるため、`plan` を前提にした語と識別子を Requirements Document / Requirements Concern(`CONTEXT.md`)に改名した。旧名の別名は残さない(`planPath` を呼ぶのは入口 skill だけで、ledger からの再開は未実装のため読み手がいない)。
- Review-Verify は push も PR の作成もしない。修正のコミットはローカルに残り、報告(`report.md` / `ledger.json`)は Deliver の結果を上書きしないよう別のディレクトリに書き出す。
- テスト/lint が最初から落ちているブランチは、Deliver と同じく修正ループに入れずに止める。落ちたテスト/lint を指摘として修正に回すと、レビューより前に上限・収束の判定を持たない修正経路ができるためである。入口 skill が起動前に1回走らせて止める。
