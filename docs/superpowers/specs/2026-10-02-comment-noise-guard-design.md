# コメントのノイズ防止(ルール + lint)設計

PR #392 で直した種類のコメント、すなわち読み手(主にエージェント)に誤った前提を渡すコメントや、正本を複数にするコメントが再び書かれないようにする。書く前に効くルールと、書いた後に止める決定的な lint の 2 層で構成する。

## 背景

#392 の棚卸しでは、ノイズを 3 種類に分けた。

- **STALE**: コードと食い違う。存在しない参照先、向きが逆の位置参照(「上の」)、ずれた行番号を含む
- **DUP**: 他の文書の写しになっていて、正本が複数ある
- **HISTORY**: 「以前は」、コミット SHA、日付つきの「更新:」の積み重ね、「#309 Task 2 で発覚」のような作業の経緯

着手時点では、コメントの書き方を定めたルールはグローバルにもこのリポジトリにも無かった。ECC から取り込んでいる `typescript/` と `web/` の `coding-style.md` にも無い。書き手の多くはエージェントで、ルールが無いまま書くと同じ種類のコメントが再生産される。

## 範囲

- ルールはグローバルに置く(`dot_claude/rules/common/`)。仕事用リポジトリと Codex にも効かせるため。
- lint はこのリポジトリにだけ置く。
- レビュー観点(deliver / review-verify への追加)と定期の棚卸しは、今回は作らない。STALE と DUP の大半は意味の判断が必要で、lint では捕まえられない。その部分はルールで書き手に任せる。

## 1. ルール `dot_claude/rules/common/code-comments.md`

日本語で、製品名・製品固有のツール名・このリポジトリ固有のパスを書かない。Codex の `AGENTS.md` にも連結されるからである。分量は 3 KB 以内に収める。着手時点の `~/.codex/AGENTS.md` は 22.8 KB で、上限 32 KiB までの残りは約 10 KB。

内容は次の 5 項目。各項目に理由を添える。

1. コメントに書くのは、コードから読み取れず、今も成り立つ理由だけにする。
2. 経緯はコミット・PR・ADR に書く。不採用にした案は、同じ失敗を繰り返さないための情報なので残すが、現在形の事実として書く。例として次を Before/After で示す(出典は `dot_config/git/claude-code.inc` の該当箇所で、ルール本文には出典パスを書かない)。
   - Before: 「以前は `.zshrc` 経由の export で抑制しようとしたが、…一度も効いていなかった」
   - After: 「`.zshrc` での export では抑制できない。Bash ツールは非対話シェルで動き `.zshrc` を読まないため」
3. 正本は 1 つにする。他の文書の内容を写さず、ポインタにする。
4. 「上の」「下の」、行番号、計画の内部番号(Task N)のような、位置や他の文書の文脈に依存する参照をしない。名前で参照する。
5. コードを変えたら、同じ範囲のコメントを読み直す。

`dot_codex/AGENTS.md.tmpl` に `{{ include "dot_claude/rules/common/code-comments.md" }}` を 1 行足す。`test/global-instructions.bats` は、rules が全件連結されていることと 32 KiB 以内に収まることを検査している。

## 2. lint `scripts/check-comment-noise.sh`

構成は `scripts/scan-sensitive-info.sh` に合わせる。パターンはスクリプト内に名前付きで持ち、例外は許可リストファイルで与える。

### 対象

- `git ls-files` の全ファイルから、次を除いたもの: `*.md`、拡張子が `.md` でない Markdown(`*.md.tmpl`、生成物の `*.mdc`、`.chezmoitemplates/agent-instructions-common`)、`docs/` 配下、`*.json`、`pnpm-lock.yaml`
- `.md` を対象外にする理由: docs・ADR・solutions・CLAUDE.md は、経緯を記録すること自体が正当な場合が多い。#392 では `dot_claude/scripts/CLAUDE.md` も直したが、Markdown の経緯の記述は lint で機械的に判定できない。

### コメント行の判定

行頭(空白を除く)が `#` か `//` で始まる行だけを見る。1 行目の `#!` は除く。行末コメントは見ない。`$#`、URL 中の `//`、文字列の中の `#` による誤検知を避けるためである。

### パターン

