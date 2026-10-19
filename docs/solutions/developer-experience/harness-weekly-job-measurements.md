---
title: "週次ジョブの前提を実機で確かめた記録"
date: 2026-10-18
category: developer-experience
problem_type: developer_experience
component: tooling
module: dot_claude/scripts/executable_harness-weekly.sh
severity: low
tags: [harness, launchd, nono, claude-p, measurement]
---

# 週次ジョブの前提を実機で確かめた記録

## 背景

週次ジョブ(`dot_claude/scripts/executable_harness-weekly.sh`)の振る舞いの規則は `.claude/rules/harness-weekly.md` にある。この文書は、その規則の前提を実機で確かめた記録で、規則から参照される。記録は測った時点の版(nono・Claude Code・bash)での結果で、版が変われば測り直す。

## 指針

- 規則を変える前に、その規則が依っている記録をここで確かめる。
- 測り直したら、版と日付を付けて該当する節に書き足すか、末尾に `## 追記 (YYYY-MM-DD)` の節を足し、frontmatter の `last_updated` を更新する(`docs/solutions/README.md`)。規則の側には結論と参照だけを置く。

## 例

### 実行中のスクリプトの書き換え(#515)

書き換え方ごとの実測(2026-10-17、`/bin/bash` 3.2.57、nono の外の小さなスクリプト。bash の読み方は nono に依らない): 同じ inode への追記(`>>`)と上書き(`>`)は効く。rename による置き換え(一時ファイル → `mv`)と Claude Code の Edit / Write ツール(inode が変わる)は効かない。包む形とその理由、テストが何を確かめるかは `.claude/rules/harness-weekly.md` の「実行中の run は起動時の内容で動かす」の項にある。そのテストは、包まない形では 3 件とも落ちる。2 行の形(最後の行を `main "$@"` だけにし、`exit` を後ろの別の行に置く)では、最後の行の直前への上書きは書き足した命令が実行されて落ち、本体の途中への上書きは、書き足した命令は実行されないが main が戻った後に bash がずれた位置(コメントの行の途中)から読み、exit 127 で落ちる。2 行の形は、書き足した命令を実行させなくても run を壊しうる。この 3 件は CI(ubuntu、bash 5 系)でも通る。

### Eval Case の評価

**Eval Case の実測(2026-10-05、nono 0.79.0 / Claude Code 2.1.289)。** (1) Contrast Pair: 既定では起きない規約をルールにしたケースを nono の内側で走らせると Δ = +1.0(with 1.0 / without 0.0、各 2 run)、注入を空にすると Δ = 0.0(両側 0.0)。(2) `--allow-tools Bash` を付けた起動は、nono の内側でも外でも、全 run が `turns: 0` で「認証情報のファイルを辿れないので Bash を許可する評価はここでは走れない」の error になり、Bash を許可しない同じ起動のケースも巻き込む(内側は ENOENT、外側は ssh のシェル展開が原因と出た)。nono の外で評価する経路は、nono の内側から書ける plugin のフックを境界の外で無人実行することになるので作っていない。Bash のケースは「評価できなかった」になり、依頼はツール無しで「実行するコマンドを答える」形に寄せる。(3) nono の内側では、plugin eval がケースの祖先を調べて `/Users` を読めず(EPERM)、`~/.claude/harness/evals` の下のケースを読み込まない。評価は `/private/tmp/claude-<uid>/harness-eval/` の写しで走らせる。(4) スクリプト経由の通し実行で、履歴(`context.history_file`)付きのケースが Δ = +1.0、天井のケースが無効と判定された(2 ケース 8 run で $0.37)。

### nono の内側での前提

