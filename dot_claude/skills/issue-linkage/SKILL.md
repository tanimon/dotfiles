---
name: issue-linkage
description: issue と PR の Issue Linkage(関連 issue のメンション、Parent / Blocked by、Closes / Refs、AC 対応表)を書くときに使う。issue-linkage-guard フックが gh issue create / gh pr create を deny したときも使う。PR 本文の骨格(Summary / Evidence / Merge Danger)は /pr スキル、作成済みの PR 本文と差分の照合は pr-body-review スキルが受け持つ。仕事リポジトリ(チケットは Notion)には使わない。
---

# issue-linkage

issue と PR の Issue Linkage(用語は chezmoi リポジトリの `GLOSSARY.md`)を、作成の瞬間に漏らさず書く。このスキルが書くのは Issue Linkage の節だけで、本文のほかの節には触れない。設計は chezmoi リポジトリの spec #577(`gh issue view 577 --repo tanimon/dotfiles`)。

最初に `bash ~/.claude/scripts/lib/issue-linkage-scope.bash "$(pwd)"` を実行する。終了コードが 0 以外なら範囲外なので、このスキルは使わずにユーザーへそう伝える。

## 共通の準備

1. **置き場所を決める。** `git rev-parse --absolute-git-dir` を単独で実行し、出力に `/issue-linkage` を足したディレクトリを使う(以降 `<dir>`)。本文は Write ツールで `<dir>/issue-body.md` か `<dir>/pr-body.md` に書く。コマンドには `$(…)` や `$TMPDIR` を含めず、展開済みの絶対パスを書く(issue-linkage-guard は展開前の文字列しか読めない)。
2. **関連 issue を探す。** タイトルの主要な語を 2〜3 通り変えて `gh issue list --state all --search "<語>" --limit 20 --json number,title,state` を実行する。関連するものを `## 関連` 節に `- #N <なぜ関連するかを 1 行>` で書く。見つからなければ「関連 issue なし(検索語: …)」と書く。

## issue を作る

本文に `## 関連`・`## Parent`・`## Blocked by` の節を置く。

- **relationship。** 親は `## Parent`、先に片付ける必要がある issue は `## Blocked by` の節に `#N` で書く。関係として読むのは行頭(`- ` などの箇条書きの記号の後ろと、見出しと同じ行の見出し語の後ろを含む)に置いた `#N` だけで、「なし。#402 がこの issue に依存する。」のような文中の `#N` は関係にならない。関係が無ければ「なし」と書き、補足は `#N` を行頭に置かずに書く。
- **作る。** 本文を書き終えたら「本文の仕上げ」節のマーカーを付けてから、`bash ~/.claude/skills/issue-linkage/scripts/create-issue.sh --title "<title>" --body-file <dir>/issue-body.md`(`--label` などは後ろに足せば `gh issue create` に渡る)。作成と同時に、`## Parent` と `## Blocked by` の関係を native の relationship として張る。終了コード 1 は「issue は作ったが relationship の一部を張れなかった」なので、stderr に出た関係を `references/relationship-api.md` のコマンドで張り直す。終了コード 2 は何も作っていない。stderr の理由を直して再実行する。作成先が範囲外と出たときは、再実行しても通らないのでユーザーに伝える。範囲内のリポジトリで `gh issue create` を直接使うと issue-linkage-guard が deny する。

## PR を作る

骨格は `/pr` スキル(Skill ツールで `mattpocock-skills:pr`)のテンプレートで書き、その `## Merge Danger` の後ろに Issue Linkage の節を次の形で足す。

```markdown
## 関連

- #N <なぜ関連するかを 1 行>

Closes #N
Refs #M

## Acceptance criteria の対応

| issue | 項目 | 対応 |
|---|---|---|
| #N | <AC の項目> | <満たした変更(ファイルやテスト)、または満たさない理由> |
```

- **Closes / Refs。** `## 関連` の箇条書きの後ろに、解決する issue ごとに `Closes #N` を 1 行ずつ書く(`Closes #1, #2` は 2 件目が効かない)。部分的にしか解決しない issue は `Refs #N` にする。`Closes` による自動 close は既定ブランチへのマージでしか効かない。
- **AC 対応表。** 完了の記録になる表で、close 済み issue の AC のチェックボックスはそろえない(chezmoi リポジトリの `docs/adr/0021-ac-mapping-table-is-the-completion-record.md`)。後から完了を確かめる人はこの表を読むので、`Closes` と `Refs` のどちらの issue も、AC(`gh issue view <N> --json body`)の項目ごとに 1 行を書き、満たさない項目にはその理由を書く。AC の節が無い issue(spec など)は項目を `(全体)` とした 1 行にし、どの issue の行やどの変更で満たしたかを書く。
- **作る。** 本文を書き終えたら「本文の仕上げ」節のマーカーを付けてから、`gh pr create --head <branch> --title "<title>" --body-file <dir>/pr-body.md`。

## 本文の仕上げ

issue も PR も、本文を書き終えたら最後の行を `<!-- issue-linkage -->`(マーカー)にする。署名(`🤖 Generated with …`)など末尾に足す行があれば、すべてマーカーより前に置く。マーカーが無い本文は、create-issue.sh も issue-linkage-guard も作成を止める。