| 名前 | 判定 | 意図 |
|---|---|---|
| `plan-step` | `(^|[^A-Za-z])(Task|Step) [0-9]+` | 計画の内部番号。計画を読んでいない読み手には意味がない |
| `issue-origin` | `#[0-9]+` の後、24 バイト以内(`LC_ALL=C` で判定するので日本語ならおよそ 8 文字)に「で発覚 / で追加 / で導入 / で修正 / で判明」が続く。または `(added|introduced|found|fixed) in #[0-9]+` | 作業の経緯。未解決 issue への参照(`#382(未解決)` など)は止めない |
| `missing-path` | コメント中のトークンのうち、`/` を含み、先頭の要素がリポジトリのトップレベルのディレクトリ(`git ls-files` から導く)と一致するものについて、`test -e` で実在を確かめる。`{`、`<`、`*`、`$` を含むトークンは確かめない。末尾の句読点・括弧・バッククォート・`:行番号`・`#アンカー` は落としてから判定する。gitignore されたパス(ローカルにだけ置くファイル)は存在しなくても止めない。判定にマシンのグローバルな除外(`core.excludesfile`)は使わない | 参照先の消失(STALE のうち機械的に判定できる部分) |

正規表現は `grep -E` と bash の `=~` だけで書き、`-P` や `\b` は使わない。CI は Ubuntu(GNU)、ローカルは macOS(BSD)で動くため。

### 例外

`scripts/comment-noise-allowlist.txt` に `<path-suffix or *>:<regex>` の形で書く。`#` で始まる行と空行は無視する。正規表現は読み込み時に検査し、不正なものがあれば exit 2 で止める(一致する違反が出るまで検出されない状態を作らないため)。

### 出力と終了コード

- 違反 1 件につき 1 行、`<file>:<line>: [<pattern 名>] <該当行>` を出す。
- 違反があれば、最後に規約がルールファイル(`dot_claude/rules/common/code-comments.md`)にあることだけを案内し、exit 1 で終える。規約の本文は写さない(lint 自身が DUP にならないため)。
- 違反が無ければ、何も出さずに exit 0 で終える。

### 組み込み

- `justfile`: `check-comment-noise` と `test-comment-noise` のレシピを作り、どちらも `lint` の依存に加える
- `.github/workflows/lint.yml`: 両方のジョブを足す(`lint` の依存はすべて CI のジョブにするという規約に従う)
- `.pre-commit-config.yaml`: `check-comment-noise` のフックを足す(`pass_filenames: false`。リポジトリ全体を走査するため)

## 3. 既存の違反

同じ PR で直す。全体を走査する方式なので、違反を残したままでは lint が赤になる。着手時点で分かっているのは `.pre-commit-config.yaml` の shellcheck のコメントにある「#309 Task 2 で発覚」。`missing-path` の違反は、実装してから走査して洗い出す。直すより残す方が正しいものは、理由を添えて許可リストに入れる。

## 4. テスト `test/check-comment-noise.bats`

一時ディレクトリに git リポジトリを作って fixture を置き、スクリプトをそこで実行する。パターンごとに、止まるべき fixture と通るべき fixture を対にする(片方だけが通っても何の証明にもならないため)。

- `plan-step`: 止まる `# Task 2 で追加`。通る `# Taskfile を読む`、`.md` 内の `Task 2`
- `issue-origin`: 止まる `# (#309 で発覚)`、`// fixed in #12`。通る `# #382(未解決)が直るまでの暫定`
- `missing-path`: 止まる `# 詳細: docs/missing.md`。通る、実在するパス・`~/.claude/x`・`dot_claude/<name>/x`・`docs/{a,b}/`・`https://example.com/docs/x`
- コメントの判定: 止まらないもの。コードの行の中の `Task 2`(`echo "Task 2"`)、行末コメント、1 行目の `#!`
- 許可リスト: 許可リストに書いた違反は止まらず、許可リストから外すと止まる
- 出力: 違反があると exit 1 になり、ルールファイルのパスを含む。違反が無ければ出力は空で exit 0

## 対象外にしたもの

- 「以前は」「used to」などの言葉と、括弧書きの実測日(`(2026-09-18)`)の lint: 着手時点で走査すると、正当な用法(不採用案の記録、実測した証拠の日付、`can be used to`)が混ざっていた。ルールだけで扱う。
- コミット SHA と日付つきの「更新:」の lint: 着手時点で 0 件だったため、作らない(YAGNI)。
- Markdown の lint、レビュー観点、定期の棚卸し: 「範囲」を参照。
