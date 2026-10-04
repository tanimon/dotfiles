# ticket スキル設計

GitHub Issues でチケットを管理する個人リポジトリで、issue と PR の関係づけの漏れを防ぐ。本書は 2026-10-04 の brainstorming で合意した内容を記録する。

## 解決する課題

1. issue の relationship(sub-issue / blocked-by)の設定が漏れる。例: #450 は本文に `## Blocked by #401` と書いてあるが、native の依存関係は未設定(`issue_dependencies_summary.total_blocked_by` が 0)。parent は native に設定済み。
2. PR で解決した issue が open のまま残る。#433・#429・#418 は close 済みだが `closedByPullRequestsReferences` が空で、PR 本文の `Closes #N` による紐付けを経ていない。
3. PR で解決した issue の Acceptance criteria が `[ ]` のまま残る。
4. 関連する issue へのメンション(`#N`)を自律的に書かない。

4つとも「やり忘れ」なので、スキルを置くだけでは解決しない。スキルはモデルが使うと判断したときにしか起動せず、忘れる場面ではスキルの起動も忘れるからである。そのため、スキル(手順の正本)と、作成時に決定的に発火するガードを組み合わせる。

## 適用範囲

- 対象は個人リポジトリ全般。仕事リポジトリ(チケットは Notion)は対象外。
- PR は主に GitHub の UI でマージする。マージの瞬間には Claude Code が関与しないので、マージ後の処理は手動で起動する照合モードが担う。
- 定期スイープ(launchd)とマージ時の GitHub Actions は採らない。

## 構成

| 部品 | 置き場所 | 役割 |
|---|---|---|
| スキル `ticket` | `dot_claude/skills/ticket/SKILL.md` → `~/.claude/skills/ticket/` | 手順の正本。作成モードと照合モードを持つ |
| 作成時ガード | `dot_claude/scripts/executable_ticket-guard.sh` → `~/.claude/scripts/ticket-guard.sh` | PreToolUse(`matcher: "Bash"`)。`gh issue create` / `gh pr create` の本文にマーカーが無ければ deny する |
| 適用範囲の判定 | `dot_claude/scripts/lib/ticket-scope.bash` → `~/.claude/scripts/lib/ticket-scope.bash` | origin の owner が許可リストにあるかを判定する。ガードが source し、deliver の入口 skill が直接実行する |
| 照合スクリプト | `dot_claude/skills/ticket/scripts/executable_audit.sh` | 照合モードの検出部分。LLM を使わずに食い違いを列挙する |

手順の正本はこのスキルだけにする。`docs/agents/issue-tracker.md` にある sub-issue と dependency の API 手順は、このスキルを参照する形に書き換える。2か所に写すと食い違うため。

## 作成モード

issue や PR を作る前に、本文ファイルを次の手順で作る。

1. **関連 issue を探してメンションする**(課題4)。タイトルと本文の語で `gh issue list --search` を実行し、関連する open / closed の issue を本文中で `#N` として参照する。参照する理由も1行添える。
2. **relationship を本文に書き、native にも設定する**(課題1)。parent は `## Parent`、blocker は `## Blocked by` の節に書く。作成後に `gh api` で sub-issue と `dependencies/blocked_by` を設定する。依存関係の API が受け取るのは blocker の database id(`gh api repos/<o>/<r>/issues/<n> --jq .id`)で、`#number` や `node_id` ではない。
3. **PR 本文に `Closes #N` と AC 対応表を書く**(課題2・3の前準備)。対応表は、issue の AC の各項目について、それを満たす変更(ファイルやテスト)を示す。満たさない項目は、満たさない理由と一緒に載せる。
4. **本文の末尾にマーカー `<!-- ticket-skill -->` を付ける。** 本文ファイルは `$(git rev-parse --absolute-git-dir)/ticket/` の下に置き、`--body-file <絶対パス>` で渡す。

`Closes #N` による自動 close は、既定ブランチへのマージでしか効かない。stacked PR が下のブランチにマージされても issue は close されないので、その分は照合モードが拾う。

## 照合モード

ユーザーが手動で起動する。対象はカレントのリポジトリ。

### 検出(`audit.sh`、決定的)

- **relationship の食い違い**: 本文の `## Parent` / `## Blocked by` 節にある番号と、API の `parent_issue_url` / dependencies を比べる。
- **open のまま残った issue**: マージ済み PR の `closingIssuesReferences` から辿り、まだ open の issue を探す。
- **AC の未チェック**: close 済みで、その issue を close した PR がマージ済みのもののうち、AC 節に `[ ]` が残る issue を探す。AC 節の見出しは `Acceptance criteria` と `完了条件` で始まるものとする(`## 完了条件(案)` などの揺れを許す)。

出力は1行1件の機械可読な形式(種類・issue 番号・根拠)にする。

### 修正

