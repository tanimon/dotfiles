---
status: accepted
date: 2026-10-17
---

# Deliver を廃止し、自律 Workflow を Review-Verify だけにする

plan から実装まで行う Deliver を廃止し、Workflow を、既存のブランチにレビュー修正ループと動作確認だけをかける Review-Verify の1通りにする。実装は Workflow の外(人間、または `superpowers:subagent-driven-development` などの実装 skill)で行い、`/deliver` は使われていなかった。実装の経路を持ち続けると、`mode` による分岐・実装エージェントのプロンプト・そのテストを、使われないまま保守することになる。Workflow は `dot_claude/workflows/review-verify.js`(`meta.name: "review-verify"`)に改名し、入口は `/review-verify` だけにする。

[ADR 0010](0010-review-verify-is-a-mode-of-the-deliver-workflow.md) が Review-Verify を `deliver.js` の mode にしたのは、レビューループの判定を2本の Workflow に複製しないためだった。Workflow が1本になったので、mode にしておく理由は無くなる。[ADR 0015](0015-deliver-does-not-publish.md) の「公開しない」は Review-Verify では最初から成り立っており、ここに引き継ぐ。[ADR 0007](0007-deliver-workflow-enforces-review-loop-in-code.md)(判定はコードで強制する)は、そのまま Review-Verify に当てはまる。

## Considered Options

- **`/deliver` を、案内だけの入口(「実装を済ませてから `/review-verify`」)として残す** — 却下。誰も起動しない skill が、description 分のコンテキストを常に使い続ける。
- **`mode` 引数を `"review-verify"` の1値だけ受け付ける形で残す** — 却下。将来 mode を足す余地のために、使わない抽象を保守し続けることになる。必要になれば git の履歴から戻せる。
- **Workflow の名前を `deliver` のまま残す** — 却下。変更は少なくて済むが、存在しないプロセスの名前で Workflow を呼び続けることになる。

## Consequences

- 引数 `mode` は受け付けない。渡されたら、未知の引数として `validateArgs` で弾く。古い入口が黙って違う挙動で走らないようにするため。
- 報告の書き出し先を `$(git rev-parse --absolute-git-dir)/review-verify/` にする。`deliver/` の下に分けていた理由(Deliver の報告を上書きしない)が無くなったため。統計の `mode` 行は、常に同じ値になるので `上限` 行(`maxReviewRounds` / `maxVerifyRetries`)に置き換える。過去に Issue に投稿した統計とは行の形が変わる。
- デプロイ済みの `~/.claude/workflows/deliver.js` と `~/.claude/skills/deliver/` は `.chezmoiremove` で消す。chezmoi は source から消したファイルをデプロイ先から消さないので、残すと `/deliver` が起動できたまま古い Workflow を呼び続ける。
- テスト/lint が最初から落ちているブランチでは、各レビューラウンドの最初で checks エージェントが落ちたテスト/lint を直してコミットし、直らなければ `checks-failing` で止まる。この修正の上限(3回)はプロンプトで指示しているだけで、コードでは強制していない。人間が書いたブランチでは、このエージェントがレビューより先にコードを変えうる。
- 「要件文書のうち、ブランチがまだ着手していない項目は範囲外」という制約(ADR 0010 の branchScope)は、常に付ける。spec はふつうブランチの範囲より広いので、この制約が無いと、checks・修正・動作確認の修正のエージェントが未着手の要件を実装してしまう。これはプロンプトでの指示でありコードでは強制できないので、残存リスクとして残る。逆向きのリスクもある。エージェントが、ブランチ自身の変更の不具合を「未着手の項目」と呼んで範囲外にしうる。これは、「ブランチが追加・変更したコードの不具合は範囲外にしない」という歯止めと、見送りの検証者が差分で本当に未着手かを確かめることで抑える。これもプロンプトでの指示にとどまる。
