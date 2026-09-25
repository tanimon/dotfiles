---
status: accepted
date: 2026-09-25
---

# 自律実装フロー `deliver` は Claude Code Workflows を骨格にし、レビューループの判定をコードで強制する

plan を受け取り、実装、レビュー修正ループ、動作確認を経て draft PR と人間への報告までを自律で行うフロー `deliver` を作る。レビューループの上限・終了条件・収束判定・Deferred Finding の承認は、LLM へのプロンプトではなく Claude Code Workflows のスクリプト(`dot_claude/workflows/deliver.js`)のコードで判定する。プロンプトで守らせる方式では、agent が自分で「もう十分」と判断してループを早く抜けたり、直しにくい指摘を見送ったりする経路が残るためである。Workflows は実行中に人間へ質問できないので、入口に skill(`dot_claude/skills/deliver/`)を置き、動作確認 skill などの不足している引数はその skill が起動前に `AskUserQuestion` で集めてから Workflow を起動する。

## Considered Options

- **superpowers の `subagent-driven-development` を拡張する** — 却下。修正ラウンドの上限(5回)と、中断後に再開するための ledger が既製である点は魅力だが、上限も収束もプロンプトで守らせるので保証されない。上流の skill を改造することにもなる。
- **compound-engineering の `lfg` を使う** — 却下。レビューが1回だけでループしない。compound-engineering plugin は廃止予定でもある。
- **orca orchestration** — 却下。Orca アプリが起動していることが前提で、ループと上限は coordinator の LLM が回すため、判定をコードで強制できない。
- **google/ax** — 却下。Kubernetes 上で agent タスクを大規模に実行するための基盤(experimental)で、ローカルの開発ループには過剰。
- **ralph-loop(Stop hook による反復)** — 却下。反復回数の上限は付けられるが、レビュー・統合・検証者を分ける構造を持たない。

## Consequences

- **別セッションからは再開できない。** Workflows の resume は同じセッション内か `claude --resume` したセッションに限られる。これを補うため、状態を `$(git rev-parse --git-dir)/deliver/ledger.json` に書き出す(workflow エージェントがここに書き込めることは 2026-09-25 に実測済み)。ledger から途中を再開する引数は試作の範囲外で、後から足す。
- **Workflow のエージェントから Skill を呼べる。ただし fork 型の skill は使えない**(2026-09-25 実測)。`ecc-code-review` と `superpowers:requesting-code-review` は本文を読み込めたが、built-in の `code-review` は別エージェントとして起動するだけで、結果は親セッションに届いた。このため built-in はレビュアーから外し、2本構成にした。fork 型の skill を足すときは、先に同じ実測をすること。
- **レビュアーごとに重大度の尺度が異なる**(ecc は CRITICAL/HIGH/MEDIUM/LOW、requesting は Critical/Important/Minor)。尺度は変換せずに、そのまま受け取る。修正必須かどうかはレビュアーごとの表でコードが判定する(ecc の CRITICAL/HIGH、requesting の Critical/Important)。ただし ecc の「Code Quality (HIGH)」は関数やファイルの行数・console.log・TODO/FIXME・JSDoc の欠落といった機械的な基準を含み、そのまま受け取るとこれらが修正必須になって指示の無いリファクタリングを招く。そこで、不具合に繋がる場合を除いてこれらを MEDIUM 以下で報告するよう、レビューの prompt で指示する(尺度の変換ではなく、どの尺度に当てはめるかの指示)。
- **agent 数が多い**(1ラウンドでレビュー2本、統合1本、修正、検証者 N 本)。`budget` の既定値は試作の実行で計測してから決める。
