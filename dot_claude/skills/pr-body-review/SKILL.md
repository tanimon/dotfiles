---
name: pr-body-review
description: PR 本文を現在の差分と照らし、食い違う記述(変更点・テスト方法・Acceptance criteria の対応・Closes など)を根拠付きで示して、承認を得てから食い違う箇所だけを書き戻す。`/pr-body-review` と打ったときだけ動く。照らし合わせと本文の案は pr-body-review-unattended が、書き戻しは `scripts/writeback.sh` が行う。
argument-hint: "[<PR 番号 | PR の URL>]"
disable-model-invocation: true
---

# pr-body-review

PR Body Review(用語は chezmoi リポジトリの `GLOSSARY.md`)の対話版。照らし合わせは無人版に任せ、このスキルは結果を示して承認を取り、書き戻しのスクリプトを呼ぶ。承認なしに GitHub へ書き込まない。

## 1. 対象の PR を決める

```bash
gh pr view <引数> --json url,state
```

引数が無ければ `<引数>` を省き、現在のブランチの PR を対象にする。PR が無い・特定できないときは、理由を伝えて止まる。`state` が `MERGED` / `CLOSED` なら、そのことを伝えて続けるかを `AskUserQuestion` で聞く(マージ済みの PR の AC 対応表は issue を解決したことの記録として後から読まれるので、直す意味はある。chezmoi リポジトリの `docs/adr/0021-ac-mapping-table-is-the-completion-record.md`)。

以降の `<PR>` には、ここで得た `url` を使う。番号を渡すと、別のリポジトリの PR を読み書きしてしまうことがある。

## 2. 照らし合わせる

Skill ツールで `pr-body-review-unattended` を、引数 `<PR>` で呼び、その手順を最後まで行う。出力先(以降 `<dir>`)に `original.md`・`edited.md`・`discrepancies.json` ができる。`edited.md` ができなければ、無人版が報告した理由を伝えて止まる。

## 3. 食い違いが無ければ終わる

`discrepancies.json` が `[]` なら、「食い違いなし」と、照らした観点を短く報告して終わる。GitHub には何も書き込まない。

## 4. 承認を求める

`discrepancies.json` を節ごとにまとめた一覧(節・食い違いの内容・根拠のコミットか差分)と、次の差分を示す。

```bash
git diff --no-index --no-ext-diff <dir>/original.md <dir>/edited.md
```

`AskUserQuestion` で「この内容で書き戻す / 直してから書き戻す / やめる」を選んでもらう。「直してから書き戻す」が選ばれたら、指示どおりに `<dir>/edited.md` を Edit ツールで直し、この手順の一覧と差分の提示からやり直して、もう一度選んでもらう。最終形を見せないまま書き戻さない。直した結果 `<dir>/edited.md` が `<dir>/original.md` と同じになったら、書き戻さずに手順 6 へ進む。

## 5. 書き戻す

```bash
bash ~/.claude/skills/pr-body-review/scripts/writeback.sh <PR> <dir>/original.md <dir>/edited.md
```

スクリプトは、書く直前に本文を取り直して `original.md` と照らし、書いた後にもう一度取り直して `edited.md` と照らす。

- **終了コード 0**: 書き戻して照合した
- **終了コード 1**: 何も書いていない。標準エラーに理由が出る。確認の間に誰かが本文を変えたときは、手順 2 からやり直す(`gh pr edit --body-file` は本文を全部置き換えるので、そのまま書くと他の人の変更を消す)。やり直すと `<dir>/edited.md` は作り直されるので、「直してから書き戻す」で受けた指示があれば、新しい案にもう一度当ててから手順 4 で見せる。本文を取得できなかったとき、または `gh pr edit` が失敗して本文が元のままのときは、その旨を伝えて止まる
- **終了コード 2**: 書いた後の本文が `edited.md` と食い違う。標準エラーの差分をそのまま報告する。自分で書き直して再試行しない(差が GitHub 側の正規化なのか取りこぼしなのかは、差分を見た人が判断する)。`<dir>/original.md` は残してあるので、元に戻すと決まったらそれを `gh pr edit <PR> --body-file` に渡す

## 6. 報告する

直した箇所と根拠、書き戻した後の確認の結果を報告する。直さなかった食い違い(ユーザーが「直してから書き戻す」で外したもの)があれば、それも書く。
