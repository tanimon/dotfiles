---
name: pr-body-review-unattended
description: PR 本文を現在の差分と照らし、食い違う記述(変更点・テスト方法・Acceptance criteria の対応・Closes など)を根拠付きで洗い出し、食い違う箇所だけを直した本文の案と食い違いの一覧をファイルに書いて止まる。質問も GitHub への書き込みもしない。対話版の `/pr-body-review` が Skill ツールで呼ぶときと、無人の呼び出し元が `claude -p` で起動するときに使う。本文を書き戻すのは pr-body-review の `scripts/writeback.sh` だけ。PR を新しく作るとき(骨格は /pr スキル、個人リポジトリの Issue Linkage の節は issue-linkage スキル)や、レビューコメントへの対応には使わない。
argument-hint: "<PR の URL | PR 番号> [--local <worktree の絶対パス>] [--out <出力先の絶対パス>]"
---

# pr-body-review-unattended

PR 本文を現在の差分と照らし(PR Body Review。用語は chezmoi リポジトリの `GLOSSARY.md`)、Stale PR Body なら食い違う箇所だけを直した案を作る。新しいコミットが積まれただけでは直さない。直すのは、差分と食い違う記述があるときだけ。

このスキルは質問せず(`AskUserQuestion` を使わない)、GitHub に書き込まない。成果物は出力先の 3 つのファイルだけ。

| ファイル | 中身 |
| --- | --- |
| `original.md` | 取得したときの本文(1 バイトも変えない) |
| `edited.md` | 食い違う箇所だけを直した本文。食い違いが無ければ `original.md` と同じ |
| `discrepancies.json` | 食い違いの一覧。無ければ `[]` |

`discrepancies.json` の 1 件は `{"section": "<本文の節の見出し>", "problem": "<食い違いの内容>", "evidence": "<根拠のコミットの SHA か、差分のファイル>"}`。

途中で失敗したら(PR を特定できない、差分を読めない、など)、`edited.md` と `discrepancies.json` を書かずに、理由を報告して止まる。呼び出し元は `edited.md` が無いことを失敗として扱う。

## 引数

- 1 つ目: PR の URL か番号。省くと現在のブランチの PR
- `--local <worktree>`: 差分を GitHub ではなく、その worktree の `<base>...HEAD` から読む(push の前のコミットを本文に反映するため)
- `--out <dir>`: 出力先。省くと手順 1 の既定の場所

## 1. 対象の PR と出力先を決める

```bash
gh pr view <引数> --json number,url,title,state,baseRefName,headRefName,commits
```

PR が無い・特定できないときは、理由を報告して止まる。`state` が `MERGED` / `CLOSED` でも続け、報告にそのことを書く(マージ済みの PR の AC 対応表も直す意味がある。chezmoi リポジトリの `docs/adr/0021-ac-mapping-table-is-the-completion-record.md`)。

以降のコマンドの `<PR>` には、ここで得た `url` を使う。番号を渡すと `gh` は現在のディレクトリのリポジトリで PR を探すので、別のリポジトリの URL で起動したときに別の PR を読んでしまう。以降の `<owner>` / `<repo>` / `<number>` も、この `url`(`https://github.com/<owner>/<repo>/pull/<number>`)から取る。

出力先(以降 `<dir>`)は、`--out` があればそれを使う。無ければ、`git rev-parse --absolute-git-dir` を単独で実行した出力に `/pr-body-review/<owner>-<repo>-<number>` を足したディレクトリにする。git リポジトリの外で起動して `git rev-parse` が失敗したとき、または sandbox が `.git` の下への書き込みを拒んで `mkdir -p <dir>` が失敗したときは、セッションの scratchpad ディレクトリの下に `pr-body-review/<owner>-<repo>-<number>` を作って `<dir>` にする。PR ごとに分けるのは、同じ worktree の別のセッションが別の PR を見直したときに、互いのファイルを上書きしないため。

```bash
mkdir -p <dir>
gh pr view <PR> --json body | jq -j .body > <dir>/original.md
```

本文は Write ツールで書き写さない。書き写すと空白や記号が変わり、`edited.md` との差分に無関係な変更が混ざる。`-q .body` も使わない。`-q` は出力の末尾に改行を足すので、それを書き戻すと実行のたびに本文の末尾の改行が増える。`jq -j` は本文を 1 バイトも足さずに出す。

