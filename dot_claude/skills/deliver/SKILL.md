---
name: deliver
description: 実装計画(plan)を受け取り、実装 → レビュー修正ループ(上限付き)→ 動作確認 → draft PR と人間への報告までを自律実行する。「この plan を実装して PR まで」「plan を渡すので自律で仕上げて」「/deliver」など、分解済みの plan を人手を挟まずに PR まで持っていきたいときに使う。spec や PRD しか無い(タスク分解の無い)入力、main などの保護ブランチ上での作業、一歩ずつ人間がレビューしたい作業には使わない。
---

# deliver

`~/.claude/workflows/deliver.js` を起動する前に、Workflow の中ではできない確認と質問をすべて済ませる。Workflow は実行中に質問できないので、ここで欠けた引数は後から補えない。設計は chezmoi リポジトリの `docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`。

## 手順

1. **ブランチを検査する。** `git rev-parse --abbrev-ref HEAD` が `main` / `master` / `development` / `HEAD`(detached)であれば、理由を伝えて**中止する**。worktree やブランチは作らない。`git status --porcelain` が空でなければ、未コミットの変更があることを伝えて中止する(実装エージェントのコミットに混ざるため)。
2. **plan を確認する。** 引数の plan パスを絶対パスにし、ファイルが存在してタスク分解(見出しやチェックボックスで区切られたタスク)を含むことを確認する。spec や PRD しか無い場合は中止し、先に plan を作るよう伝える(`superpowers:writing-plans` など)。
3. **差分の基点を決める。** 引数 `base=` があればそれを使う。無ければ `origin/HEAD` が指すブランチ(`git symbolic-ref --short refs/remotes/origin/HEAD`。`origin/main` の形で出る)を使う。プロジェクトの規約で別のブランチと比較するもの(例: hotfix 以外は `development` と比較する)があれば、その規約に従う。
4. **テスト/lint のコマンドを決める。** プロジェクトの CLAUDE.md が示す検証コマンド(例: `just lint`、`bash scripts/lint/git-diff-lint.sh`、`npm test`)を列挙する。特定できない、または候補が複数あって選べない場合は、`AskUserQuestion` で選んでもらう。1件以上が必要。
5. **動作確認 skill を決める。** 引数 `verify=` があればそれを使う。無ければ `AskUserQuestion` で聞く。選択肢は、そのリポジトリ専用の検証 skill(あれば先頭に置く)、`web-verify`、`run`、`none`(テスト/lint のみ)とする。
6. **上限回数を決める。** 引数 `rounds=` があれば `maxReviewRounds` に使い、無ければ省略する(既定は 3)。
7. **起動する。** Workflow ツールを次の形で呼ぶ。`args` は JSON の値として渡し、文字列化しない。

   ```
   Workflow({
     scriptPath: "<ホームディレクトリの絶対パス>/.claude/workflows/deliver.js",
     args: {
       planPath: "<絶対パス>",
       baseRef: "<手順3>",
       checkCommands: ["<手順4>", ...],
       verifySkill: "<手順5>",
       maxReviewRounds: <手順6。指定があるときだけ>
     }
   })
   ```

8. **結果を伝える。** Workflow の返り値の `report` を、そのままユーザーに示す。`prUrl` があれば添え、`published` が false であれば公開に失敗したことを、`publishError` の理由とともに先頭に書き、返り値の `report` と `ledger` をそれぞれ `$(git rev-parse --absolute-git-dir)/deliver/pr-body.md` / `ledger.json` に Write ツールでそのまま書き出す(Workflow 内の書き出しが予算の上限などで失敗していても残すため。PR は作らない)。`stopReason` があれば、何が原因で止まったかを1文で添える。報告の中身を要約して丸めない(Unresolved Finding と Plan Concern は人間の判断材料なので、省略しない)。
