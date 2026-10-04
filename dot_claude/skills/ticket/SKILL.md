---
name: ticket
description: GitHub Issues でチケットを管理する個人リポジトリで、issue / PR を作るとき(作成モード)と、マージ後の関係づけの漏れを洗い出して直すとき(照合モード)に使う。「issue を作って」「PR を作って」「issue を整理して」「close し忘れの issue を探して」「AC のチェック漏れを直して」「/ticket」など。ticket-guard フックが gh issue create / gh pr create を deny したときも使う。仕事リポジトリ(チケットは Notion)には使わない。
argument-hint: "[audit]"
---

# ticket

issue と PR の関係づけ(関連 issue のメンション、parent / blocked-by、`Closes #N`、Acceptance criteria)を漏らさないための手順。設計は chezmoi リポジトリの `docs/superpowers/specs/2026-10-04-ticket-skill-design.md`。

最初に `bash ~/.claude/scripts/lib/ticket-scope.bash "$(pwd)"` を実行する。終了コードが 0 以外なら範囲外なので、このスキルは使わずにユーザーへそう伝える。引数が `audit` なら照合モード、それ以外は作成モード。

## 作成モード

issue や PR を作る前に、本文ファイルを次の手順で作る。

1. **置き場所を決める。** `git rev-parse --absolute-git-dir` を単独で実行し、出力に `/ticket` を足したディレクトリを使う(以降 `<dir>`)。本文は Write ツールで `<dir>/issue-body.md` か `<dir>/pr-body.md` に書く。コマンドには `$(…)` や `$TMPDIR` を含めず、展開済みの絶対パスを書く(ticket-guard は展開前の文字列しか読めない)。
2. **関連 issue を探してメンションする。** タイトルの主要な語を 2〜3 通り変えて `gh issue list --state all --search "<語>" --limit 20 --json number,title,state` を実行する。関連するものを `## 関連` 節に `- #N <なぜ関連するかを 1 行>` で書く。見つからなければ「関連 issue なし(検索語: …)」と書く。
3. **issue なら relationship を書く。** 親は `## Parent`、先に片付ける必要がある issue は `## Blocked by` の節に `#N` で書く。関係として読むのは行頭(`- ` などの箇条書きの記号の後ろと、見出しと同じ行の見出し語の後ろを含む)に置いた `#N` だけで、「なし。#402 がこの issue に依存する。」のような文中の `#N` は関係にならない。関係が無ければ「なし」と書き、補足は `#N` を行頭に置かずに書く。native の設定は手順6の `create-issue.sh` が作成と同時に行う。既存の issue に後から張るコマンドは `references/relationship-api.md` にある。
4. **PR なら Closes と AC 対応表を書く。** 解決する issue ごとに `Closes #N` を 1 行ずつ書く(`Closes #1, #2` は 2 件目が効かない)。部分的にしか解決しない issue は `Refs #N` にする。各 issue の AC(`gh issue view <N> --json body`)について、`## Acceptance criteria の対応` 節に表 `| issue | 項目 | 対応 |` を書く。「対応」には満たした変更(ファイルやテスト)を書き、満たさない項目にはその理由を書く。`Closes` による自動 close は既定ブランチへのマージでしか効かない。
5. **末尾にマーカーを付ける。** 本文の最後の行を `<!-- ticket-skill -->` にする。
6. **作る。** issue は `bash ~/.claude/skills/ticket/scripts/create-issue.sh --title "<title>" --body-file <dir>/issue-body.md`(`--label` などは後ろに足せば `gh issue create` に渡る)。終了コード 1 は「issue は作ったが relationship の一部を張れなかった」なので、stderr に出た関係を `references/relationship-api.md` のコマンドで張り直す。終了コード 2 は何も作っていない。stderr の理由を直して再実行する。PR は `gh pr create --head <branch> --title "<title>" --body-file <dir>/pr-body.md`。範囲内のリポジトリで `gh issue create` を直接使うと ticket-guard が deny する。

## 照合モード

1. `bash ~/.claude/skills/ticket/scripts/audit.sh` を実行する。出力は 1 行 1 件のタブ区切り `<kind> <issue> <根拠>`。終了コード 1 は一部の issue の検査を API の失敗で飛ばしたことを示す(stderr に issue が出る)。出力は全件ではないので、飛ばした issue を報告に含める。
2. kind ごとに `references/audit-fixes.md` の手順で修正案を作る。`mentioned-by-merged` は Closes の書き忘れの候補にすぎず、`ac-unchecked` で `[x]` にしてよいのは根拠の PR の AC 対応表に満たしたと書いてある項目だけ。
3. 修正案を表(kind・issue・操作・根拠)で示し、`AskUserQuestion` で「全部適用 / 種類ごとに選ぶ / やめる」を選んでもらう。承認なしに書き込まない。
4. 適用する。AC を `[x]` にする手順は `references/audit-fixes.md` の「AC を `[x]` にする適用の手順」。
5. もう一度 `audit.sh` を実行し、適用した分が出なくなったことを確かめてから、残った件数と理由を報告する。
