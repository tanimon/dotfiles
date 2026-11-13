---
name: review-verify
description: 既にコミットされたブランチに、要件文書(plan または spec)を基準にしたレビュー修正ループ(上限付き)と動作確認だけをかけ、PR は作らずに人間へ報告する。「このブランチをレビューして直して動作確認まで」「spec を渡すのでレビューループだけ回して」「/review-verify」など、実装は済んでいて仕上げだけを自律で回したいときに使う。実装そのものはしない。要件文書が無いブランチ、main などの保護ブランチ上での作業には使わない。
argument-hint: "<要件文書のパス> [base=] [verify=] [rounds=] [stats-issue=<Issue の URL>] [pr=<PR の URL>]"
---

# review-verify

`~/.claude/workflows/review-verify.js` を起動する前に、Workflow の中ではできない確認と質問をすべて済ませる。Workflow は実行中に質問できないので、ここで欠けた引数は後から補えない。レビューループの設計は chezmoi リポジトリの `docs/superpowers/specs/2026-09-25-deliver-workflow-design.md`、実装をしない理由は同じく `docs/adr/0022-retire-deliver-keep-only-review-verify.md`。

Workflow は実装も push も PR の作成もしない。修正エージェントのコミットはローカルのブランチに残る。

## 手順

1. **書き出し先を決め、起動前の確認をする。** 書き出し先 `<dir>` は、`git rev-parse --absolute-git-dir` を単独で実行した出力に `/review-verify` を足したディレクトリにする。`git rev-parse` が失敗したとき、または sandbox が `.git` の下への書き込みを拒んで `mkdir -p <dir>` が失敗したときは、セッションの scratchpad ディレクトリの下に `review-verify` を作って `<dir>` にする。要件文書(plan でも spec でもよく、タスク分解は要らない)が引数に無ければ中止し、意図を書いた文書を渡すよう伝える(レビュー・修正の見送り・動作確認は、すべてこの文書を意図の正本として判断する)。そのうえで次を実行する。`--pr` / `--stats-issue` は引数 `pr=` / `stats-issue=` があるときだけ付ける。

   ```
   bash ~/.claude/skills/review-verify/scripts/precheck.sh --dir <dir> --requirements <要件文書のパス> [--pr <pr= の URL>] [--stats-issue <stats-issue= の URL>]
   ```

   終了コード 2 なら標準エラー出力の理由を伝えて**中止する**(worktree やブランチは作らず、ブランチの切り替えや変更の退避もしない)。終了コード 0 なら、標準出力の JSON の `requirementsPath` を `<Workflow に渡す要件文書>`、`preSha` を起動前の SHA として控える。
