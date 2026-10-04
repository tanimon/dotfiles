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

- 入力は plan と spec のどちらも受け付けるため、`plan` を前提にした語と識別子を Requirements Document / Requirements Concern(`CONTEXT.md`)に改名した(タスク分解を持つ plan を前提にする Deliver 専用の `planPrompt` や停止理由 `plan-unreadable` は plan のままにする)。旧名の別名は残さない(`planPath` を呼ぶのは入口 skill だけで、ledger からの再開は未実装のため読み手がいない)。
- `mode` は必須で既定値を置かない。既定を `deliver` にすると、入口が `mode` を渡し忘れた Review-Verify が黙って Deliver として走り、人間のブランチの上で実装・push・draft PR の作成まで進む。両方の入口 skill が `mode` を明示的に渡すので、必須にしても呼び出し側の負担は増えない。
- Review-Verify は push も PR の作成もしない。修正のコミットはローカルに残り、報告(`report.md` / `ledger.json`)は Deliver の結果を上書きしないよう別のディレクトリに書き出す。Deliver も [ADR 0015](0015-deliver-does-not-publish.md) で公開しなくなり、両者の違いは実装から始めるかどうかだけになった。
- テスト/lint が最初から落ちているブランチも、Deliver と同じ扱いにする。各レビューラウンドの最初で checks エージェントが落ちたテスト/lint を直してコミットし、直らなければ `checks-failing` で止まる。この修正の上限(3回)はプロンプトで指示しているだけでコードでは強制していない。これは Deliver にも既にある残存リスクで、Review-Verify のために新しく作る経路ではない。人間が書いたブランチでは、このエージェントがレビューより先にコードを変えうる。
- spec はふつうブランチの範囲より広いので、そのままでは未着手の要件が「要件文書とのずれ」として修正必須になり、修正エージェントや動作確認の修正エージェントがそれを実装してしまう。未着手の項目を検査するテストがブランチに先に入っていれば、レビューより前に走る checks エージェントも、落ちたテストを直すつもりでそれを実装してしまう。`implement()` を mode で塞いでも、これらの経路は残る。Review-Verify の mode のときだけ、テスト/lint(checks)・レビュー・修正・見送りの検証・動作確認・動作確認の修正のプロンプトに「ブランチがまだ着手していない項目は範囲外」を足して塞ぐ。これはプロンプトでの指示でありコードでは強制できないので、残存リスクとして残る。spec を受け付けない案(入口で plan に限る)は、「spec を渡してループだけ回す」使い方を失うため採らなかった。
- 逆向きのリスクもある。この制約を口実に、エージェントがブランチ自身の変更の不具合を「未着手の項目」と呼べば、レビュアーは observations に回し、修正エージェントは見送りを提案できる。見送りは Deferred Finding として閉じた扱いになり、Unresolved Finding には載らない。プロンプトに「ブランチが追加・変更したコードの不具合は範囲外にしない」という歯止めを添え、見送りの検証者には、その項目が差分で本当に未着手かを自分で確かめさせる。これもプロンプトでの指示にとどまり、残存リスクとして残る。