**nono の内側での前提の実測(nono 0.79.0)。** 一時ラベルで launchd に登録し、plist から `nono run --profile claude-seal --allow-cwd -- /bin/bash <プローブ>` を起動した(`--allow-cwd` を外した最終形は、`~/.claude/harness` を cwd にすると付与されて書き込めること、付与の無い cwd(`~/Library/LaunchAgents`)では cwd が `/` になり書き込みが拒否されることを、非対話の `nono run` で別に確かめた)。`INSIDE_NONO_SANDBOX=1`、cwd は `WorkingDirectory`、launchd から継承した stdout(nono では書き込み DENIED の `~/Library/Logs`)に書ける、`uuidgen` / `mktemp` / `jq` は動く。`ps` は `Operation not permitted`(exit 126)、別の nono インスタンスのプロセスと PID 1 への `kill -0` は `Operation not permitted`、存在しない PID には `No such process`。

### 抽出の工程までの通し実行

**抽出の工程までの通し実行(2026-10-03、nono 0.79.0。選別・push・PR の作成は未計測)。** 本番のラベルを launchd から起動し、claude の起動まで通った。`launchctl print` は `runs = 1`・`last exit code = 0`、ログは `exit=0 pending=16->6`、結果は `is_error: false`・`subtype: success`、heartbeat は end の時刻で書かれた。pending 16 件のうち上限の 10 件を処理し、`total_cost_usd` は $1.20 で、既定の予算 $5 に届かなかった。境界の外の起動との比較(Contrast Pair)は、スクリプトの中で nono を掛けていた構成での次項の測定による。nono の内側から orca の hook スクリプトの読み取りが拒否されたが、hook は読めないときに `{}` を返すだけなので影響は無い。plist の読み取りも拒否されていた(いまは `read_file` で付与済み。`dot_config/nono/CLAUDE.md` の「境界の外で無人実行するもの」)。Bash が 1 回 `permission_denials` に入った(queue に追記するヒアドキュメントの本文を git push guard が `ask` にし、headless では拒否になる。#429)。エージェントの再試行で追記は済んでいた。

### launchd からの起動の Contrast Pair

**実機の Contrast Pair(2026-10-02〜03、nono 0.78.0 / Claude Code 2.1.287。スクリプトの中で nono を掛けていた構成での測定)。** 一時ラベルで launchd に登録し、同じプロンプト(Bash を 1 回呼び、`INSIDE_NONO_SANDBOX` と `HARNESS_DISABLE` を出す)を nono で包んだ起動と包まない起動で実行した。
  - **nono で包まない側**: 成功(`is_error: false`)。`INSIDE_NONO_SANDBOX=unset HARNESS_DISABLE=1`。費用 $0.43。
  - **nono で包んだ側**: 成功(`is_error: false`)。`INSIDE_NONO_SANDBOX=1 HARNESS_DISABLE=1` で、Bash は入れ子のサンドボックスで落ちず(exit 71 なし)、`HARNESS_DISABLE` は nono を越えて子プロセスまで届いた。結果の `session_id` は `--session-id` で渡した値と一致した。費用 $0.38。
  - **認証が切れた run** は `Not logged in` で、結果は `subtype: success` のまま `is_error: true` になる(#418。launchd に固有ではなく、対話の wrapper 経由の `claude` も同じく未ログインになり、ログインし直すと両方とも直る)。終了コードではなく `is_error` を見るのはこのため。認証が切れると週次ジョブは黙らずに失敗し、heartbeat の古さとして briefing に出る。
  - **予算切れの run**: nono の内側で `--max-budget-usd 0.01` にして Bash を 3 回呼ばせると、exit 1・`subtype: error_max_budget_usd`・`is_error: true`・`errors: ["Reached maximum budget ($0.01)"]` で終わった。ただし `total_cost_usd` は $0.35 で、上限はターンの区切りでしか確かめられないため、1 ターン分の費用だけ超えうる。`--max-budget-usd` は厳密な上限ではなく、超えたら次のターンに進まない歯止めとして読むこと。

## 関連

- `.claude/rules/harness-weekly.md`(規則)
- `docs/adr/0012-self-improvement-runs-weekly-headless-inside-nono.md`