## 2. 本文の規約を決める

本文をどう書くべきかは、このスキルに写さず正本を読む。

- **個人リポジトリ**: `bash ~/.claude/scripts/lib/issue-linkage-scope.bash <dir0> <owner/repo>` の終了コードが 0 なら、issue-linkage スキル(`~/.claude/skills/issue-linkage/SKILL.md`)の「PR を作る」節が規約(骨格は `/pr` スキルのテンプレート、その後ろに Issue Linkage の節)。`<dir0>` は `--local` があればその worktree、無ければ現在のディレクトリ(`$(pwd)`)。`<owner/repo>` は PR の URL から取る。
- **それ以外**: 対象リポジトリの既定ブランチにある PR テンプレートが規約。手元の作業ツリーは古いことがあるので GitHub から読む。

  ```bash
  gh api 'repos/<owner>/<repo>/contents/.github/pull_request_template.md' -H 'Accept: application/vnd.github.raw'
  ```

  404 ならテンプレートは無い。読み込まれているルールに PR 本文の書き方があれば、それにも従う。

## 3. 本文と差分を照らす

**`--local` が無いとき**: PR 全体の差分を GitHub から読む。

```bash
gh pr diff <PR> --name-only
gh pr diff <PR>
```

差分が大きいときは `--name-only` で全体を掴み、本文の記述に関係するファイルの差分を読む。`gh pr diff` はパスで絞れないので、ファイルごとの差分は `gh api repos/<owner>/<repo>/pulls/<number>/files --paginate` の `filename` と `patch` から読む。GitHub の上限(300 ファイル・20000 行程度)を超える PR では `gh pr diff` が HTTP 406 で失敗するので、そのときもこのコマンドで読む。食い違いを生んだコミットは、手順 1 の `commits` から当たりを付け、`gh api repos/<owner>/<repo>/commits/<sha> --jq '.files[] | {filename, patch}'` で読む(`<sha>` は `commits` の `oid`)。

**`--local <worktree>` があるとき**: その worktree の、PR の base から HEAD までを読む。`<base>` は手順 1 の `baseRefName`。

```bash
git -C <worktree> diff --no-ext-diff --name-only origin/<base>...HEAD
git -C <worktree> diff --no-ext-diff origin/<base>...HEAD -- <パス>
git -C <worktree> log --format='%H %s' origin/<base>..HEAD
git -C <worktree> show --no-ext-diff <sha>
```

`origin/<base>` が無ければ、失敗として止まる(GitHub の差分で代えると、push の前のコミットが本文に反映されない)。

どちらのときも、照らす相手は PR 全体の差分で、本文をいつ書いたかは問わない。`Closes #N` / `Refs #N` の issue の AC を読むときは、PR と同じリポジトリを指定する(`gh issue view <N> -R <owner>/<repo> --json body`)。指定しないと、現在のディレクトリのリポジトリにある同じ番号の issue を読んでしまう。

本文の記述を節ごとに差分と照らし、次に当たるものを食い違いとして洗い出す。

- 本文が述べる変更が差分に無い(取り消された、別の方法に変わった)
- 差分にある主要な変更が本文に書かれていない
- テスト方法・確認手順が、今の差分では成り立たない
- AC 対応表の「対応」が、差分に無いファイルやテストを根拠にしている。満たしたと書いた項目を、今の差分が満たしていない
- `Closes #N` / `Refs #N` が、今の差分が解決する範囲と合わない

文体の好み、言い回しの改善、差分と矛盾しない記述の詳細化は食い違いではない。直さない。

## 4. 本文の案と一覧を書く

`cp <dir>/original.md <dir>/edited.md` で複写する。食い違いがあれば、Read ツールで読んでから、食い違う箇所だけを Edit ツールで直す。手順 2 の規約の見出し・順序・節構成、規約が「原文のまま残す」とする節、不可視のコメント(`<!-- issue-linkage -->` など)は変えない。

最後に、手順の冒頭の形で `<dir>/discrepancies.json` を Write ツールで書く。食い違いが無ければ `[]`。

## 5. 報告して止まる

`<dir>` の絶対パス、食い違いの件数(と節ごとの要約)、照らした観点を短く報告する。`state` が `MERGED` / `CLOSED` ならそれも書く。対話版の `/pr-body-review` から呼ばれたときは、対話版の手順に戻る。
