---
name: review-verify
description: 既にコミットされたブランチに、要件文書(plan または spec)を基準にしたレビュー修正ループ(上限付き)と動作確認だけをかけ、PR は作らずに人間へ報告する。「このブランチをレビューして直して動作確認まで」「spec を渡すのでレビューループだけ回して」「/review-verify」など、実装は済んでいて仕上げだけを自律で回したいときに使う。実装から始めたい(plan を渡して実装から任せたい)なら /deliver を使う。要件文書が無いブランチ、main などの保護ブランチ上での作業には使わない。
argument-hint: "<要件文書のパス> [base=] [verify=] [rounds=] [stats-issue=https://github.com/tanimon/dotfiles/issues/426]"
---

# review-verify

`~/.claude/workflows/deliver.js` を `mode: "review-verify"` で起動する前に、Workflow の中ではできない確認と質問をすべて済ませる。Workflow は実行中に質問できないので、ここで欠けた引数は後から補えない。Deliver と同じ Workflow を使う理由は chezmoi リポジトリの `docs/adr/0010-review-verify-is-a-mode-of-the-deliver-workflow.md`。

Workflow は実装も push も PR の作成もしない。修正エージェントのコミットはローカルのブランチに残る。

## 手順

1. **ブランチを検査する。** `git rev-parse --abbrev-ref HEAD` が `main` / `master` / `development` / `HEAD`(detached)であれば、理由を伝えて**中止する**。worktree やブランチは作らない。`git status --porcelain` が空でなければ、未コミットの変更があることを伝えて中止する(修正エージェントのコミットに混ざるため)。検査を通ったら `git rev-parse HEAD` を起動前の SHA として控える(手順8で使う)。
2. **要件文書を確認する。** 引数の文書パスを絶対パスにし、ファイルが存在することを確認する。plan でも spec でもよく、タスク分解は要らない。文書が渡されていなければ中止し、意図を書いた文書を渡すよう伝える(レビュー・修正の見送り・動作確認は、すべてこの文書を意図の正本として判断する)。
3. **差分の基点を決める。** 引数 `base=` があればそれを使う。無ければ `origin/HEAD` が指すブランチ(`git symbolic-ref --short refs/remotes/origin/HEAD`。`origin/main` の形で出る)を使う。`refs/remotes/origin/HEAD` は clone の仕方によってはローカルに無く、このコマンドが失敗する。その場合は推測せず `AskUserQuestion` で基点を聞く。プロジェクトの規約で別のブランチと比較するもの(例: hotfix 以外は `development` と比較する)があれば、その規約に従う。`git rev-list --count <基点>..HEAD` が 0 なら、レビューする差分が無いことを伝えて中止する。
4. **テスト/lint のコマンドを決める。** プロジェクトの CLAUDE.md が示す検証コマンド(例: `just lint`、`bash scripts/lint/git-diff-lint.sh`、`npm test`)を列挙する。特定できない、または候補が複数あって選べない場合は、`AskUserQuestion` で選んでもらう。1件以上が必要。落ちているコマンドがあっても、Workflow がレビューの前に直そうとする(直らなければ止まる。要件文書のうちブランチが未着手の項目を検査するテストは、実装せずに止まる)ので、起動前に走らせて止める必要はない。
5. **動作確認 skill を決める。** 引数 `verify=` があればそれを使う。無ければ `AskUserQuestion` で聞く。選択肢は、そのリポジトリ専用の検証 skill(あれば先頭に置く)、`web-verify`、`run`、`none`(テスト/lint のみ)とする。
6. **上限回数を決める。** 引数 `rounds=` があれば `maxReviewRounds` に使い、無ければ省略する(既定は 3)。引数 `stats-issue=` があれば、`https://github.com/<owner>/<repo>/issues/<番号>` の形の URL であることを確かめて控える(手順9で使う)。番号だけ(`426` や `#426`)なら中止し、URL で渡し直すよう伝える。番号だけでは、`gh` がカレントのリポジトリの同じ番号の Issue に投稿する。
7. **起動する。** Workflow ツールを次の形で呼ぶ。`args` は JSON の値として渡し、文字列化しない。

   ```
   Workflow({
     scriptPath: "<ホームディレクトリの絶対パス>/.claude/workflows/deliver.js",
     args: {
       mode: "review-verify",
       requirementsPath: "<手順2の絶対パス>",
       baseRef: "<手順3>",
       checkCommands: ["<手順4>", ...],
       verifySkill: "<手順5>",
       maxReviewRounds: <手順6。指定があるときだけ>
     }
   })
   ```

