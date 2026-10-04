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
3. **issue なら relationship を書く。** 親は `## Parent`、先に片付ける必要がある issue は `## Blocked by` の節に `#N` で書く。native の設定は手順6の `create-issue.sh` が作成と同時に行う。既存の issue に後から張るとき(照合モードや `create-issue.sh` が一部失敗したとき)は次のコマンドを使う。
   - database id: `gh api repos/<owner>/<repo>/issues/<n> --jq .id`(`#number` や `node_id` ではない)
   - 親子: `gh api repos/<owner>/<repo>/issues/<親>/sub_issues -X POST -F sub_issue_id=<子の database id>`
   - 依存: `gh api repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by -X POST -F issue_id=<blocker の database id>`
   - 確認: `gh api repos/<owner>/<repo>/issues/<n> --jq '{parent: .parent_issue_url, deps: .issue_dependencies_summary}'`
4. **PR なら Closes と AC 対応表を書く。** 解決する issue ごとに `Closes #N` を 1 行ずつ書く(`Closes #1, #2` は 2 件目が効かない)。部分的にしか解決しない issue は `Refs #N` にする。各 issue の AC(`gh issue view <N> --json body`)について、`## Acceptance criteria の対応` 節に表 `| issue | 項目 | 対応 |` を書く。「対応」には満たした変更(ファイルやテスト)を書き、満たさない項目にはその理由を書く。`Closes` による自動 close は既定ブランチへのマージでしか効かない。
5. **末尾にマーカーを付ける。** 本文の最後の行を `<!-- ticket-skill -->` にする。
6. **作る。** issue は `bash ~/.claude/skills/ticket/scripts/create-issue.sh --title "<title>" --body-file <dir>/issue-body.md`(`--label` などは後ろに足せば `gh issue create` に渡る)。終了コード 1 は「issue は作ったが relationship の一部を張れなかった」なので、stderr に出た関係を手順3のコマンドで張り直す。PR は `gh pr create --head <branch> --title "<title>" --body-file <dir>/pr-body.md`。範囲内のリポジトリで `gh issue create` を直接使うと ticket-guard が deny する。

## 照合モード

1. `bash ~/.claude/skills/ticket/scripts/audit.sh` を実行する。出力は 1 行 1 件のタブ区切り `<kind> <issue> <根拠>`。
2. kind ごとに修正案を作る。
   - `parent-missing` / `blocked-by-missing`: 作成モードの手順3のコマンドで native に張る。
   - `open-after-merge`: `gh issue close <issue> --reason completed --comment "PR #<n> のマージで解決済み(Closes による自動 close が効かなかった)"`。
   - `mentioned-by-merged`: Closes を書き忘れた PR の候補にすぎない。PR の本文と差分(`gh pr view <n> --json body,files`)と issue の AC を読み、解決したと言える場合だけ close の候補にする。言えなければ「言及のみ」として報告に載せ、操作は提案しない。
   - `ac-unchecked`: 根拠の PR の本文(`gh pr view <n> --json body`)の AC 対応表で、その項目を満たしたと書いてあるものだけを `[x]` にする候補にする。対応表に無い項目や、理由を書いて意図的に `[ ]` のまま残した項目は触らず、報告に載せる。
3. 修正案を表(kind・issue・操作・根拠)で示し、`AskUserQuestion` で「全部適用 / 種類ごとに選ぶ / やめる」を選んでもらう。承認なしに書き込まない。
4. 適用する。AC は `gh issue view <issue> --json body --jq .body` を `<dir>/issue-<issue>.md` に保存し、該当行の `- [ ]` だけを `- [x]` に直して `gh issue edit <issue> --body-file <dir>/issue-<issue>.md` で戻す。
5. もう一度 `audit.sh` を実行し、適用した分が出なくなったことを確かめてから、残った件数と理由を報告する。
