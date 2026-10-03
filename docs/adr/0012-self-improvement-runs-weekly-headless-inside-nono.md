---
status: accepted
date: 2026-10-02
---

# 自己改善ループを、ローカルの launchd から週 1 回、nono の内側で headless 実行する

自己改善ループの全工程(失敗の検出 → Failure Pattern への分類 → 学びの抽出 → Eval Case の作成と 2 アーム評価 → draft PR 1 本)を、ローカルの launchd から週 1 回、`claude -p` で実行する。起動は launchd の plist が `nono run --profile claude-seal -- /bin/bash <入口スクリプト>` と明示し、入口スクリプトごと nono の内側に置く。入口スクリプトは `~/.claude` 配下にあり nono の内側から書き換えられるので、境界の外で実行しない(境界の外で動くのは、内側から書けない nono の実体と plist だけ)。macOS ではサンドボックスを入れ子にできない(`dot_config/nono/CLAUDE.md`)ため、Bash を許可した Eval Case の実行のように子プロセスが Claude Code 自身のサンドボックスを必要とする部分だけは、nono の外でネイティブの sandbox と `--allowedTools` で絞って動かす。1 回の実行で扱う Eval Case は最大 20 件とし、`--max-budget-usd` で 1 回ごとの上限もかける。人間は週 1 本の draft PR をまとめて承認する。

人の起動に頼る設計は実績で破綻した。2026-07-06 に作り直したループは、最初の `/harness-review` が実行される 2026-09-28 まで約 12 週間止まり、その間に未処理のセッションが 426 件溜まった。そのうち 39 件は transcript もダイジェストも残っていなかった。transcript は既定で 30 日(`cleanupPeriodDays`)で消えるので、起動が遅れるほど証拠そのものが失われる。

## Considered Options

- **人の手動起動を続ける(rebuild spec の Decision 5 の延長)** — 却下。上の 12 週間の停止がその結果である。
- **GitHub Actions で実行する** — 却下。transcript はローカルの `~/.claude/projects/` にしかなく、Actions からは読めない。OAuth の token 失効による 401 で、旧システムが 1 か月気づかれずに止まっていた前例もある(rebuild spec の Decision 6 が、定期の健康診断を CI ではなくローカルに置いた理由と同じ)。
- **launchd から nono を通さずに実行する** — 却下。launchd から起動すると zsh の wrapper(`dot_config/zsh/sandbox.zsh`)を通らないため、明示しない限り nono が適用されない。人がいない実行こそ、境界を外す理由がない。

## Consequences

- rebuild spec の Decision 5(hook から headless の `claude -p` を起動しない)は、hook 起点の実行についての決定として残る。この ADR が追加するのは launchd 起点の実行で、hook からは起動しない。
- 入れ子のサンドボックスで Bash が失敗するかは未確認なので、実装の最初に Contrast Pair で確かめる。
- 停止の検知は、briefing の表示だけに頼らない。ジョブは最後に成功した時刻(heartbeat)をファイルに残し、briefing がその古さを表示する。加えて、ジョブの失敗時と、draft PR が 2 週以上放置されたときは、既存の `harness-issue-alert` と同じくタイトルで重複を避けて GitHub Issue を作る。
- `--max-budget-usd` は 1 回の実行にしか効かず、複数回や月単位の上限は無い。週ごとの上限は、launchd の実行間隔と 1 回あたりの Eval Case の件数で間接的にかける。
- `--bare` を付けない headless 実行は、SessionEnd hook が自分自身のセッションを `pending.jsonl` に積む。ジョブは自分のセッションを処理の対象から除外する必要がある。