8. **結果を書き出して伝える。** Workflow の返り値の `report` と `ledger` を、それぞれ `$(git rev-parse --absolute-git-dir)/deliver/review-verify/report.md` / `ledger.json` に Write ツールでそのまま書き出す(Deliver の `report.md` を上書きしないよう、ディレクトリを分ける)。そのうえで `report` をそのままユーザーに示し、書き出した2つの path を添える。`stopReason` があれば、何が原因で止まったかを1文で添える。Workflow が足したコミットは `<起動前の SHA>..HEAD` であることも、SHA を書いて添える(レビューや巻き戻しの範囲を人間が辿れるように)。ただし先に `git merge-base --is-ancestor <起動前の SHA> HEAD` で、起動前の SHA が今も HEAD の祖先であることを確かめる。祖先でなければ、エージェントが amend / rebase / reset で人間のコミットを書き換えたので、この範囲を Workflow が足したコミットとして示さず、履歴が書き換わったことを起動前の SHA とともに出力の先頭に書く(push 済みのブランチなら戻すのに force push が要る)。祖先であれば、まず `git diff --name-only <起動前の SHA>..HEAD -- <手順2の絶対パス>` が空でないかを見る。空でなければ、エージェントが要件文書を書き換えたこと(Workflow はそれをプロンプトで禁じているだけで、コードでは止められない)と、それを変えたコミット(`git log --format='%h %s' <起動前の SHA>..HEAD -- <手順2の絶対パス>`)を、出力の先頭に書く。ただし要件文書が git に追跡されていなければ(`git ls-files --error-unmatch <手順2の絶対パス>` が失敗する。リポジトリの外にある場合と、gitignore 済みや未追跡のまま置かれた場合)、書き換えても差分に出ず、この確認は黙って通ってしまう。そのときは確かめられなかったことを書く。次に、要件文書を除いた Workflow が変えたファイル(`git diff --name-only <起動前の SHA>..HEAD`)を、ledger.json に記録されたファイル(`jq -r '.checksChanges[].file, .fixChanges[].file, .verifyFixChanges[].file'`。テスト/lint を通すための変更、レビュー指摘を直すための変更、動作確認を通すための変更)と突き合わせる。要件文書を突き合わせから外すのは、記録に載っていても書き換えてよい理由にはならないため。差分にあって記録に無いファイルがあれば、「報告に記録の無い変更」として列挙し、`git log --format='%h %s' <起動前の SHA>..HEAD -- <ファイル>` で、どのコミットが変えたかを添える。報告の変更の節はどれもエージェントの申告で、Workflow は git を見られないので、申告漏れはここでしか見つからない。`git status --porcelain` が空でなければ、Workflow のエージェントが未コミットの変更を残したこと(テスト/lint や動作確認の修正を途中で諦めた場合に起きる)と変更のあるファイルを、出力の先頭に書く。この変更は `<起動前の SHA>..HEAD` の範囲に入らないため、黙っていると人間が見落とす。消したりコミットしたりはせず、扱いはユーザーに委ねる。Workflow が値を返さずに終わった場合(Workflow ツールがエラーを返した場合)は、書き出しを飛ばし、値が無いことと Workflow のエラーを出力の先頭に書いたうえで、この手順の git による確認(祖先、要件文書の書き換え、未コミットの変更)だけを行う。途中までのコミットや未コミットの変更が残りうるため。ledger との突き合わせは ledger が無いのでできず、そのことも書く。報告の中身を要約して丸めない(Unresolved Finding と Requirements Concern は人間の判断材料なので、省略しない)。push と PR の作成はユーザーに委ねる。
9. **統計を投稿する。** 手順6で `stats-issue=` を控えたときだけ行う。返り値の `stats` を `$(git rev-parse --absolute-git-dir)/deliver/review-verify/stats.md` に Write ツールでそのまま書き出し、`gh issue comment <URL> --body-file <そのファイル>` で投稿する。`stats` に何も足さない(リポジトリ名・ブランチ名・SHA・報告の他の節)。仕事のリポジトリでの実行を public な Issue に投稿しうるためで、`stats` はそれらを含まないよう Workflow が組み立てている。Workflow が値を返さずに終わり `stats` が無い場合と、投稿に失敗した場合は、実行の失敗にはせず、投稿できなかったことと理由をユーザーに伝える(伝えないと、集めている統計の件数が黙って欠ける)。
