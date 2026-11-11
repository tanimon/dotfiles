# 現状の Human Touchpoint はどこで何回起きているか(棚卸し)

日付: 2026-11-11
問い: #646(親の地図は #645)
期間: 2026-10-12T00:00Z 〜 2026-11-12T00:00Z(31 日。最後の週 2026-W46 は 11-09〜11-11 の 3 日分しかない)
対象: 個人リポジトリ(`tanimon/*`)のメインのセッション 253 件。仕事のリポジトリと、どのリポジトリか決められないセッションは件数に含めない(「2. 方法」)。

Human Touchpoint は、作業の流れのうち人間の手が入らないと先へ進めない点を指す。#645 の Notes が `GLOSSARY.md` の Autonomy 節を正本に指定している。ただし、このブランチの基点(95cbd23)の `GLOSSARY.md` にはこの節がまだ無い。

本書は件数と、件数から読める所見を記録する。各件数には、それを出したコマンドか集計スクリプトの出力キーを添える。

## 1. 要約

- **人の手は、ほぼすべて dotfiles の対話セッション(153 件)に集中している。** 対象 253 件のうち 100 件は headless(`sdk-cli`)で、人の入力は 0 件だった。内訳は software-factory-engineering の定期実行 30 件、dotfiles の週次ジョブ 8 件、そのほか 62 件。
- **最も多いのは「エージェントからの質問」で、計 326 回あった。** 内訳は `AskUserQuestion` が 230 回(質問 320 問)、テキストで聞かれた質問への回答が 96 回。どちらも、答えの大半は推奨案をそのまま受け入れたものだった。`AskUserQuestion` では回答 314 件のうち 226 件(72%)が推奨の選択肢で、テキストの回答では 96 件のうち 55 件(57%)が「全部推奨案で」や、全問「はい」だけの回答だった。
- **「次の段を人が手で起動する」操作が、起動以外の prompt の半分近くを占める。** 起動の後に人が打った prompt 335 件のうち、157 件がこれに当たる。内訳は、スラッシュコマンドで次の段を起動したものが 90 件(最多は `/superpowers:receiving-code-review` の 38 件)、「PR 作って」「push + /pr-body-review」のような PR の作成・push の指示が 67 件。`AskUserQuestion` の 320 問のうち 90 問も「次に何をしますか」「どこまで進めますか」という進め方の質問だった。
- **Approval Gate での承認は 190 回あったが、すでに減っている。** 最多の原因だった `create-issue.sh` の 53 回は #617(2026-10-31)以降は 0 回になった。2026-11-01 以降に残っているのは 27 回で、そのうち 12 回は git-push-guard の推定。git-push-guard の承認は、heredoc を含むコマンドで多く起きていた(原因の箇所は未確認)。Approval Gate で人が拒否したのは 4 回だけだった。
- **PR のレビューは GitHub 上では行われていない。** 期間内に作られた PR は 88 件で、GitHub のレビュー記録は 0 件だった。マージは 86 件すべてを人のアカウントが行った。エージェントによる `gh pr merge` は 1 回試みられたが、deny ルールで止まった。人とエージェントのセッションで作った PR は、作成からマージまでの中央値が 0.55 時間で、78 件中 54 件が 1 時間以内にマージされた。一方、週次ジョブの Loop PR は 2 件とも 97〜153 時間待っている。

## 2. 方法

### 2.1 データ源

- **transcript:** `~/.claude/projects/*/*.jsonl` のトップレベルのファイル(メインのセッション)。subagent の transcript は数えない。集計には、このファイルと同じディレクトリにある `docs/research/human-touchpoint-inventory.py` を使った。
  ```sh
  python3 -I docs/research/human-touchpoint-inventory.py <scratch>/inventory.json
  ```
  標準出力に件数を JSON で出す。本書で `出力キー` と書いた値はこの JSON のキーを指す。典型例の抜粋は `<scratch>/inventory.json` の `examples` にだけ書く。
- **cclens:** 既定の保存先(`~/.local/state/cclens/`)はサンドボックスから書けないので、`cclens analyze --db <scratch>/cclens.db` で一時的に store を作り、`cclens sql --db <scratch>/cclens.db …` で照合した(cclens 0.4.0)。
- **GitHub:** `gh pr list --repo tanimon/dotfiles …`(「4.5 PR の作成・レビュー・マージ」のコマンド)。`tanimon/software-factory-engineering` には、期間内に作られた PR が無かった。

