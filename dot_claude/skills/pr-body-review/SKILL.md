---
name: pr-body-review
description: PR 本文を現在の差分と照らし、食い違う記述(変更点・テスト方法・Acceptance criteria の対応・Closes など)を根拠付きで洗い出して、承認を得てから食い違う箇所だけを直す。「PR の本文が古くなっていないか見て」「push したので PR 本文を見直して」「PR description を差分に合わせて直して」「/pr-body-review」など。PR を新しく作るとき(個人リポジトリなら ticket スキル)や、レビューコメントへの対応には使わない。
argument-hint: "[<PR 番号 | PR の URL>]"
---

# pr-body-review

PR 本文を現在の差分と照らし、Stale PR Body なら食い違う箇所だけを直す(PR Body Review。用語は chezmoi リポジトリの `CONTEXT.md`)。新しいコミットが積まれただけでは直さない。直すのは、差分と食い違う記述があるときだけ。

## 1. 対象の PR を決める

```bash
gh pr view <引数> --json number,url,title,state,baseRefName,headRefName,commits
```

引数が無ければ `<引数>` を省き、現在のブランチの PR を対象にする。PR が無い・特定できないときは、理由を伝えて止まる。`state` が `MERGED` / `CLOSED` なら、そのことを伝えて続けるかを聞く(マージ済みの PR の AC 対応表は ticket スキルの照合モードが根拠として読むので、直す意味はある)。

以降のコマンドの `<PR>` には、ここで得た `url` を使う。番号を渡すと `gh` は現在のディレクトリのリポジトリで PR を探すので、別のリポジトリの URL で起動したときに別の PR を読み書きしてしまう。

編集前の本文をファイルに保存する。置き場所は `git rev-parse --absolute-git-dir` を単独で実行した出力に `/pr-body-review` を足したディレクトリ(以降 `<dir>`)。

```bash
mkdir -p <dir>
gh pr view <PR> --json body | jq -j .body > <dir>/original.md
```

本文は Write ツールで書き写さない。書き写すと空白や記号が変わり、手順5の差分に無関係な変更が混ざる。`-q .body` も使わない。`-q` は出力の末尾に改行を足すので、それを書き戻すと実行のたびに本文の末尾の改行が増える。`jq -j` は本文を 1 バイトも足さずに出す。

## 2. 本文の規約を決める

本文をどう書くべきかは、このスキルに写さず正本を読む。

- **個人リポジトリ**: `bash ~/.claude/scripts/lib/ticket-scope.bash "$(pwd)" <owner/repo>`(`<owner/repo>` は PR の URL から取る)の終了コードが 0 なら、ticket スキル(`~/.claude/skills/ticket/SKILL.md`)の作成モードの手順4・5が規約。
- **それ以外**: 対象リポジトリの既定ブランチにある PR テンプレートが規約。手元の作業ツリーは古いことがあるので GitHub から読む。

  ```bash
  gh api 'repos/<owner>/<repo>/contents/.github/pull_request_template.md' -H 'Accept: application/vnd.github.raw'
  ```

  404 ならテンプレートは無い。読み込まれているルールに PR 本文の書き方があれば、それにも従う。

## 3. 本文と差分を照らす

```bash
gh pr diff <PR> --name-only
gh pr diff <PR>
```

差分が大きいときは `--name-only` で全体を掴み、本文の記述に関係するファイルの差分を読む。コミットの一覧(手順1の `commits`)で、本文を書いた後に何が積まれたかを掴む。

本文の記述を節ごとに差分と照らし、次に当たるものを食い違いとして洗い出す。

- 本文が述べる変更が差分に無い(取り消された、別の方法に変わった)
- 差分にある主要な変更が本文に書かれていない
- テスト方法・確認手順が、今の差分では成り立たない
- AC 対応表の「対応」が、差分に無いファイルやテストを根拠にしている。満たしたと書いた項目を、今の差分が満たしていない
- `Closes #N` / `Refs #N` が、今の差分が解決する範囲と合わない

文体の好み、言い回しの改善、差分と矛盾しない記述の詳細化は食い違いではない。直さない。

## 4. 食い違いが無ければ終わる

食い違いが 1 件も無ければ、「食い違いなし」と、照らした観点を短く報告して終わる。GitHub には何も書き込まない。

## 5. 直した本文を作り、承認を求める

`cp <dir>/original.md <dir>/edited.md` で複写し、Read ツールで読んでから、食い違う箇所だけを Edit ツールで直す。手順2の規約の見出し・順序・節構成、規約が「原文のまま残す」とする節、不可視のコメント(`<!-- ticket-skill -->` など)は変えない。

食い違いを節ごとにまとめた一覧(節・食い違いの内容・根拠のコミットか差分)と、次の差分を示す。

```bash
git diff --no-index --no-ext-diff <dir>/original.md <dir>/edited.md
```

`AskUserQuestion` で「この内容で書き戻す / 直してから書き戻す / やめる」を選んでもらう。承認なしに書き込まない。

## 6. 書き戻して確かめる

書き戻す直前に本文を取得し直し、`<dir>/original.md` と一致することを確かめる。

```bash
gh pr view <PR> --json body | jq -j .body > <dir>/current.md
cmp <dir>/original.md <dir>/current.md
```

一致しなければ、確認の間に誰かが本文を変えている。書き戻さずに手順1からやり直す(`gh pr edit --body-file` は本文を全部置き換えるので、そのまま書き戻すと他の人の変更を消す)。

一致したら書き戻し、同じ方法でもう一度取得して `<dir>/edited.md` と `cmp` で比べる。

```bash
gh pr edit <PR> --body-file <dir>/edited.md
```

書き戻した後に一致しなければ、`git diff --no-index --no-ext-diff <dir>/edited.md <dir>/current.md` の結果をそのまま報告する。自分で書き直して再試行しない(差が GitHub 側の正規化なのか取りこぼしなのかは、差分を見た人が判断する)。`<dir>/original.md` は残してあるので、元に戻すと決まったらそれを `--body-file` に渡す。

## 7. 報告する

直した箇所と根拠、書き戻した後の確認の結果を報告する。直さなかった食い違い(ユーザーが「直してから書き戻す」で外したもの)があれば、それも書く。
