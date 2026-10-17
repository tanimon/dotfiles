---
title: "chezmoi が source を辿る途中で、並列のレシピが作っては消す一時ファイルを lstat して落ちる"
date: 2026-10-17
category: integration-issues
problem_type: integration_issue
component: tooling
module: scripts/chezmoi-source-snapshot.sh
severity: medium
symptoms:
  - "`just lint-fast` がたまに落ち、単独で流し直すと通る"
  - "chezmoi: lstat <repo>/node_modules/.pnpm/lock.yaml.<乱数>: no such file or directory"
  - "chezmoi: lstat <repo>/_tmp_<pid>_<hash>: no such file or directory"
root_cause: async_timing
resolution_type: code_fix
tags: [chezmoi, just, pnpm, flaky, bats]
---

# chezmoi が source を辿る途中で、並列のレシピが作っては消す一時ファイルを lstat して落ちる

## 問題

`chezmoi execute-template` / `managed` / `source-path` に `--source <repo>` を渡すと、chezmoi はそのディレクトリ全体を辿り、各ディレクトリの一覧を取ってから項目を 1 つずつ lstat する。`.chezmoiignore` に書いたディレクトリ(`node_modules/` など)も辿る。無視するかどうかは辿った後に決まる。

`just lint` と `just lint-fast` は `[parallel]` なので、chezmoi で描画するレシピと、`pnpm exec` を使う別のレシピが同時に走る。pnpm はリポジトリの中に一時ファイルを作っては消す。chezmoi が一覧を取ってから lstat するまでの間にその一時ファイルが消えると、chezmoi は ENOENT で終了する。

## 症状

- `just lint-fast` を何回か流すと、描画を使うレシピがときどき落ちる。落ちるレシピは毎回違う(`test-nono-packs` のことも `check-templates` のこともある)。
- そのレシピを単独で流し直すと通る。
- エラーは `chezmoi: lstat <repo>/<一時ファイル>: no such file or directory` の 1 行だけ。

## 一時ファイルを作るもの

- `pnpm exec` は起動するたびに、リポジトリ直下に `_tmp_<pid>_<hash>` を作って消す(`pnpm exec true` を 30 回流す間に、直下で 12 回観測した)。
- `node_modules/.pnpm/lock.yaml.<乱数>` は、`pnpm exec` を流すだけでは書かれなかった(lock.yaml の mtime が変わらなかった)。どのコマンドが作るのかは確かめていない。
- 仕組みは作るものによらない。リポジトリの中で一瞬だけ存在するファイルなら、どれでも同じように落ちる。

## 再現

一時ファイルを人工的に作っては消すループを背景で回しながら、描画を繰り返す。

```bash
churn() { while :; do f="$dir/$prefix$RANDOM$RANDOM"; : >"$f"; rm -f "$f"; done; }
dir="$PWD/node_modules/.pnpm" prefix=lock.yaml. ; churn & churn &
for i in $(seq 30); do
  echo '{{ .chezmoi.os }}' | chezmoi execute-template --source "$PWD" >/dev/null
done
```

- `node_modules/.pnpm/` で回すと 29/30 回落ちた。リポジトリ直下で `_tmp_` を回すと 30/30 回落ちた。
- 一時ファイルを作らなければ 0/30 回だった。
- `.chezmoiignore` に書いていない、ファイルが 3,000 個あるディレクトリで回しても 18/20 回落ちた。無視の設定は関係ない。
- 中身が数個のディレクトリで回すと 0/20 回だった。一覧を取ってから lstat するまでの時間は、そのディレクトリで先に lstat する項目の数で決まる。ファイルの多い `node_modules/.pnpm/` と、項目の多いリポジトリ直下で落ちやすい。
- 本物の `pnpm exec true` を並走させた 40 回では 1 回も落ちなかった。実際の `lint-fast` で落ちるのは、多数のレシピが同時に `pnpm exec` を起動し、CPU が混み合うときだけだと推測している(測っていない)。

## うまくいかなかったこと

- **pnpm を使うレシピと描画するレシピを同時に走らせない。** ほぼすべての bats のレシピが `pnpm exec bats` で動き、描画するレシピ自身もそうなので、分けられない。
- **lstat の ENOENT が出たときだけ再試行する。** 再現の手順で 97% の確率で落ちるので、数回の再試行では落ち方がほとんど変わらず、直ったことを再現の手順で示せない。それに、競合そのものは残る。
- **`.chezmoiignore` に書く。** 上のとおり、chezmoi は無視する前に lstat する。

## 解決

chezmoi の `--source` に、リポジトリそのものではなく、作業ツリーをリポジトリの外に写したもの(`scripts/chezmoi-source-snapshot.sh`)を渡す。写しには誰も書き込まないので、この競合が起きない。

- 写すのは作業ツリーの内容で、commit していない編集と、`.gitignore` されていない未追跡ファイルを含む。`.git` と `.gitignore` されたものは写さない。
- 未追跡のファイルには pnpm の一時ファイルも混ざるので、写す前か写している間に消えたものは飛ばす。
- `test/helpers/render.bash` は、bats を 1 回実行するたびに写しを 1 つ作り、`RENDER_SOURCE` として suite のあいだで共有する。chezmoi を直接呼ぶ suite も `--source "$RENDER_SOURCE"` を使う。justfile の `check-templates` も、レシピの最初に写しを作る。
- 描画結果の `.chezmoi.sourceDir` は写しのパスになる。テンプレートが `{{ .chezmoi.sourceDir }}/…` で読むファイルは写しにもあるので、描画の結果は変わらない。

確認には、直す前と直した後で同じ人工の一時ファイルを流し、実際のレシピを走らせた(Contrast Pair)。

| レシピ | 直す前 | 直した後 |
|---|---|---|
| `test-nono-packs`(`node_modules/.pnpm/` で回した) | 3/3 回落ちた | 0/3 回 |
| `check-templates`(リポジトリ直下で回した) | 2/2 回落ちた | 0/2 回 |

`test/chezmoi-source-snapshot.bats` は、写しを source にした描画が一時ファイルの作成と削除の中でも落ちないことを確かめる。このケースで `--source` に写しではなくリポジトリを渡すと落ちることも確かめた。

## なぜ効くか

競合しているのは、「chezmoi が辿るディレクトリ」と「並列のレシピが書き込むディレクトリ」が同じであることだ。写しはリポジトリの外にあり、誰も書き込まないので、2 つが重ならない。写しを作るとき自体はリポジトリを読むが、消えたファイルを飛ばすことで同じ競合を避けている。

## 再発防止

- chezmoi で source state を読む検査を新しく書くときは、`--source` に `RENDER_SOURCE`(bats)か写しを渡す。`--source "$(pwd)"` やリポジトリのパスを直接渡さない。
- `lint` に並列のレシピがある限り、リポジトリ全体を辿るほかの検査(`secretlint '**/*'`、`scan-sensitive`)も、理屈のうえでは同じ競合を受けうる。今のところ観測はしていない。

## 関連

- `scripts/chezmoi-source-snapshot.sh`、`test/helpers/render.bash`
- [workflow-issues/verification-through-the-wrong-resolution-path.md](../workflow-issues/verification-through-the-wrong-resolution-path.md)(`--source` を渡さないと別の source を見る、という逆向きの落とし穴)