### 2.2 対象のセッションの決め方

各 transcript で最初に記録された `cwd` から origin を引き、owner が `tanimon` なら対象にした。worktree が消えて origin を引けないディレクトリは、`PERSONAL_PREFIXES`(dotfiles の worktree 群、`~/.local/share/chezmoi`、週次ジョブの作業場所、software-factory-engineering)で始まるものだけを対象にした。それ以外は理由を問わず除外した。仕事のリポジトリも、どのリポジトリか決められないディレクトリもここで落ちる。

- 対象 253 件、除外 506 件(出力キー `scope_sessions`)。除外の件数は、実行した時点のセッション数で変わる。
- 対象の内訳は、対話(`cli`)153 件と headless(`sdk-cli`)100 件(出力キー `counts.session:*`)。リポジトリ別の内訳は出力キー `by_repo` にある。人の入力・質問・承認が記録されていたのは、すべて dotfiles のセッションだった。

### 2.3 Human Touchpoint の判定に使った記録

| 種類 | transcript の記録 |
|---|---|
| Approval Gate の承認 | tool の結果の record の `permissionDecision.source == "user_temporary"`(`AskUserQuestion` と `ExitPlanMode` を除く) |
| Approval Gate の拒否 | `toolDenialKind == "user-rejected"` |
| 自動の拒否(人は関与しない) | `permissionDecision.decision == "reject"` で、source が人以外のもの |
| `AskUserQuestion` | assistant の `tool_use`(name が `AskUserQuestion`)と、その結果の `toolUseResult.answers` |
| 人の prompt | user の record で、`origin.kind == "human"`、`promptSource == "typed"`、`turnOrigin == "human"` のどれかを満たすもの。タスク通知・peer のメッセージ・SDK からの入力は入れない |
| 手での起動 | 対話セッションでの最初の人の prompt。`<command-name>` があればスラッシュコマンドとして名前で数えた |
| 割り込み | 人の record の本文に `[Request interrupted by user` を含むもの |

起動の後の人の prompt は、字面で 9 種類に分けた(スクリプトの `classify_prompt`)。字面だけで決めるので、とくに「訂正」は下限の値になる。

cclens にも prompt の分類(`instruct` / `correct` / `steer` / `question`)がある。しかし dotfiles の期間内で `correct` に入った 33 件のうち 8 件を開いて確かめたところ、8 件ともタスク通知か teammate のメッセージで、人の訂正ではなかった。そのため、この分類は使っていない。

```sh
cclens sql --db <scratch>/cclens.db "SELECT e.source AS class, count(*) AS n FROM events e JOIN sessions s ON s.id = e.session_id WHERE e.kind = 'prompt' AND s.root LIKE '%/chezmoi%' AND e.started_epoch >= strftime('%s','2026-10-12') GROUP BY 1 ORDER BY 2 DESC"
# instruct 523 / correct 33 / steer 25 / question 9(計 590。人の prompt 484 件より多いのは、通知とメッセージを含むため)
```

## 3. 種類別の件数

| 種類 | 件数 | 出どころ(出力キー、またはコマンド) |
|---|---:|---|
| **Approval Gate の承認** | 190(すべて Bash) | `counts.approve` |
| うち 2026-11-01 以降 | 27 | `approve_trigger_since_2026-11-01` の合計 |
| **Approval Gate の拒否**(人) | 4(Bash 3、Read 1) | `counts.user_rejected:Bash`、`user_rejected:Read` |
| (参考)自動の拒否 | 14 | `counts.auto_reject` |
| **エージェントからの質問: `AskUserQuestion`** | 230 回 / 320 問(回答 225 回、拒否 5 回) | `counts.ask_tool_use`、`ask_questions`、`ask_answered`、`user_rejected:AskUserQuestion` |
| うち推奨の選択肢を選んだ回答 | 314 件中 226 件 | `counts.ask_answer:*` |
| **エージェントからの質問: テキストの質問への回答** | 96 | `prompt_kind_after_launch.テキストの質問への回答` |
| うち推奨案か「はい」だけの回答 | 55 | `counts.text_answer_pure_acceptance` |
| **ユーザーの割り込み** | 9(tool の実行中 6、応答中 3) | `counts.interrupt:*` |
| **訂正・追加要望**(字面で拾える下限) | 5 | `prompt_kind_after_launch.訂正・追加要望` |
| **手での起動**(セッションの開始) | 149 | `counts.launch`、`launch_kind` |
| **手での起動**(セッションの途中で次の段を起動) | 90 | `prompt_kind_after_launch.スラッシュコマンドで次の段を起動`、`slash_after_launch` |
| PR の作成・push の指示 | 67 | `prompt_kind_after_launch.PR 作成・push の指示` |
| 続行の合図(「OK」「進めて」など) | 23 | `prompt_kind_after_launch.続行の合図` |
| PR のマージ・apply の報告 | 4 | `prompt_kind_after_launch.PR マージ・apply の報告` |
| そのほか(ユーザーからの質問 6、`!` での手のシェル実行 5、その他の指示 39) | 50 | `prompt_kind_after_launch` |
| **PR のマージ**(期間内) | 86(すべて人のアカウント) | 「4.5 PR の作成・レビュー・マージ」のコマンド |
| **PR のレビュー**(GitHub 上) | 0 | 同上 |