- AC を `[x]` にしてよいのは、マージ済み PR の本文の対応表に根拠がある項目だけ。対応表に無い項目と、意図的に `[ ]` のまま残した項目(#434 の「skip 方式を採ったため不要」のように理由が書かれたもの)は触らず、報告に載せる。
- 修正案は種類ごとの一覧(issue・操作・根拠)で示す。`AskUserQuestion` で「全部適用 / 種類ごとに選ぶ / やめる」を選んでもらってから書き込む。誤った判定が公開される前に止めるため。自分が author の issue を承認なしで更新するかどうかは #443 で別に扱う。

## 作成時ガード

### 判定

コマンド文字列は、既存の `dot_claude/scripts/lib/shell-reader.bash` で読む。`cd … && gh pr create` のように連結されていても、区切りごとに判定する。

| 入力 | 結果 |
|---|---|
| `gh issue create` / `gh pr create` を含まない | 無出力で通す |
| origin が無い、GitHub 以外、owner が許可リストに無い | 無出力で通す |
| `--body-file` / `-F` の絶対パスのファイルにマーカーがある | 無出力で通す |
| `--body` / `-b` の値にマーカーがある | 無出力で通す |
| マーカーが無い(`--fill` / `--web` もここに入る) | deny |
| `--body-file` が変数を含むパス、相対パス、`-`、読めないファイル | 理由付きで deny |
| reader が読み切れない(長すぎる、引用符が閉じない、番兵の byte を含む) | 無出力で通す |
| heredoc 演算子より後ろの segment(本文の行でありうる) | 判定しない |

- deny の理由文には「`ticket` スキルの作成モードで本文を作り、`$(git rev-parse --absolute-git-dir)/ticket/` の下の本文ファイルを `--body-file` に絶対パスで渡して再実行する」と書く。deliver や他のスキルが、人の手を借りずに立て直せるようにするため。
- 相対パスは deny する。`cd` が前に連結されていると、フックが受け取る cwd からは解決できないため。
- `gh pr edit` / `gh issue edit` は対象にしない。作成時に一度ガードを通っていれば足りる。
- 読み切れない入力を通すのは git-push-guard と逆の向き。このガードの目的は起動忘れの防止で、読めないことを理由に deny すると無関係なコマンドを止める損の方が大きい。
- owner の許可リストはスクリプト内の定数(既定値は `tanimon`)で、環境変数 `TICKET_GUARD_OWNERS` で上書きできる。書くのは公開済みの個人アカウント名だけなので、identity leak guard に触れない。仕事 org の除外リスト方式は採らない。`.ghOrg` を使うテンプレートになって shellcheck が効かなくなり、OSS リポジトリへの PR まで対象になるため。

### 配線

`dot_claude/settings.json.tmpl` の PreToolUse に、理由を書いた `{{/* */}}` コメント付きで追加する。git-push-guard と同じく、スクリプトを直接呼ぶ。

### 残存

- launchd から起動されるスクリプトが直接 `gh` を呼ぶ経路(`harness-weekly.sh`)と、`gh api` で issue / PR を作る経路には効かない。
- フックが無い、またはクラッシュしたときは無出力になり、判定なしで通る(フェイルオープン)。
- マーカーは手で書けるので、手順を飛ばしてマーカーだけ付けることは防げない。ガードの目的は「スキルの起動を忘れる」ことを防ぐことで、意図的な迂回を防ぐことではない。

## 同じ変更で直す既存経路

- **deliver**: `deliver.js` は、サブエージェントの Bash で `gh pr create --draft --body-file …/pr-body.md` を実行する。PreToolUse フックはサブエージェントにも効くので、直さないと自律実行が deny で止まる。引数 `ticket`(真偽値)を足し、入口 skill が `ticket-scope.bash` で範囲内と判定したときだけ `true` にする。`true` のとき、Workflow は公開の前にエージェント(label `ticket`)に作成モードの PR 向けの手順で「## チケット」節を作らせ、報告の後ろに節とマーカーを付けたものを PR 本文にする。節を作れなかったときも公開は止めず、作れなかったことを本文に書く(止めると PR ごと失うため)。返り値に PR 本文 `prBody` を足し、公開に失敗したときに入口 skill が書き出すのはこれにする。
- **issue-tracker.md**: API 手順の記述を、スキルを参照する形に置き換える。
- `ce-commit-push-pr` などの外部プラグインのスキルは直せない。これらは deny の理由文に従って立て直す。

## テスト

- `test/settings-hooks.bats`: ガードが配線されていることを確認する。
- ガード本体の bats は、対になるケースを並べて書く。
  - マーカーあり → 通る / マーカーなし → deny
  - 許可リスト外 → 素通し / 許可リスト内 → deny
  - `cd … &&` で連結 → 判定される
  - 変数を含むパス・`--fill` → deny
- `audit.sh` の bats は `gh` をスタブにする。#450 と同じ形(本文に Blocked by があり、API 側は未設定)を検出し、両方揃っているときは検出しないことを、対にして確かめる。

## ドキュメント

- ガードの判定と残存は、スクリプト冒頭のコメントに書く。`dot_claude/scripts/CLAUDE.md` には書かない(サイズ上限 70035 バイトに対し 70032 バイトで余白が無い。#449)。
- SKILL.md は短く保ち、詳細は同梱のファイルに分ける(#440 で議論しているサイズ上限に合わせる)。

## 関連

- #443 自分が author の issue / PR の作成や更新を自動実行できるようにしたい(照合モードの承認の要否)
- #440 skill の本文にもサイズ上限を設ける
- #450 relationship の食い違いの実例