2. **差分の基点を決める。** 引数 `base=` があればそれを使う。無ければ `origin/HEAD` が指すブランチ(`git symbolic-ref --short refs/remotes/origin/HEAD`。`origin/main` の形で出る)を使う。`refs/remotes/origin/HEAD` は clone の仕方によってはローカルに無く、このコマンドが失敗する。その場合は推測せず `AskUserQuestion` で基点を聞く。プロジェクトの規約で別のブランチと比較するもの(例: hotfix 以外は `development` と比較する)があれば、その規約に従う。`git rev-list --count <基点>..HEAD` が 0 なら、レビューする差分が無いことを伝えて中止する。
3. **テスト/lint のコマンドを決める。** プロジェクトの CLAUDE.md が示す検証コマンド(例: `just lint`、`bash scripts/lint/git-diff-lint.sh`、`npm test`)を列挙する。特定できない、または候補が複数あって選べない場合は、`AskUserQuestion` で選んでもらう。1件以上が必要。落ちているコマンドがあっても、Workflow がレビューの前に直そうとする(直らなければ止まる。要件文書のうちブランチが未着手の項目を検査するテストは、実装せずに止まる)ので、起動前に走らせて止める必要はない。
4. **動作確認 skill を決める。** 引数 `verify=` があればそれを使う。無ければ `AskUserQuestion` で聞く。選択肢は、そのリポジトリ専用の検証 skill(あれば先頭に置く)、`web-verify`、`run`、`none`(テスト/lint のみ)とする。`verify=` で渡された場合も含め、動作確認 skill が起動時に人間に確かめる事項があれば、ここで確かめて `verifyArgs` に1つの文字列で入れる(Workflow の動作確認エージェントは質問できない)。`web-verify` なら、確かめる事項・順序・`verifyArgs` の形は web-verify の SKILL.md の「起動前に人間が確かめる事項」に従う。その SKILL.md は Skill ツールで起動せずファイルとして読む(起動すると、ここで動作確認そのものが始まる)。場所はまずこの skill と同じ skills ディレクトリの `web-verify/SKILL.md` を見て、無ければ `~/.claude/skills`・プロジェクトの `.claude/skills`・`~/.claude/plugins` の配下から `web-verify/SKILL.md` を探す。見つからなければ保存場所だけを聞き、`検証資産の保存場所: <絶対パス>(質問)` の形で渡す。確かめる事項が無ければ省略する。
5. **上限回数を決める。** 引数 `rounds=` があれば `maxReviewRounds` に使い、無ければ省略する(既定は 3)。
6. **起動する。** Workflow ツールを次の形で呼ぶ。`args` は JSON の値として渡し、文字列化しない。`~/.claude/workflows/review-verify.js` は名前付きワークフローとして `name` で起動する。`scriptPath` で渡すと、作業ディレクトリの外のファイルとして拒否される。

   ```
   Workflow({
     name: "review-verify",
     args: {
       requirementsPath: "<Workflow に渡す要件文書>",
       baseRef: "<差分の基点>",
       checkCommands: ["<テスト/lint のコマンド>", ...],
       verifySkill: "<動作確認 skill>",
       verifyArgs: "<動作確認 skill について確かめた事項。あるときだけ>",
       maxReviewRounds: <上限回数。指定があるときだけ>
     }
   })
   ```

7. **結果を書き出して伝える。** Workflow が返ったら、値を返さずに終わった場合(Workflow ツールがエラーを返した場合)も含めて、次を実行する。`<output-file>` は完了通知の `<output-file>` で、Workflow ツールがエラーを返したときは `--output-file` ごと省く。

   ```
   bash ~/.claude/skills/review-verify/scripts/postcheck.sh --dir <dir> --output-file <output-file>
   ```

   完了通知の `<result>` から Write ツールで書き出さない(返り値はスクリプトが出力ファイルから `<dir>` に書き出す)。終了コードにかかわらず、標準出力を出力の先頭にそのまま置く(Workflow ツールがエラーを返したときは、そのエラーをさらに上に書く)。終了コード 2 のときは、確認を最後まで実行できなかったことと標準エラー出力も先頭に書く。続けて `<dir>/report.md` があればその中身をそのまま示し、`report.md` と `ledger.json` の path を添える。`report.md` が無く出力ファイルがあるときは、出力ファイルの path を添える。報告に停止の理由(`stopReason`)があれば、何が原因で止まったかを 1 文で添える。どの場合も、報告の中身を要約して丸めない(Unresolved Finding と Requirements Concern は人間の判断材料なので、省略しない)。未コミットの変更を消したりコミットしたりせず、扱いはユーザーに委ねる。push と PR の作成もユーザーに委ねる。
8. **統計を投稿する。** 引数 `stats-issue=` があるときだけ行う。`<dir>/stats.md` があれば `gh issue comment <URL> --body-file <dir>/stats.md` で投稿する。`stats.md` に何も足さない(リポジトリ名・ブランチ名・SHA・報告の他の節)。仕事のリポジトリでの実行を public な Issue に投稿しうるためで、`stats` はそれらを含まないよう Workflow が組み立てている。`stats.md` が無い場合(Workflow が値を返さずに終わった場合など)と、投稿に失敗した場合は、実行の失敗にはせず、投稿できなかったことと理由をユーザーに伝える(伝えないと、集めている統計の件数が黙って欠ける)。