拒否と割り込みは、同じ 1 回の操作で両方の記録が残ることがある。拒否 9 回(Approval Gate の 4 回と `AskUserQuestion` の 5 回)のうち 7 回は、直後に割り込みの記録があった(出力キー `counts.interrupt_right_after_rejection`)。両方を合わせた操作の回数は 11 回になる(拒否 9 回と、拒否を伴わない割り込み 2 回)。

週ごとの件数(出力キー `week`。W46 は 3 日分):

| 週 | 起動(対話セッション) | 人の prompt | `AskUserQuestion` | 承認 |
|---|---:|---:|---:|---:|
| 2026-W42 | 50 | 174 | 95 | 52 |
| 2026-W43 | 27 | 104 | 42 | 26 |
| 2026-W44 | 52 | 150 | 68 | 85 |
| 2026-W45 | 13 | 35 | 17 | 11 |
| 2026-W46 | 7 | 21 | 8 | 16 |

W45 以降はどの種類も少ないが、起動した対話セッションの数も 50 前後から 13 と 7 に減っている。そのため、仕組みが改善した結果とは言えない。ただし Approval Gate については、原因ごとの最終日から、仕組みの変更で止まったことを確認できる(「4.1 Approval Gate」)。

## 4. 種類ごとの内訳と典型例

### 4.1 Approval Gate

承認の原因の内訳(出力キー `approve_trigger`、`approve_trigger_since_2026-11-01`、`approve_trigger_last_date`):

| 原因 | 31 日間 | 11-01 以降 | 最後に起きた日 |
|---|---:|---:|---|
| issue 作成スクリプト `create-issue.sh` | 53 | 0 | 10-31(#617 で確認なしになった) |
| フック: git-push-guard(推定) | 28 | 12 | 11-10 |
| フック: curl-localhost-guard(推定) | 11 | 5 | 11-10 |
| フック: 両方(推定) | 2 | 0 | 10-31 |
| ask ルール: `pnpm install` / `npm install` / `pnpm add`(推定) | 20 | 0 | 10-23 |
| ask ルール: `git rebase` / `git reset`(推定) | 20 | 2 | 11-06 |
| 不明(`reasonCode` が記録されていない古い版) | 13 | 0 | 10-18 |
| ask ルール: `uvx`(推定) | 10 | 0 | 10-31 |
| ask ルール: `gh issue edit` / `close` / `create`、`gh label create`(推定) | 13 | 1 | 11-11 |
| サンドボックス外での実行(`dangerouslyDisableSandbox`) | 7 | 1 | 11-06 |
| ask ルール: `gh run rerun`(推定) | 6 | 4 | 11-10 |
| 組込みの安全確認(`safetyCheck`) | 6 | 2 | 11-10 |
| ask ルール: `mise install`(推定) | 1 | 0 | 10-31 |

推定の根拠は次のとおり。

- **フック:** transcript は、どのフックが ask を返したかを記録しない。そこで、今デプロイされている guard に同じコマンドを渡し直し、ask を返したものを数えた(スクリプトの `replay_guards`)。guard は当時から変わっているので推定になる。git-push-guard に当たった 30 件のうち 28 件は、`python3 - <<'PY' …` のような heredoc を含むコマンドだった(出力キー `counts.push_guard_heredoc`)。今の git-push-guard は、これらを「引数を読み切れない push」と判定する。28 件はどれも本文に `push` を含み、14 件は `git push` という並びをそのまま含んでいた(出力キー `counts.push_guard_heredoc:*`)。heredoc の本文が push のコマンドとして読まれている可能性が高いが、guard のどの判定が働いたかは確かめていない。本文に `push` を含むだけの最小の heredoc(`git` を含まない)を渡したときは、ask を返さなかった。
- **ask ルール:** 今の `dot_claude/settings.json.tmpl` の `permissions.ask` を、過去のコマンドに当てて決めた。

人が承認するまでの時間は、中央値 38.5 秒、上位 10% が 353 秒だった(出力キー `approve_latency`。tool_use の時刻から結果の時刻まで)。Approval Gate で人が拒否したのは Bash 3 回と Read 1 回だった。`AskUserQuestion` の拒否 5 回と合わせた 9 回のうち 7 回は、直後に割り込みの記録があり、`Esc` で止めた形だった。補足を書き込んで拒否したものは 1 回(出力キー `counts.user_rejected_with_feedback`)。

headless の実行では guard の ask が拒否になる(#429)。そのため、対話では 10 日で 27 回程度の小さな手間でも、AFK の実行では 1 回で作業が止まる。

### 4.2 エージェントからの質問

`AskUserQuestion` の 320 問を字面で分けた結果(出力キー `ask_kind`。スクリプトの `classify_ask`):

| 質問の種類 | 問数 | 典型例(要旨) |
|---|---:|---|
| 設計・方針の判断 | 196 | 「issue の指示が古くなっています。どう進めますか?」「ロックをいつ取るか、どうしますか?」 |
| 次の段・どこまで進めるか | 90 | 「次に何をしますか?」「レビュー指摘への修正 4 件を入れ、検査も通しました。この後どこまで進めますか?」「今回の変更をコミットしますか?」 |
| レビュー指摘の取捨 | 23 | 「どの指摘を直しますか?(複数選択可)」 |
| 後始末・削除の可否 | 11 | 「マージ済みブランチの worktree のうち、未コミットのファイルが残っている 2 つをどうしますか?」 |

回答 314 件の内訳は、推奨の選択肢 226 件、推奨以外の選択肢 61 件、自由記述か複数選択 27 件(出力キー `counts.ask_answer:*`)。回答するまでの時間は、中央値 107 秒、上位 10% が 389 秒だった(出力キー `ask_latency`)。

テキストで聞かれた質問への回答は 96 件あった。典型は grilling 系のセッションでの「Q1: はい Q2: a Q3: 推奨案で …」という形で、「全部推奨案で」「すべて推奨案で」だけの回答が 26 件あった(出力キー `counts.text_answer_recommend_all_only`)。96 件のうち 55 件は、推奨案か「はい」だけで情報を足していない回答だった(出力キー `counts.text_answer_pure_acceptance`)。残りの 41 件には、「Q6: brew での管理をやめて global mise に移すのはどう?」のような、人の意図が入っていた。

起動したスキル別に見ると、質問が多かったのは次のセッションだった(出力キー `by_launch`)。

- `/mattpocock-skills:code-review`: 20 セッションで `AskUserQuestion` 44 回
- `/mattpocock-skills:improve-codebase-architecture`: 13 セッションで 40 回
- `/mattpocock-skills:ask-matt`: 24 セッションで 37 回
- `/review-verify`: 11 セッションで 28 回

### 4.3 割り込み・訂正・拒否

割り込みは 9 回、拒否は 9 回あり、重なりを除くと 11 回だった(「3. 種類別の件数」)。訂正として字面で拾えたのは 5 件で、そのうち 3 件は「日本語でお願い」という応答言語の訂正だった。ほかの 2 件は「別件候補も裏どりしてから、間違っていれば修正して」のような追加の要望だった。字面に出ない訂正(例: 「その他の指示」に入った「#568 は別の PR で対応中」)は数えていないので、この件数は下限である。

### 4.4 手での起動

対話セッション 149 件の、最初の prompt の内訳(出力キー `launch_kind`):

- 自由記述: 32 件
- `/mattpocock-skills:ask-matt`: 24 件
- `/mattpocock-skills:code-review`: 20 件
- `/mattpocock-skills:improve-codebase-architecture`: 13 件
- `/review-verify`: 11 件
- `/superpowers:requesting-code-review`: 8 件
- `/mattpocock-skills:implement`: 6 件、`/mattpocock-skills:implement-spec`: 5 件
- その他: 30 件

セッションの途中で人が打ったスラッシュコマンドは 90 回あった(出力キー `slash_after_launch`)。

- `/superpowers:receiving-code-review`: 38 回
- `/mattpocock-skills:implement`: 12 回
- `/mattpocock-skills:grill-with-docs`: 12 回
- `/pr-body-review`: 6 回(このほか、「push + /pr-body-review」のように PR の指示に添えたものが 20 回ある。出力キー `counts.pr_instruction_with_pr_body_review`)
- `/mattpocock-skills:ask-matt`: 6 回
- `/mattpocock-skills:to-tickets`: 5 回、`/mattpocock-skills:retro`: 5 回
- `/mattpocock-skills:to-spec`: 4 回
- その他: 2 回

レビュー(`code-review`)→ 指摘への対応(`receiving-code-review`)→ PR の作成 → 本文の照合(`pr-body-review`)という連鎖を、人が 1 段ずつ起動している。

### 4.5 PR の作成・レビュー・マージ

```sh
gh pr list --repo tanimon/dotfiles --state all --search "created:>=2026-10-12" --limit 300 \
  --json number,createdAt,mergedAt,state,author,headRefName,reviews | jq -c '{created: length, reviews: (map(.reviews|length)|add), by_state: (group_by(.state)|map({(.[0].state): length})|add), human_merged: ([.[] | select(.mergedAt and (.headRefName|startswith("harness/review-")|not) and (.author.login|test("renovate")|not)) | ((.mergedAt|fromdate) - (.createdAt|fromdate))/3600] | sort | {n: length, p50_h: (.[(length/2|floor)]*100|round/100), p90_h: (.[(length*0.9|floor)-1]*100|round/100), le_1h: (map(select(. <= 1))|length), gt_24h: (map(select(. > 24))|length)}), loop_merged_h: [.[] | select(.mergedAt and (.headRefName|startswith("harness/review-"))) | ((.mergedAt|fromdate) - (.createdAt|fromdate))/3600|round]}'
# {"created":88,"reviews":0,"by_state":{"MERGED":80,"OPEN":8},"human_merged":{"n":78,"p50_h":0.55,"p90_h":20.46,"le_1h":54,"gt_24h":8},"loop_merged_h":[153,97]}
gh pr list --repo tanimon/dotfiles --state merged --search "merged:>=2026-10-12" --limit 300 --json mergedBy | jq -c 'group_by(.mergedBy.login)|map({(.[0].mergedBy.login): length})|add'
# {"tanimon":86}
```

- **作成:** 人とエージェントのセッションには、「PR 作って」「PR を作成して」「push + /pr-body-review」という PR の作成・push の指示が 67 回あった。78 件の PR の大半は、人のこの指示で作られたと見られる(PR とセッションの突き合わせはしていない)。週次ジョブは draft の Loop PR を自分で作る。
- **レビュー:** GitHub のレビュー記録は 0 件だった。レビューはセッションの中で、`/mattpocock-skills:code-review` などのスキルと人の回答で行われている(「4.2 エージェントからの質問」と「4.4 手での起動」)。
- **マージ:** 86 件すべてを人のアカウントがマージした。エージェントの `gh pr merge` は 1 回だけで、「CI が pass したらマージして」という依頼に対して実行し、`dot_claude/settings.json.tmpl` の deny ルール `Bash(gh pr merge:*)` で止まった(出力キー `counts.gh_pr_merge_attempt`)。マージした後、人がセッションに「#564 をマージした。続きの作業をお願い」「merge + apply + セッション再起動した。確認お願い」と報告する touchpoint も 4 回あった。
- **待ち時間:** 人とエージェントのセッションの PR 78 件は、作成からマージまでの中央値が 0.55 時間、上位 10% が 20.5 時間だった。24 時間を超えたのは 8 件。Loop PR は 2 件とも長く待ち、97 時間と 153 時間だった(さらに 1 件が draft のまま開いている)。renovate の PR は 6 件が 18〜24 日開いたままになっている(期間内に作られたものだけ。期間前のものも残っている)。

### 4.6 通知(計測していない)

通知のイベント(`Notification` フック、orca への受け渡し)は transcript に残らないため、件数を出していない。代わりの手がかりは 2 つある。

- 人が席を外してから戻ったときに作られる要約(`system` の `away_summary`)が 211 件あった(出力キー `counts.away_summary`)。
- 承認と質問への回答の待ち時間は、上位 10% が 6 分前後だった。

どちらも、人が近くにいる対話セッションだったことを示すだけで、通知がどこで要ったかは分からない。

## 5. 所見: どの枝を先に掘るか

#645 の到達点は、人の手を「意図を出す」と「PR のレビューとマージ」だけに残すこと。この基準で、件数の多い順に並べる。

1. **途中の質問(最優先)。** 計 326 回で最も多く、回答の 69%(410 件中 281 件。`AskUserQuestion` の推奨の選択肢 226 件とテキストの純粋な受け入れ 55 件)は推奨案をそのまま受け入れていた。消す候補は `AskUserQuestion` の「次の段・どこまで進めるか」の 90 問と、code-review / review-verify のセッションの質問(31 セッションで 72 回)。どちらも実装とレビューの経路の中にあり、PR のレビューで覆せる。一方、ask-matt / improve-codebase-architecture / grill-with-docs のセッションの質問は「意図を出す」側の作業なので、意図して残すかどうかを別に決める必要がある。質問の数は、起動したスキルによって大きく違う(「4.2 エージェントからの質問」)。
2. **PR の作成と、次の段への手での連結(2 番目)。** 起動の後の prompt 335 件のうち 157 件は「次の段を起動する」「PR を作る」「push する」だった。途中の質問のうち 90 問も同じ性質を持つ。tracer bullet(`ready-for-agent` の issue 1 件 → 人間がレビューできる PR)の経路では、ここがそのまま詰まる場所になる。#443(PR の作成)と、実装の段(`/mattpocock-skills:implement` の 18 回の起動)をどこへつなぐかに直結する。
3. **通知(3 番目)。** 質問と連結を消して人が離れると、戻る経路が要る。件数は計測できていない(「4.6 通知」)。次に掘るときは、実行 1 回ごとに「人の手が要った点」を記録するところ(#645 の Not yet specified にある「計測」)から始める必要がある。
4. **権限(4 番目。ただし AFK では必須)。** 31 日で 190 回あったが、主な原因はすでに消えた。11-01 以降の 27 回のうち、git-push-guard の 12 回(推定)が最大だった。31 日間では、その多くが heredoc を含む push 以外のコマンドで起きていた。原因の箇所を確かめれば、guard の判定の問題として個別に直せる見込みがある。人の手間としては小さいが、headless では ask が拒否になる(#429)ため、AFK の経路では 0 にする必要がある。
5. **着手。** セッションの開始 149 回は「意図を出す」に当たり、#645 は人に残すと決めている。ただし、起動のうち 39 回は実装の後の段(code-review 20、review-verify 11、requesting-code-review 8)で、これは 2 番目の「連結」の問題に含まれる。
6. **PR のレビューとマージ。** #645 で人に残すと決めている。待ち時間の中央値は 0.55 時間で詰まってはいない。例外は Loop PR(97〜153 時間)と renovate の PR(18 日以上)で、これらは人が見に行く動機が弱い PR が放置されている形である。

## 6. 限界と注意

- 期間は 31 日で、W46 は 3 日分しかない。W45 以降は起動した対話セッション自体が少ない(週 13 件と 7 件)。
- 対象は、最初の `cwd` で決めた個人リポジトリのセッションだけ。途中で別のリポジトリに移った作業は、最初のリポジトリの件数に入る。どのリポジトリか決められないディレクトリのセッションは除外した。
- subagent の transcript は数えていない。subagent の中の承認は、親のセッションの承認として出ないかぎり件数に入らない。
- prompt の分類と `AskUserQuestion` の質問の分類は字面だけで決めている。とくに訂正(5 件)は下限である。
- Approval Gate の原因のうち「推定」と付けたものは、今の設定と今の guard を過去のコマンドに当てて決めた。
- 通知と、人が PR を GitHub の外(手元の差分やセッションの中)で読んだ時間は計測していない。
- cclens の prompt の分類は、タスク通知や teammate のメッセージを人の prompt として数え、日本語の訂正もほぼ拾わない。この用途には使えなかった。
