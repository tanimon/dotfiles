#!/usr/bin/env bash
# 自己改善ループの週次ジョブの入口(ADR 0012)。launchd が週 1 回、nono の内側で起動する
# (plist の ProgramArguments が `nono run … -- /bin/bash <このスクリプト>`)。
#
# 工程は 2 つで、それぞれ headless の `claude -p` を 1 回ずつ起動する(ほかに分類器が、分類する失敗が
# あるときだけツール無しで 1 回起動する)。
#   1. 抽出: 失敗の検出器で pending を選別し(harness-select-pending.sh。失敗の無いセッションを外す)、
#      残ったセッションに対して harness-reflect スキルを行う(残りが無ければ省く)
#      その前に、検出した失敗を Failure Pattern に分類し(harness-classify-failures.sh。claude を
#      ツール無しで 1 回起動する)、週の再発率を記録する(harness-failure-rates.sh)
#   2. 選別: queue に項目があれば、chezmoi の source リポジトリの使い捨ての worktree で
#      harness-review スキルを行い、採用した変更を commit させる(queue が空なら省く)
# 採用した commit があれば(または採用が無くても週の再発率の記録がたまっていれば)、push と
# `gh pr create --draft` はこのジョブが固定の引数で行う。手順の正本は公開の lib(lib/harness-publish.bash)で、
# このスクリプトは本文の節を書いてからその入口を呼ぶ。claude にさせないのは、headless では PreToolUse フックの ask が
# 拒否になり、git push guard が変数を含む push に ask を返すため(#429)。
# PR を作った後に、採用ごとの Rule Ledger の記録を作り(harness-rule-ledger.sh)、このジョブの
# commit で同じブランチに足して push し直す(PR 番号は PR を作るまで決まらないため)。
# 抽出と選別の claude は ~/.claude に書けるので、claude の後に使うスクリプトとデータは Integrity Snapshot
# (lib/harness-integrity.bash。ADR 0019)が claude の起動前にハッシュを取り、使う直前に比べる。claude の工程は
# 必ず工程の入口(harness_integrity_run_untrusted。直後にデータを比べる)を通して起動し、claude の後に
# ~/.claude/scripts のスクリプトを呼ぶときは、必ず実行物の入口(harness_integrity_run)を通す。
# 両方の工程が成功するか省かれ、判定の記録に PR にならなかった採用が残っていなければ(finish_run)
# heartbeat(最後に成功した時刻)を書き、briefing と doctor がその古さを表示する。
# 停止(この run の失敗・前の週に成功しなかったこと・ループの PR の放置・PR にならないループの
# ブランチ)は、EXIT trap の report_stops が GitHub Issue で知らせる。
#
# PR のブランチ名は `harness/review-<日付>`。CI はこの prefix で自己改善ループの PR を
# 見分け、Guarded Path(scripts/guarded-paths.txt)に触れた PR を落とす
# (scripts/check-guarded-paths.sh)。手動の /harness-review も同じ prefix の
# `harness/review-<日付>-manual` を使う(harness-review スキルの冒頭の節が指定する)
#
# nono をこのスクリプトの中で掛けないのは、このファイルが nono の内側から書き換えられる
# (~/.claude は claude-seal で read+write)ため。境界の外で無人実行されるのは、
# 内側から書けない nono の実体と plist だけにする
#
# 処理はすべて main の中に置く。bash はスクリプトを実行しながら読むので、包まない形では、同じ inode への
# 書き換え(追記・上書き)の内容が実行中の run の残りの部分で動く(このファイルは抽出と選別の claude が
# 書ける)。main の定義は呼ぶ前に最後まで読まれるので、run は起動時の内容で最後まで動く。main が戻った後に
# このファイルの続きを読まない理由は、ファイル末尾の main の呼び出しのコメント。書き換え方ごとの実測と
# 塞いでいない範囲は .claude/rules/harness-weekly.md
set -euo pipefail

main() {

    HARNESS_DIR="$HOME/.claude/harness"
    REFLECT_BUDGET_USD="${HARNESS_WEEKLY_BUDGET_USD:-5}"
    REVIEW_BUDGET_USD="${HARNESS_WEEKLY_REVIEW_BUDGET_USD:-5}"
    MAX_SESSIONS="${HARNESS_WEEKLY_MAX_SESSIONS:-10}"
    # 選別の工程が worktree を切る元。nono の内側からは作業ツリーに書けず、.git の
    # objects / refs / logs / worktrees にだけ書ける(claude-seal)ので、このリポジトリの
    # checkout そのものには触れず、linked worktree で作業する
    REPO="${HARNESS_WEEKLY_REPO:-$HOME/.local/share/chezmoi}"

    # 誤用を止めるためのもので、境界ではない(変数は誰でも立てられる)。nono の外で
    # 実行すると claude が境界なしで動くので、手動でも launchd 経由で起動させる
    if [[ -z "${INSIDE_NONO_SANDBOX:-}" ]]; then
        printf 'harness-weekly: not inside nono; refusing. Run it via launchd: launchctl kickstart gui/%s/local.dotfiles.harness-weekly\n' "$(id -u)" >&2
        exit 1
    fi

    command -v jq >/dev/null 2>&1 || {
        printf 'harness-weekly: jq not found (brew install jq)\n' >&2
        exit 1
    }

    mkdir -p "$HARNESS_DIR"
    cd "$HARNESS_DIR"

    # 同時実行を防ぐ lock。mkdir の成否で取り合い、持ち主の PID を中に置く。
    # 次のどれかなら持ち主が生きているとみなし、何もせず終わる(失敗ではない):
    #   - PID がまだ書かれていない(mkdir と PID の書き込みの間)
    #   - kill -0 が成功する
    #   - kill -0 が EPERM を返す。nono の内側からは別の nono インスタンスや境界の外の
    #     プロセスへの kill -0 が EPERM になり、生死を確かめられない(実測)。ps も
    #     拒否されるので、PID の再利用かどうかもここでは区別できない
    # どれでもなければ、または lock が LOCK_STALE_MINUTES より古ければ、止まった実行
    # (SIGKILL や電源断で trap が動かなかった)の残骸として取り戻す。古さの上限は、PID が
    # 無関係のプロセスに再利用されて EPERM が返り続けるときに、毎週スキップし続けないため。
    # 起動は週 1 回なので、次の起動では必ず上限を過ぎている。上限を過ぎてもハングした
    # 実行が生きていれば並走しうるが、同じ週のうちには起きないので受容する。
    # この lock は週次ジョブ同士しか防がない。対話セッションの /harness-reflect と同時に
    # 走ると pending と queue の書き換えが競合しうる(.claude/rules/harness-weekly.md)。
    # 取り戻しは rm → mkdir で原子的ではない。2 つの実行が同時に取り戻しに入ると
    # 両方が走りうるが、週 1 回の起動と手動実行が同じ瞬間に重なる場合に限るので受容する
    LOCK="$HARNESS_DIR/weekly.lock"
    LOCK_STALE_MINUTES=1440
    lock_held() {
        local lock_pid kill_error
        [[ -n "$(find "$LOCK" -maxdepth 0 -mmin -"$LOCK_STALE_MINUTES" 2>/dev/null)" ]] || return 1
        lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
        [[ "$lock_pid" =~ ^[0-9]+$ ]] || return 0
        kill_error=$(LC_ALL=C kill -0 "$lock_pid" 2>&1) && return 0
        [[ "$kill_error" == *"Operation not permitted"* ]]
    }
    if ! mkdir "$LOCK" 2>/dev/null; then
        if lock_held; then
            printf 'harness-weekly: already running (lock %s); skipping\n' "$LOCK"
            exit 0
        fi
        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || {
            printf 'harness-weekly: lost the race to reclaim a stale lock; skipping\n' >&2
            exit 1
        }
    fi
    printf '%s\n' "$$" >"$LOCK/pid"

    PENDING="$HARNESS_DIR/pending.jsonl"
    JOB_SESSIONS="$HARNESS_DIR/weekly-sessions.txt"
    # 失敗の検出器で抽出の入力を選ぶスクリプトと、それが書くセッションごとの検出件数の記録
    SELECT_PENDING="$HOME/.claude/scripts/harness-select-pending.sh"
    DETECTIONS="$HARNESS_DIR/detections.jsonl"
    # 失敗を Failure Pattern に分類するスクリプトと、週の再発率を記録して推移の節を作るスクリプト
    CLASSIFY_FAILURES="$HOME/.claude/scripts/harness-classify-failures.sh"
    FAILURE_RATES="$HOME/.claude/scripts/harness-failure-rates.sh"
    # 週の再発率の記録(1 週 1 ファイル)。ローカルに全週を持ち、PR を作る run がリポジトリの
    # HARNESS_PUBLISH_RATES_REPO_DIR(公開の lib の定数)に無い週の分を、公開の lib がこのジョブの commit で足す。
    # 1 つのファイルに追記しないのは、記録を含む PR が 2 本開いたときに同じ行の追記どうしで
    # コンフリクトするため(同じ内容の新規ファイルどうしならぶつからない)
    LOCAL_RATES_DIR="$HARNESS_DIR/failure-pattern-rates"
    # Rule Ledger(採用したルールごとの記録。ADR 0011)。ローカルに 1 採用 1 ファイルで作り、PR を作る run が
    # リポジトリの HARNESS_PUBLISH_LEDGER_REPO_DIR(公開の lib の定数)に無い記録を、公開の lib がこのジョブの commit で
    # 足す。記録の形と書き出しはスクリプトのヘッダ
    VERDICT_CLI="$HOME/.claude/scripts/harness-verdict.sh"
    LOCAL_LEDGER_DIR="$HARNESS_DIR/rule-ledger"

    # ジョブ自身のセッションを処理の対象から外す(ADR 0012 の Consequences)。
    # 2 段構え: HARNESS_DISABLE で SessionEnd hook に積ませず、それでも積まれた
    # (環境変数が nono や hook まで届かなかった)ときのために、起動前に記録した
    # session id を pending から外す。外すのは実行の前と後の両方で、前に外すのは
    # 前回の実行が後片付けの前に止まった場合の積み残しのため。
    # pending は SessionEnd hook が並行に追記するので、前に読んだ写しは書き戻さず、
    # その場で grep -v で絞って mv する(/harness-reflect の Bookkeeping と同じ)。
    # grep と mv の間に追記された行は失われうる(reflect と同じ残余)ので、外す行が
    # 無いとき(HARNESS_DISABLE が効いた通常の run)は書き換えない。
    # grep の終了コード 2 以上は読み取りの失敗なので、途中までの内容で pending を
    # 上書きせずに失敗する。-v で絞るときの終了コード 1 は「残る行が無い」で正常
    strip_job_sessions() {
        [[ -s "$JOB_SESSIONS" && -f "$PENDING" ]] || return 0
        local tmp status=0
        grep -qF -f <(sed 's/.*/"session_id":"&"/' "$JOB_SESSIONS") "$PENDING" || status=$?
        [[ "$status" -ne 1 ]] || return 0
        if [[ "$status" -gt 1 ]]; then
            printf 'harness-weekly: failed to read %s (grep exit %s); left it unchanged\n' "$PENDING" "$status" >&2
            return 1
        fi
        tmp=$(mktemp "$HARNESS_DIR/.pending.XXXXXX")
        grep -vF -f <(sed 's/.*/"session_id":"&"/' "$JOB_SESSIONS") "$PENDING" >"$tmp" || status=$?
        if [[ "$status" -gt 1 ]]; then
            rm -f "$tmp"
            printf 'harness-weekly: failed to filter %s (grep exit %s); left it unchanged\n' "$PENDING" "$status" >&2
            return 1
        fi
        mv "$tmp" "$PENDING"
    }

    # 実行ログで run の区切りと進み具合を読めるように、開始と終了の行を出す。
    # 処理件数は claude の結果(成功時の要約文)に頼らず pending の行数の前後で残す。
    # 予算切れなどで失敗した run の結果には要約文が無いため。終了の行は EXIT trap で
    # 出すので、失敗の run でも残る(SIGKILL では残らない)
    count_pending() {
        if [[ -f "$PENDING" ]]; then
            wc -l <"$PENDING" | tr -d ' '
        else
            printf '0\n'
        fi
    }

    SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    REVIEW_SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    CLASSIFY_SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    # 記録は起動より前に行い、直近の分だけ残す
    printf '%s\n%s\n%s\n' "$SESSION_ID" "$REVIEW_SESSION_ID" "$CLASSIFY_SESSION_ID" >>"$JOB_SESSIONS"
    tail -n 20 "$JOB_SESSIONS" >"$JOB_SESSIONS.tmp" && mv "$JOB_SESSIONS.tmp" "$JOB_SESSIONS"
    strip_job_sessions || {
        rm -rf "$LOCK"
        exit 1
    }
    PENDING_BEFORE=$(count_pending)
    printf 'harness-weekly: start %s session=%s pending=%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SESSION_ID" "$PENDING_BEFORE"

    # 停止を GitHub Issue で知らせる(ADR 0012 の Consequences)。タイトルを重複を避ける鍵にし、同じ
    # タイトルの Issue が開いていればコメントにする(CI の scheduled workflow が使う
    # .github/actions/harness-issue-alert と同じ規則とラベル。ジョブはローカルで走るので gh で同じことをする)。
    # Issue は公開リポジトリに作るので、本文にログの行やエラー文は貼らない(ローカルのパスを含む)。
    # 固定の文言・日時・session id・~ で書いたパスだけにし、詳細はログ(session id で引ける)に任せる
    ALERT_LABEL=harness-analysis
    FAILED_TITLE='harness: 週次ジョブが失敗した'
    # 開いている harness-analysis の Issue のうち、タイトルが一致するものを `<番号>\t<最終更新の epoch>` で
    # 出す(無ければ何も出さない)
    # shellcheck disable=SC2317,SC2329 # EXIT trap からだけ呼ぶ(理由は cleanup のコメント)
    open_issue() { # <タイトル>
        local issues
        issues=$(cd "$REPO" && gh issue list --label "$ALERT_LABEL" --state open --json number,title,updatedAt --limit 100) &&
            jq -r --arg title "$1" '[.[] | select(.title == $title)][0]
            | if . == null then empty
              else "\(.number)\t\(.updatedAt | sub("\\.[0-9]+"; "") | fromdateiso8601)" end' <<<"$issues"
    }

    # shellcheck disable=SC2317,SC2329 # EXIT trap からだけ呼ぶ(理由は cleanup のコメント)
    alert_issue() { # <タイトル> <本文>
        local title=$1 body=$2 issue number
        if ! issue=$(open_issue "$title"); then
            printf 'harness-weekly: WARN could not report "%s" as a GitHub Issue (listing the open issues failed)\n' "$title" >&2
            return 1
        fi
        number=${issue%%$'\t'*}
        if [[ -n "$number" ]]; then
            # 失敗の再発だけでなく、放置された PR やブランチのように同じ状態が続いている場合もあるので「再発」とは書かない
            if (cd "$REPO" && gh issue comment "$number" --body "$(printf 'この run でも検出した。\n\n%s' "$body")") >/dev/null; then
                printf 'harness-weekly: commented on issue #%s (%s)\n' "$number" "$title"
                return 0
            fi
        elif (cd "$REPO" && gh issue create --label "$ALERT_LABEL" --title "$title" --body "$body") >/dev/null; then
            printf 'harness-weekly: opened an issue (%s)\n' "$title"
            return 0
        fi
        printf 'harness-weekly: WARN could not report "%s" as a GitHub Issue\n' "$title" >&2
        return 1
    }

    # Issue の本文に書くパス。$HOME の下なら ~ で書く(ローカルアカウント名を公開リポジトリに出さない)
    # shellcheck disable=SC2317,SC2329 # EXIT trap からだけ呼ぶ(理由は cleanup のコメント)
    home_relative() {
        case $1 in
        "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;;
        *) printf '%s\n' "$1" ;;
        esac
    }

    # 停止を Issue で知らせる。EXIT trap から呼ぶので、trap が入った後のすべての run(成功・失敗・
    # 工程を省いた exit 0)で走る。trap より前の exit(nono の外での起動・jq が無い・lock の取り合い・
    # pending の読み取りの失敗)は知らせない。そのときは次の run が「成功していなかった」を知らせ、
    # briefing が heartbeat の古さを表示する。
    # 健全性の lib を読めずに止まる run も trap の後なので、失敗の Issue は作る。そのためこの関数と
    # それが使う定義(ALERT_LABEL・FAILED_TITLE・open_issue・alert_issue・home_relative)は trap より前に置く
    # (bash は関数を定義の行を実行したときに作るので、後ろに置くと trap から呼べない)。
    # 送れなかったものは WARN を出して 1 を返すだけで、ジョブの終了コードは変えない。
    # 知らせるもの(タイトルが重複を避ける鍵なので、原因ごとに分ける):
    #   - この run の失敗
    #   - 前の成功が 1 周期より古い(起動時に MISSED_DAYS に読んだもの)
    #   - ループの PR が HARNESS_HEALTH_STALE_PR_DAYS 日以上開いたまま(PR ごと)
    #   - PR にならないまま origin/main に無い commit を持つ、7 日以上前の日付のループのブランチ(ブランチごと)。
    #     採用の記録が残る run は finish_run が失敗させるが、陳腐化の修正だけの commit は記録を残さないので、
    #     この判定でしか見つからない。PR があれば(手動の review が残したブランチや squash マージ)知らせない
    # 本文の `…` は Markdown のコードスパンで、~ と $(id -u) は人が貼り付けて実行するコマンドの一部なので展開しない
    # shellcheck disable=SC2016,SC2088,SC2317,SC2329 # SC2317・SC2329 の理由は cleanup のコメント
    report_stops() { # <この run の終了コード>
        local status=$1 failed=0 reported_failure=0 failed_issue="" log remedy prs stale number url days branches branch count pr_count repo cutoff marks
        local verdict_status verdict_note push_command pr_command
        log='~/Library/Logs/harness-weekly.log'
        remedy='launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly'
        if [[ "$status" -ne 0 ]]; then
            if alert_issue "$FAILED_TITLE" "$(printf '週次ジョブ(harness-weekly.sh)が失敗し、heartbeat を書かなかった。\n\n- 日時: %s\n- run: `session=%s`\n- 終了コード: %s\n\n対処:\n\n1. ターミナルで `%s` の `session=%s` の run を読み、失敗を知らせる `harness-weekly:` の行の手順に従う\n2. 直したら、ターミナルから `%s` で再実行する\n3. 成功したらこの Issue を閉じる(閉じるまで、次の失敗はこの Issue へのコメントになる)\n' \
                "$(date '+%Y-%m-%d %H:%M')" "$SESSION_ID" "$status" "$log" "$SESSION_ID" "$remedy")"; then
                reported_failure=1
            else
                failed=1
            fi
        fi
        # lib を読み込む前に終わった run では、ここから後の判定を使えない
        declare -F harness_health_stale_prs harness_health_unpublished_loop_branches >/dev/null || return "$failed"
        # 失敗した run と、失敗した週の後の run は、前の成功も古い。同じ停止を別の Issue にしないのは、
        # 失敗の Issue が前の成功より後の失敗を知らせているときだけにする:
        #   - この run の失敗を知らせた: 一覧を引き直さない(作った直後の Issue は一覧に出ないことがある)
        #   - 開いている失敗の Issue が前の成功より後に更新された(失敗した run がコメントを足している)
        # 前の成功より前から閉じ忘れで開いている失敗の Issue は、その後の停止を知らせていないので抑止しない
        if [[ -z "${MISSED_DAYS:-}" ]]; then
            :
        elif [[ "$reported_failure" == 1 ]]; then
            printf 'harness-weekly: last success was %s days ago; the failure issue of this run reports it\n' "$MISSED_DAYS"
        elif ! failed_issue=$(open_issue "$FAILED_TITLE"); then
            printf 'harness-weekly: WARN could not check for an open "%s" issue\n' "$FAILED_TITLE" >&2
            failed=1
        elif [[ -n "$failed_issue" && "${failed_issue#*$'\t'}" -gt "${LAST_SUCCESS:-0}" ]]; then
            printf 'harness-weekly: last success was %s days ago; issue #%s already reports the failures\n' "$MISSED_DAYS" "${failed_issue%%$'\t'*}"
        else
            alert_issue "harness: 週次ジョブが ${HARNESS_HEALTH_WEEKLY_STALE_DAYS} 日以上成功していなかった" "$(printf '週次ジョブの前の成功が %s 日前だった。その間の週は、ジョブが起動しなかったか失敗した。この run(`session=%s`)の起動時に見つけた。\n\n対処:\n\n1. 失敗の Issue(`harness: 週次ジョブが失敗した`)が開いていれば、先にそちらを読む\n2. 無ければ launchd が起動していない。ターミナルで `launchctl print gui/$(id -u)/local.dotfiles.harness-weekly` の `runs` と `last exit code` を見る。ラベルが無ければ `chezmoi apply` で登録し直す\n3. `%s` に start の行が無い週は、その時刻に Mac が止まっていたか、nono の起動に失敗している\n4. 原因が分かったらこの Issue を閉じる\n' \
                "$MISSED_DAYS" "$SESSION_ID" "$log")" || failed=1
        fi

        if prs=$(cd "$REPO" && gh pr list --state open --limit 100 --json number,url,headRefName,createdAt) &&
            stale=$(harness_health_stale_prs "$(date +%s)" "$LOOP_BRANCH_PREFIX" <<<"$prs"); then
            while IFS=$'\t' read -r number url days; do
                [[ -n "$number" ]] || continue
                alert_issue "harness: ループの PR #${number} が ${HARNESS_HEALTH_STALE_PR_DAYS} 日以上放置されている" "$(printf 'ループの PR %s が作られてから %s 日、マージもクローズもされていない。承認が止まっている間、ループの変更は効かない。\n\n対処(どちらか):\n\n- 採用する: レビューし、draft なら `gh pr ready %s` で draft を外してから、マージする\n- 採用しない: `gh pr close %s` で閉じる\n\nPR が開いていなくなったら、この Issue を閉じる(開いている間は毎週コメントが付く)。\n' \
                    "$url" "$days" "$number" "$number")" || failed=1
            done <<<"$stale"
        else
            printf 'harness-weekly: WARN could not list the open PRs to find loop PRs left for %s days\n' "$HARNESS_HEALTH_STALE_PR_DAYS" >&2
            failed=1
        fi

        # 前の週から残ったブランチだけを見る(その日の run と、手動の review がまだ公開していないものを除く)。
        # 基準日は今日の 7 日前で固定なので、前の週の run がスリープ明けなどで遅れて走ったブランチは、
        # 今週は外れて次の週に知らせる(1 週遅れる)。基準日を近づけると作業中の手動の review を知らせてしまう
        if cutoff=$(jq -rn --argjson epoch "$(($(date +%s) - 7 * 86400))" '$epoch | localtime | strftime("%Y-%m-%d")') &&
            branches=$(harness_health_unpublished_loop_branches "$REPO" "$LOOP_BRANCH_PREFIX" "$cutoff"); then
            repo=$(home_relative "$REPO")
            while IFS=$'\t' read -r branch count; do
                [[ -n "$branch" ]] || continue
                # PR になっていない採用が残るブランチは finish_run がジョブを失敗させ、失敗の Issue が知らせる。
                # Verdict の CLI は Integrity Snapshot の入口を通してだけ呼ぶ。入口を使えない(lib を読み込む前か
                # スナップショットの前に止まった)run と、照合に落ちた run では CLI を呼ばず、採用の有無を確かめずに
                # ブランチの Issue を作って、そのことを本文に書く(通知は止めない)
                verdict_note=""
                if ! declare -F harness_integrity_run harness_integrity_ready >/dev/null || ! harness_integrity_ready; then
                    verdict_note='Verdict CLI を確かめられなかった(この run は改ざんの検出の準備の前に止まった)ため、このブランチに PR になっていない採用が残っているかは確かめていない。'
                else
                    verdict_status=0
                    marks=$(harness_integrity_run "$VERDICT_CLI" unpublished --branch "$branch") || verdict_status=$?
                    if [[ "$verdict_status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
                        verdict_note='Verdict CLI を信頼できなかった(claude の起動後に週次ジョブが使うスクリプトが書き換えられていた。ログの `harness-integrity:` の行を参照)ため、このブランチに PR になっていない採用が残っているかは確かめていない。'
                    elif [[ "$verdict_status" -ne 0 ]]; then
                        printf 'harness-weekly: WARN could not read the unpublished verdicts of %s from %s\n' "$branch" "$ARCHIVE" >&2
                        failed=1
                        continue
                    elif [[ -n "$marks" ]]; then
                        printf 'harness-weekly: %s has an adopted verdict in %s; the failure issue reports it\n' "$branch" "$ARCHIVE"
                        continue
                    fi
                fi
                [[ -z "$verdict_note" ]] || verdict_note+=$'\n\n'
                pr_count=$(cd "$REPO" && gh pr list --head "$branch" --state all --json number --jq length) || {
                    printf 'harness-weekly: WARN could not check whether %s has a PR\n' "$branch" >&2
                    failed=1
                    continue
                }
                if [[ "$pr_count" != 0 ]]; then
                    # PR になったブランチ(squash マージを含む)は残っている限り毎週照会されるので、消し方を残す
                    printf 'harness-weekly: %s already has a PR; delete it with git -C %s branch -D %s to stop checking it\n' "$branch" "$REPO" "$branch"
                    continue
                fi
                # 綴りの正本は公開の lib。lib を読み込む前に止まった run だけがこの写しを使うので、綴りを変えるときは両方を直す
                # (食い違いは test/harness-weekly.bats の「公開の lib を読み込む前に止まった run のブランチの Issue も…」が見つける)
                if declare -F harness_publish_push_command harness_publish_pr_command >/dev/null; then
                    push_command=$(harness_publish_push_command "$branch" "$repo")
                    pr_command=$(harness_publish_pr_command "$branch")
                else
                    push_command="git -C $repo push origin $branch"
                    pr_command="gh pr create --draft --base main --head $branch"
                fi
                alert_issue "harness: ループのブランチ ${branch} が PR になっていない" "$(printf 'ループのブランチ `%s` が、PR にならないまま `%s` に残っている(origin/main に無い commit: %s 件)。週次ジョブはこのブランチを公開しない。\n\n%s対処(どちらか):\n\n- 公開する: `%s` の後に、`%s` で `%s`\n- 要らなければ消す: `git -C %s branch -D %s`\n\nどちらかをしたら、この Issue を閉じる。\n' \
                    "$branch" "$repo" "$count" "$verdict_note" "$push_command" "$repo" "$pr_command" "$repo" "$branch")" || failed=1
            done <<<"$branches"
        else
            printf 'harness-weekly: WARN could not list the loop branches in %s (is origin/main fetched?)\n' "$REPO" >&2
            failed=1
        fi
        return "$failed"
    }

    # cleanup は trap が名前で呼び、report_stops とそれが使う関数は cleanup を経由してだけ呼ばれる。
    # main の中の trap からの呼び出しを shellcheck は追わず、これらを呼ばれない関数として指摘する。新しい版は
    # SC2329、CI の ubuntu に入っている古い版は同じ指摘を SC2317 で出すので両方を抑制する
    # shellcheck disable=SC2317,SC2329
    cleanup() {
        local status=$?
        strip_job_sessions || true
        # report_stops の gh はネットワークを待ち、タイムアウトを持たない(macOS に timeout が無い)。固まっても
        # lock を握ったままにしないよう、lock は先に解放する。固まったプロセスが残る間は launchd が次の週を
        # 起動しないことは防げない(end の行が出ないことで分かる)
        rm -rf "$LOCK"
        report_stops "$status" ||
            printf 'harness-weekly: WARN could not report every stop as a GitHub Issue (see the lines above)\n' >&2
        printf 'harness-weekly: end %s session=%s exit=%s pending=%s->%s\n' \
            "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SESSION_ID" "$status" "$PENDING_BEFORE" "$(count_pending)"
    }
    trap cleanup EXIT
    export HARNESS_DISABLE=1

    QUEUE="$HARNESS_DIR/queue.md"
    ARCHIVE="$HARNESS_DIR/queue-archive.md"
    WORKTREE="$HARNESS_DIR/review-worktree"
    REVIEW_DATE=$(date +%Y-%m-%d)
    # 日付を入れるのは、失敗した run の本文と結果ファイルを次の週の run が消さないため。
    # 成功した run は消す
    PR_BODY="$HARNESS_DIR/review-pr-body-$REVIEW_DATE.md"
    # 選別に毎回書かせる結果ファイル。形・読み方・Deploy-only Fix の記録の正本は Review Outcome の lib
    REVIEW_RESULT="$HARNESS_DIR/review-result-$REVIEW_DATE.json"
    # 採用したルールの Eval Case の依頼。選別に書かせ、harness-eval-cases.sh が評価して結果を書く(ADR 0011)
    EVAL_CASES="$HOME/.claude/scripts/harness-eval-cases.sh"
    EVAL_REQUESTS="$HARNESS_DIR/eval-requests-$REVIEW_DATE.json"
    EVAL_RESULTS="$HARNESS_DIR/eval-results-$REVIEW_DATE.json"
    EVAL_BUDGET_USD="${HARNESS_WEEKLY_EVAL_BUDGET_USD:-5}"
    # ループのブランチの prefix。正本は scripts/check-guarded-paths.sh(CI はこの prefix でループの PR を見分ける)
    LOOP_BRANCH_PREFIX="harness/review-"
    BRANCH="${LOOP_BRANCH_PREFIX}${REVIEW_DATE}"
    # 選別の採用の印。選別の claude に環境変数 HARNESS_REVIEW_RUN で渡し、Verdict の CLI の settle が採用に付ける
    # (ADR 0017。prompt には書かない)。印の書式は CLI だけが持ち、このスクリプトは印の値で CLI を呼ぶ。
    # run ごとの印(選別の session id)を入れるのは、同じ日の前の run が失敗して残した採用を、今回の PR の URL で
    # 上書きしないため(公開の lib の harness_publish_review)。前の run の記録は残り、finish_run が知らせる
    REVIEW_RUN="$BRANCH run $REVIEW_SESSION_ID"

    # 停止の判定(前の成功の古さ・PR の放置・PR にならないループのブランチ)と heartbeat の読み書きは健全性の lib にある。
    # 読めなければ失敗する。失敗の Issue は EXIT trap が lib に依らずに作る(report_stops)。
    # 素の source は、無い・構文エラー・空の lib で黙って落ちるので、briefing と同じ順に確かめる
    HEALTH_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/harness-health.bash"
    if [[ ! -r "$HEALTH_LIB" ]] || ! "$BASH" -n "$HEALTH_LIB" 2>/dev/null; then
        printf 'harness-weekly: %s is missing or broken; run chezmoi apply\n' "$HEALTH_LIB" >&2
        exit 1
    fi
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=lib/harness-health.bash
    source "$HEALTH_LIB"
    declare -F harness_health_heartbeat_file harness_health_heartbeat_epoch harness_health_write_heartbeat harness_health_missed_run_days harness_health_stale_prs harness_health_unpublished_loop_branches >/dev/null || {
        printf 'harness-weekly: %s lacks the heartbeat and stop checks; run chezmoi apply\n' "$HEALTH_LIB" >&2
        exit 1
    }
    # Integrity Snapshot の lib(ADR 0019)。claude の後に使うスクリプトとデータの一覧と照合は lib だけが持つ。
    # 健全性の lib と同じく、claude の起動前に読んでメモリに載せる(claude が後で書き換えても効かない)
    INTEGRITY_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/harness-integrity.bash"
    if [[ ! -r "$INTEGRITY_LIB" ]] || ! "$BASH" -n "$INTEGRITY_LIB" 2>/dev/null; then
        printf 'harness-weekly: %s is missing or broken; run chezmoi apply\n' "$INTEGRITY_LIB" >&2
        exit 1
    fi
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=lib/harness-integrity.bash
    source "$INTEGRITY_LIB"
    if ! declare -F harness_integrity_snapshot harness_integrity_ready harness_integrity_run harness_integrity_run_untrusted harness_integrity_gate harness_integrity_check_data harness_integrity_seal harness_integrity_sealed >/dev/null ||
        [[ -z "${HARNESS_INTEGRITY_FAILED:-}" ]]; then
        printf 'harness-weekly: %s lacks the integrity checks; run chezmoi apply\n' "$INTEGRITY_LIB" >&2
        exit 1
    fi
    # 公開の module。公開の定数・手で公開するコマンドの綴り・Metrics-only PR の要否の判定・公開の手順(選別の結果と
    # Metrics-only PR)の正本。ほかの lib と同じく、claude の起動前に読んでメモリに載せる。Integrity Snapshot の lib の後に
    # 読むので、この lib を読めずに止まった run の report_stops は綴りの関数を持たない(report_stops がその場合の綴りを持つ)
    PUBLISH_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/harness-publish.bash"
    if [[ ! -r "$PUBLISH_LIB" ]] || ! "$BASH" -n "$PUBLISH_LIB" 2>/dev/null; then
        printf 'harness-weekly: %s is missing or broken; run chezmoi apply\n' "$PUBLISH_LIB" >&2
        exit 1
    fi
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=lib/harness-publish.bash
    source "$PUBLISH_LIB"
    if ! declare -F harness_publish_init harness_publish_push_command harness_publish_pr_command harness_publish_record_command \
        harness_publish_metrics_only_maybe_due harness_publish_metrics_only_due harness_publish_review harness_publish_metrics_only \
        harness_publish_discard >/dev/null ||
        [[ -z "${HARNESS_PUBLISH_RATES_REPO_DIR:-}" || -z "${HARNESS_PUBLISH_LEDGER_REPO_DIR:-}" ||
            -z "${HARNESS_PUBLISH_METRICS_ONLY_WEEKS:-}" || -z "${HARNESS_PUBLISH_AGENT_GIT_CONFIG:-}" ]]; then
        printf 'harness-weekly: %s lacks the publish steps; run chezmoi apply\n' "$PUBLISH_LIB" >&2
        exit 1
    fi
    harness_publish_init --repo "$REPO" --worktree "$WORKTREE" --branch "$BRANCH" --loop-branch-prefix "$LOOP_BRANCH_PREFIX" \
        --pr-body "$PR_BODY" --review-result "$REVIEW_RESULT" --eval-results "$EVAL_RESULTS" --date "$REVIEW_DATE" \
        --run "$REVIEW_RUN" || exit 1
    # Review Outcome の module。選別の結果ファイルの契約・Deploy-only Fix の記録・選別が残したものの分類の正本。
    # 公開の lib の置き場の定数を使うので、その後に読む
    REVIEW_OUTCOME_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/harness-review-outcome.bash"
    if [[ ! -r "$REVIEW_OUTCOME_LIB" ]] || ! "$BASH" -n "$REVIEW_OUTCOME_LIB" 2>/dev/null; then
        printf 'harness-weekly: %s is missing or broken; run chezmoi apply\n' "$REVIEW_OUTCOME_LIB" >&2
        exit 1
    fi
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=lib/harness-review-outcome.bash
    source "$REVIEW_OUTCOME_LIB"
    declare -F harness_review_outcome_init harness_review_outcome_result_instructions harness_review_outcome_classify \
        harness_review_outcome_sections >/dev/null || {
        printf 'harness-weekly: %s lacks the review outcome checks; run chezmoi apply\n' "$REVIEW_OUTCOME_LIB" >&2
        exit 1
    }
    harness_review_outcome_init --worktree "$WORKTREE" --review-result "$REVIEW_RESULT" --pr-body "$PR_BODY" \
        --run "$REVIEW_RUN" --date "$REVIEW_DATE" || exit 1
    # heartbeat はこの run が成功すると書き換わるので、起動時に読む
    MISSED_DAYS=$(harness_health_missed_run_days)
    # 前の成功の時刻。失敗の Issue がそれより後に更新されていれば、走らなかった週はその Issue が知らせている
    LAST_SUCCESS=$(harness_health_heartbeat_epoch) || LAST_SUCCESS=""
    # PR の本文の検出件数の期間の始まり(detection_section)。前の成功が無ければ直近 7 日にする
    DETECTION_SINCE=${LAST_SUCCESS:-$(($(date +%s) - 7 * 24 * 60 * 60))}

    # headless の claude を 1 回起動し、結果をログに残してから成否を返す。
    # 非 0 で終わっても結果(費用・エラーの種類)を先に出す。予算の上限などで止まった run も
    # exit 0 で終わりうるので、終了コードだけでなく結果の is_error も見る。読めない結果は
    # 失敗に倒す(heartbeat が嘘をつかないように)。
    # permission_denials は headless で拒否されたツール呼び出し。PreToolUse フックの ask も
    # ここに入る(確認する人がいないため)。エージェントが別の形で再試行して進むこともあるので
    # 失敗にはしないが、黙って成功扱いにしないよう警告を出す
    # shellcheck disable=SC2317,SC2329 # 抽出では工程の入口に関数名で渡し、選別では review_in_worktree から呼ぶ
    run_claude() {
        local stage=$1 session_id=$2 budget=$3 prompt=$4 status=0 result denials
        result=$(claude -p "$prompt" \
            --settings '{"sandbox":{"enabled":false}}' \
            --dangerously-skip-permissions \
            --max-budget-usd "$budget" \
            --session-id "$session_id" \
            --output-format json) || status=$?
        printf '%s\n' "$result"
        denials=$(printf '%s' "$result" | jq -r '(.permission_denials // []) | length' 2>/dev/null || true)
        if [[ "$denials" =~ ^[0-9]+$ && "$denials" -gt 0 ]]; then
            printf 'harness-weekly: WARN %s: %s permission denial(s) (in a headless run a hook that asks is a denial)\n' \
                "$stage" "$denials" >&2
        fi
        if [[ "$status" -ne 0 ]] || ! printf '%s' "$result" | jq -e '.is_error == false' >/dev/null 2>&1; then
            printf 'harness-weekly: %s: claude failed (exit %s) or reported an error; heartbeat not updated\n' \
                "$stage" "$status" >&2
            return 1
        fi
    }

    # headless ではフックの ask が拒否になる。git push guard / curl localhost guard は
    # ヒアドキュメントの本文を読み切れないと ask を返すので、エージェントが書く本文はシェルで
    # 書かせない(#429)。コマンドの出力を一時ファイルに書いて mv する形は禁じない。
    # harness-reflect / review の Bookkeeping が pending.jsonl と state.json をその形で更新させており
    # (pending は SessionEnd hook が並行に追記するので、Read した写しを Write で書き戻すと
    # 追記を失う)、push や curl を含まないコマンドにフックは ask を返さないため
    WRITE_RULE="- Write text you compose (queue entries, rule and doc text, the PR body, the result file) only with the Write and Edit tools, never with heredocs, echo or printf: in this headless run a hook that asks for confirmation denies the command. Redirecting a command's output to a temp file and moving it into place (the skills' Bookkeeping for pending.jsonl and state.json) is fine; never rewrite those files from a copy you read earlier."

    count_queue() {
        if [[ -f "$QUEUE" ]]; then
            grep -c '^## ' "$QUEUE" || true
        else
            printf '0\n'
        fi
    }

    # 前回の実行が止まって残した worktree(ディレクトリと .git/worktrees の登録のどちらか、
    # または両方)を片付けてから作り直す。ブランチは origin/main の最新から切る。
    # 登録だけが残った自分のパスは add / move の -f で上書きし、git worktree prune は使わない。
    # prune はリポジトリのすべての linked worktree を見るが、nono の内側からは付与の外にある
    # 他の worktree(~/orca/workspaces/… など)の .git を stat できず、git はそれを「存在しない」と
    # 読んで作業中の worktree の登録を消す(nono 0.79.0 で prune --dry-run を実測)。
    # 残存: fetch や claude の commit が起動する gc --auto も prune --expire を走らせるので、
    # 登録から gc.worktreePruneExpire(既定 3 か月)より古い worktree は消えうる
    # fetch を linked worktree の中で行うのは、FETCH_HEAD が worktree ごとの git dir に
    # 書かれるため(元の checkout の .git 直下は nono の内側から書けない)。
    # --no-track は追跡の設定を .git/config に書かせないため(nono の内側から書けない)。
    # 同じ日のブランチが残っていれば -C で作り直すが、origin/main に無い commit を持つなら
    # 作り直さずに失敗する。push か PR の作成に失敗した run の commit は、そのブランチから
    # 手で push / PR を作るよう案内しているので、同じ日の再実行で消してはいけない。
    # その判定は fetch の要る新しい worktree($WORKTREE.new)で行い、通ってから前回の
    # worktree を消して置き換える。判定の前に消すと、失敗した run を調べるための状態を失う
    prepare_worktree() {
        local ahead fresh="$WORKTREE.new"
        git -C "$REPO" worktree remove --force "$fresh" >/dev/null 2>&1 || true
        rm -rf "$fresh"
        git -C "$REPO" worktree add --quiet --force --detach "$fresh" HEAD || return 1
        git -C "$fresh" fetch --quiet origin main || return 1
        if git -C "$fresh" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
            ahead=$(git -C "$fresh" rev-list --count "FETCH_HEAD..refs/heads/$BRANCH") || return 1
            if [[ "$ahead" -gt 0 ]]; then
                git -C "$REPO" worktree remove --force "$fresh" >/dev/null 2>&1 || rm -rf "$fresh"
                printf 'harness-weekly: local branch %s in %s has %s commit(s) not on origin/main; push / open the PR by hand (PR body %s, if present) or delete the branch, then rerun\n' \
                    "$BRANCH" "$REPO" "$ahead" "$PR_BODY" >&2
                return 1
            fi
        fi
        git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
        rm -rf "$WORKTREE"
        git -C "$REPO" worktree move --force "$fresh" "$WORKTREE" || return 1
        git -C "$WORKTREE" switch --quiet --no-track -C "$BRANCH" FETCH_HEAD || {
            printf 'harness-weekly: could not reset branch %s (is it checked out in another worktree of %s?)\n' \
                "$BRANCH" "$REPO" >&2
            return 1
        }
    }

    # PR の本文に付ける純増の節。claude の申告ではなく diff から数える。
    # 採用した変更ごとの純増は、選別に「採用 1 件(陳腐化の修正 1 件)= 1 commit、件名に queue の
    # タイトル」と commit させたうえで commit ごとに数える。続けてファイルごとの表と合計を出す。
    # commit ごとの集計に plumbing(rev-list / diff-tree)を使うのは、launchd 経由では
    # ~/.gitconfig が効き、porcelain の出力に署名の検証結果などが混ざりうるため。
    # numstat はバイナリファイルの行数を `-` で出すので、表には「バイナリ」と書いて合計から外す。
    # パスと件名の `|` は表の区切りにならないよう `\|` にする(gsub の置換文字列の `\` の扱いは
    # awk の実装で違うので、index と substr で置き換える)
    NUMSTAT_AWK_ESCAPE='
    function escape_pipes(text,    out, i) {
        out = ""
        while ((i = index(text, "|")) > 0) {
            out = out substr(text, 1, i - 1) "\\|"
            text = substr(text, i + 1)
        }
        return out text
    }'
    net_change_section() {
        local base=$1 commits commit subject numstat
        commits=$(git -C "$WORKTREE" rev-list --reverse "$base..HEAD") || return 1
        printf '\n## 純増\n\n### 変更ごと(commit ごと)\n\n| 変更 | 追加 | 削除 |\n|---|---:|---:|\n'
        for commit in $commits; do
            subject=$(git -C "$WORKTREE" -c log.showSignature=false log -1 --format=%s "$commit") || return 1
            numstat=$(git -C "$WORKTREE" diff-tree --no-commit-id -r --numstat "$commit") || return 1
            # 件名は -v ではなく環境変数で渡す(-v は値の backslash をエスケープとして解釈する)
            printf '%s\n' "$numstat" | COMMIT_SUBJECT="$subject" awk -F'\t' "$NUMSTAT_AWK_ESCAPE"'
            NF >= 3 {
                if ($1 == "-" || $2 == "-") { binaries++; next }
                added += $1
                deleted += $2
            }
            END {
                note = (binaries > 0 ? sprintf("(バイナリ %d 件を除く)", binaries) : "")
                printf "| %s%s | +%d | -%d |\n", escape_pipes(ENVIRON["COMMIT_SUBJECT"]), note, added, deleted
            }' || return 1
        done
        git -C "$WORKTREE" diff --no-ext-diff --numstat "$base" HEAD | awk -F'\t' "$NUMSTAT_AWK_ESCAPE"'
        BEGIN { print ""; print "### ファイルごと"; print ""; print "| ファイル | 追加 | 削除 |"; print "|---|---:|---:|" }
        {
            path = escape_pipes($3)
            if ($1 == "-" || $2 == "-") {
                printf "| `%s` | バイナリ | バイナリ |\n", path
                binaries++
                next
            }
            printf "| `%s` | +%s | -%s |\n", path, $1, $2
            added += $1
            deleted += $2
        }
        END {
            net = added - deleted
            printf "\n合計: +%d / -%d(純増 %s%d 行)\n", added, deleted, (net > 0 ? "+" : ""), net
            if (binaries > 0) printf "\nバイナリファイル %d 件は行数に含めない。\n", binaries
        }'
    }

    # PR の本文に付ける、失敗の検出件数の節。期間は前回の成功した run(heartbeat)より後で、
    # $DETECTIONS の epoch で切る。記録した実行(週次ジョブか手動の /harness-reflect か)は問わない。
    # 手動の reflect が週の途中で先に選別したセッションも、その週の件数に入れるため。選別は
    # 増えた分だけを記録する(harness-select-pending.sh のヘッダ)ので、期間で足せば重ねて数えない。
    # 失敗した run の後は heartbeat が進まないので、次の run の期間はその分も含む。抽出を省いた週
    # (pending が空)も表を出す。採用 0 件で PR を作らない週の件数は $DETECTIONS にだけ残る。
    # JSON として読めない行は飛ばす
    DETECTION_SIGNALS="user_negation user_interrupt user_rejection hook_deny ci_failure tool_error repeat"
    detection_section() {
        local rows="[]" signal count sessions failing total since_label
        if [[ -f "$DETECTIONS" ]]; then
            rows=$(jq -R -s -c --argjson since "$DETECTION_SINCE" \
                '[split("\n")[] | (try fromjson catch null)
              | select(type == "object" and ((.epoch // 0) | type) == "number" and (.epoch // 0) > $since)]' \
                "$DETECTIONS") || return 1
        fi
        sessions=$(jq '[.[].session_id] | unique | length' <<<"$rows") || return 1
        failing=$(jq 'map(select(.counts != {}) | .session_id) | unique | length' <<<"$rows") || return 1
        total=$(jq 'map(.counts | add // 0) | add // 0' <<<"$rows") || return 1
        since_label=$(date -r "$DETECTION_SINCE" '+%Y-%m-%d %H:%M' 2>/dev/null ||
            date -d "@$DETECTION_SINCE" '+%Y-%m-%d %H:%M') || return 1
        printf '\n## 失敗の検出\n\n%s 以降に検出器にかけたセッション: %s 件(失敗あり %s 件)。\n\n| 信号 | 件数 |\n|---|---:|\n' \
            "$since_label" "$sessions" "$failing"
        for signal in $DETECTION_SIGNALS; do
            count=$(jq --arg signal "$signal" 'map(.counts[$signal] // 0) | add // 0' <<<"$rows") || return 1
            # shellcheck disable=SC2016 # バッククォートは Markdown のコードスパン
            printf '| `%s` | %s |\n' "$signal" "$count"
        done
        printf '| 合計 | %s |\n' "$total"
    }

    # 検出件数の節を、組み立てに成功したときだけ本文に足す。指標の節の失敗で PR の公開を止めない
    append_detection_section() {
        local section
        if section=$(detection_section); then
            printf '%s\n' "$section" >>"$PR_BODY"
        else
            printf 'harness-weekly: WARN failed to build the detection counts from %s; left them out of %s\n' \
                "$DETECTIONS" "$PR_BODY" >&2
        fi
    }

    # 検出した失敗を Failure Pattern に分類し、この run の週の再発率を記録する。期間は分類に成功した
    # 前の週の記録の終わりから(harness-failure-rates.sh の since)。分類に失敗した週も、失敗したことを記録し
    # (推移では「記録なし」になる)、その週の失敗は次の run の期間に含めて分類し直すので、分類の失敗は
    # WARN だけにする。期間を決められない・記録を
    # 書けない週は記録そのものが欠け、推移に「記録なし」とも出ないので、RATE_RECORD_ERROR に残して
    # finish_run で run を失敗させる(週の処理は止めない)。since は前の週の記録が読めないと毎週失敗するので、
    # WARN だけだと以降の週の記録が黙って作られなくなる。Metrics-only PR の push や作成の失敗は、
    # 採用のある PR と同じく run の失敗にする(公開の lib の harness_publish_metrics_only)
    RATE_RECORD_ERROR=""
    record_failure_rates() {
        local since classification=ok
        if ! since=$(bash "$FAILURE_RATES" since "$REVIEW_DATE"); then
            RATE_RECORD_ERROR="could not decide the period with $FAILURE_RATES (is a record in $LOCAL_RATES_DIR unreadable?); failure rates not recorded"
            printf 'harness-weekly: %s\n' "$RATE_RECORD_ERROR" >&2
            return 0
        fi
        bash "$CLASSIFY_FAILURES" --since "$since" --session-id "$CLASSIFY_SESSION_ID" || {
            printf 'harness-weekly: WARN classifying failures with %s failed; this week is recorded as unclassified\n' \
                "$CLASSIFY_FAILURES" >&2
            classification=failed
        }
        bash "$FAILURE_RATES" record "$REVIEW_DATE" --since "$since" --classification "$classification" || {
            RATE_RECORD_ERROR="failed to record the failure rates with $FAILURE_RATES"
            printf 'harness-weekly: %s\n' "$RATE_RECORD_ERROR" >&2
        }
    }

    # 再発率の推移の節を、組み立てに成功したときだけ本文に足す(検出件数の節と同じ扱い)。ただし入口の照合に
    # 落ちたら節を省いたうえで予約コードを返す(呼び出し元は PR を作らない)
    append_rates_section() {
        local section status=0
        section=$(harness_integrity_run "$FAILURE_RATES" trend --weeks 4) || status=$?
        if [[ "$status" -eq 0 ]]; then
            printf '%s\n' "$section" >>"$PR_BODY"
        elif [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
            printf 'harness-weekly: the failure rate trend could not be trusted; left it out of %s\n' "$PR_BODY" >&2
            return "$status"
        else
            printf 'harness-weekly: WARN failed to build the failure rate trend; left it out of %s\n' "$PR_BODY" >&2
        fi
    }

    # 判定の記録のうち、この run の選別が採用した項目の見出しを 1 行ずつ出す(Verdict の CLI の adopted)。
    # 公開の lib が印を PR の URL に置き換える前に読む
    adopted_titles() {
        harness_integrity_run "$VERDICT_CLI" adopted --run "$REVIEW_RUN"
    }

    # 採用したルールの Eval Case を評価し、効果の節を本文に足す。採用したのに結果にも免除にも無いものは、節が
    # 名前で出す(依頼が無ければ全件がそうなる)。評価の工程の失敗は WARN にとどめて PR の公開は止めないが、
    # 本文に評価できなかったことを書く(黙って節を省くと、効果が測られていないことが PR から見えない)
    append_eval_section() {
        local adopted="$HARNESS_DIR/.eval-adopted-$REVIEW_DATE" section status=0
        adopted_titles >"$adopted" || status=$?
        if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
            rm -f "$adopted"
            return "$status"
        elif [[ "$status" -ne 0 ]]; then
            printf 'harness-weekly: WARN could not read the adopted verdicts from %s for the eval section\n' "$ARCHIVE" >&2
            : >"$adopted"
        fi
        if [[ ! -f "$EVAL_REQUESTS" ]]; then
            printf 'harness-weekly: review wrote no eval requests %s; the PR body lists every adopted rule as unevaluated\n' "$EVAL_REQUESTS"
            printf '{"cases": []}\n' >"$EVAL_REQUESTS"
        fi
        # 結果のファイルは選別の claude も置けるので、評価の前に消し、評価が成功したときだけ封印して Rule Ledger に
        # 渡す(公開の lib は封印したものだけを渡し、データの照合が封印の後の書き換えを見つける)
        rm -f "$EVAL_RESULTS" || return 1
        status=0
        HARNESS_EVAL_BUDGET_USD="$EVAL_BUDGET_USD" harness_integrity_run "$EVAL_CASES" run \
            --requests "$EVAL_REQUESTS" --date "$REVIEW_DATE" --out "$EVAL_RESULTS" || status=$?
        [[ "$status" -ne 0 ]] ||
            section=$(harness_integrity_run "$EVAL_CASES" section --results "$EVAL_RESULTS" --adopted "$adopted") || status=$?
        if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
            rm -f "$adopted"
            return "$status"
        elif [[ "$status" -eq 0 ]]; then
            printf '%s\n' "$section" >>"$PR_BODY"
            harness_integrity_seal "$EVAL_RESULTS" || {
                rm -f "$adopted"
                return "$HARNESS_INTEGRITY_FAILED"
            }
        else
            printf 'harness-weekly: WARN evaluating the eval cases with %s failed; the PR body says so\n' "$EVAL_CASES" >&2
            printf '\n## ルールの効果\n\n評価の工程が失敗したため、この PR のルールの効果は測っていない(週次ジョブのログを参照)。\n' >>"$PR_BODY"
        fi
        rm -f "$adopted"
    }

    # Metrics-only PR の本文の節(推移と検出件数)。公開の lib が記録の commit と件数の文の後に呼ぶ。
    # 推移の節が入口の照合に落ちたら非 0 を返し、lib は PR を作らない。
    # lib が名前で呼ぶので shellcheck は呼び出しを追えない(新しい版は SC2329、古い版は SC2317 で指摘する)
    # shellcheck disable=SC2317,SC2329
    metrics_only_sections() {
        append_rates_section || return 1
        append_detection_section
        return 0
    }

    # queue が空で選別を省いた週に、Metrics-only PR が要るかを確かめて作る。要否の判定と公開は公開の lib が行い、
    # worktree を作る前の絞り込みと、base を使った判定の 2 段で尋ねる。当日のブランチが origin に
    # あれば、その日の PR は作成済みか手で作るのを待っているので作らない
    publish_metrics_if_due() {
        local remote_status=0 base
        harness_publish_metrics_only_maybe_due || return 0
        git -C "$REPO" ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null || remote_status=$?
        if [[ "$remote_status" -ne 2 ]]; then
            [[ "$remote_status" -eq 0 ]] ||
                printf 'harness-weekly: WARN failed to query origin for %s (git ls-remote exit %s); no metrics-only PR this week\n' \
                    "$BRANCH" "$remote_status" >&2
            return 0
        fi
        command -v pnpm >/dev/null 2>&1 || {
            printf 'harness-weekly: pnpm not found on PATH (%s); add the directory that holds it (e.g. ~/.local/share/mise/shims) to PATH in the launchd plist; no metrics-only PR\n' \
                "$PATH" >&2
            return 1
        }
        prepare_worktree || {
            printf 'harness-weekly: failed to prepare the worktree %s for a metrics-only PR\n' "$WORKTREE" >&2
            return 1
        }
        rm -f "$PR_BODY" "$REVIEW_RESULT"
        base=$(git -C "$WORKTREE" rev-parse HEAD) || return 1
        if ! harness_publish_metrics_only_due "$base"; then
            harness_publish_discard
            return 0
        fi
        (cd "$WORKTREE" && pnpm install --frozen-lockfile --prefer-offline) || {
            printf 'harness-weekly: pnpm install failed in %s; no metrics-only PR\n' "$WORKTREE" >&2
            return 1
        }
        harness_publish_metrics_only "$base" metrics_only_sections
    }

    # 選別の結果から PR を作る。選別が残したものの分類(Review Outcome の lib の harness_review_outcome_classify)で振り分ける:
    #   - no-change → 成功。PR は作らない(deploy-only だけの週を含む)。ただし origin/main に無い週の再発率の記録が
    #     たまっていれば、Metrics-only PR を作る(公開の lib の harness_publish_metrics_only_due と harness_publish_metrics_only)
    #   - publish → 本文の節を足し、公開の lib の harness_publish_review で PR を作る
    #   - failed と、分類の照合の失敗(予約コード 3)→ 失敗。heartbeat を書かせない(理由は Review Outcome の lib が出す。
    #     照合の失敗は Integrity Snapshot の lib が書き換えを出し、ここで PR を作らないことを出す)
    # 公開の lib が失敗を返したとき(push か PR の作成の失敗など。扱いはその入口のコメント)も失敗にする。
    # commit 0 件で成功する週は本文を PR にしないので捨てる(採用も陳腐化の修正も無い週の本文は件数と残った陳腐化だけで、
    # 次の選別がまた数える)。失敗の経路では worktree・本文・結果ファイルを残す(調べられるように。worktree は次の
    # 実行が作り直す)。採用した項目は既に archive に移っているので、push か PR の作成が失敗した run の
    # commit は $REPO のローカルブランチ $BRANCH から手で push / PR を作る(案内は公開の lib が出す)
    publish_review() { # <base>
        local base=$1 outcome outcome_status=0 titles status=0
        # データの照合は工程の入口が選別の claude の直後に済ませており、落ちた run はここに来ない(report_failed_review)。
        # Verdict の CLI などの実行物は、分類が入口を通して呼ぶときに照合される
        outcome=$(harness_review_outcome_classify "$base" ok) || outcome_status=$?
        if [[ "$outcome_status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
            printf 'harness-weekly: no PR created; the Verdict CLI could not be trusted\n' >&2
            return 1
        fi
        [[ "$outcome_status" -eq 0 ]] || return 1
        case "$outcome" in
        publish) ;;
        no-change)
            if harness_publish_metrics_only_due "$base"; then
                printf 'harness-weekly: review committed no changes; opening a metrics-only PR\n'
                harness_publish_metrics_only "$base" metrics_only_sections
                return
            fi
            printf 'harness-weekly: review committed no changes; no PR created\n'
            harness_publish_discard
            return 0
            ;;
        *) return 1 ;;
        esac
        harness_review_outcome_sections >>"$PR_BODY" || return 1
        append_detection_section
        append_rates_section || {
            printf 'harness-weekly: no PR created; the failure rate trend could not be trusted\n' >&2
            return 1
        }
        append_eval_section || {
            printf 'harness-weekly: no PR created; the evaluation could not be trusted\n' >&2
            return 1
        }
        # 純増は選別の commit だけで数える(記録の commit を混ぜると、ルールの肥大の数字に記録の行が入る)
        net_change_section "$base" >>"$PR_BODY" || return 1
        # Rule Ledger の記録は PR 番号が要るので、PR を作った後の commit で足す(公開の lib の harness_publish_review)。
        # 足せなかったことは本文では知らせられないので、ログの WARN と、PR の commit に記録が無いことで分かる
        # 採用を読めなければ節を省く(評価の節と同じく、PR の公開は止めない)
        titles=$(adopted_titles) || status=$?
        if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
            printf 'harness-weekly: no PR created; the Verdict CLI could not be trusted\n' >&2
            return 1
        elif [[ "$status" -ne 0 ]]; then
            printf 'harness-weekly: WARN could not read the adopted verdicts from %s; left the Rule Ledger section out of %s\n' "$ARCHIVE" "$PR_BODY" >&2
        elif [[ -n "$titles" ]]; then
            printf '\n## Rule Ledger\n\n採用したルールの記録(%s)は、この PR を作った後に週次ジョブが「harness: Rule Ledger の記録を足す」の commit で足す。その commit が無ければ、記録はローカルに残っていて、この PR がマージされた後の PR に載る(マージせずに閉じたら載らない)。\n' \
                "$HARNESS_PUBLISH_LEDGER_REPO_DIR" >>"$PR_BODY"
        fi
        harness_publish_review "$base"
    }

    # 選別の claude が失敗した(予算切れを含む)run と、claude の成否に関わらず照合に落ちた run の後始末の案内。claude は commit や
    # archive への移動を済ませてから失敗しうるので、残った commit の場所と手で PR を作る手順を
    # ログに出す(データの照合に落ちた run では、手順の代わりにそのまま公開しないよう案内する)。worktree は残す(次の実行が作り直すが、prepare_worktree は origin/main に無い
    # commit を持つ当日のブランチを作り直さない)。Deploy-only Fix の記録と、commit が無い run の案内は Review Outcome の lib が
    # 分類のときに行う。結果ファイルは run の前に消してあるので、lib が読むのはこの run の claude が書いたものだけ。
    # commit が残っていれば、手で作る PR の本文にも Dropped Change と Deploy-only Fix の節を足す(claude には本文に書かせないため、
    # 足さないと落とした変更の一覧が結果ファイルにしか残らない)
    report_failed_review() { # <base> <データを信頼できるか(1/0)>
        local base=$1 data_trusted=$2 claude=untrusted outcome commits trusted=0
        [[ "$data_trusted" -ne 1 ]] || claude=failed
        outcome=$(harness_review_outcome_classify "$base" "$claude") || return 0
        [[ "$outcome" == failed-with-commits ]] || return 0
        commits=$(git -C "$WORKTREE" rev-list --count "$base..HEAD" 2>/dev/null || printf '?')
        harness_review_outcome_sections >>"$PR_BODY" ||
            printf 'harness-weekly: failed to add the sections from %s to %s\n' "$REVIEW_RESULT" "$PR_BODY" >&2
        # データの照合(工程の入口が選別の claude の直後に済ませている)に落ちたら検出件数と推移の節を省き、手で公開する
        # 手順の代わりに、書き換えを確かめてから commit を読み直すよう案内する
        if [[ "$data_trusted" -eq 1 ]]; then
            append_detection_section
            append_rates_section && trusted=1
        fi
        if [[ "$trusted" -eq 0 ]]; then
            printf 'harness-weekly: review failed after %s commit(s) on local branch %s (worktree %s), and the scripts or records the job uses were changed (or could not be checked) after the claude runs started; do not publish the branch as it is. Restore them, find what changed them, and review the commits before publishing them by hand\n' \
                "$commits" "$BRANCH" "$WORKTREE" >&2
            return 0
        fi
        printf 'harness-weekly: review failed after %s commit(s) on local branch %s (worktree %s, PR body %s); verdicts adopted in this run may already be in %s. To publish by hand: %s, then %s, then %s\n' \
            "$commits" "$BRANCH" "$WORKTREE" "$PR_BODY" "$ARCHIVE" "$(harness_publish_push_command "$BRANCH" "$REPO")" \
            "$(harness_publish_pr_command "$BRANCH" "$PR_BODY")" "$(harness_publish_record_command "$REVIEW_RUN")" >&2
    }

    # 成功した run の締め。前の run が採用を記録したまま PR にできなかった(push・PR の作成・
    # 選別の claude のどれかが失敗した)ことを、次の週の run が見落とさないよう、heartbeat を
    # 書く前に判定の記録を確かめる(Verdict の CLI の unpublished)。選別は採用に run の印を付けて記録し、PR を
    # 作れた run だけが自分の印を PR の URL に置き換える(公開の lib の harness_publish_review)。手動の /harness-review は最初から
    # PR の URL で記録するので当たらない。ブランチで絞らないので、ループ以外の印(手で書いた `adopted (by hand)` など)
    # も PR になっていない採用として止まる。そうした印には push するブランチが無いので、案内の publish で記録するか
    # queue に戻す。ローカルの harness/review-* ブランチの有無で
    # 判定しないのは、手動の手順もローカルにブランチを残すため。
    # 残っていれば heartbeat を書かずに失敗し、briefing の古さの警告で人に知らせる。その週の抽出と
    # 選別は済ませてから確かめる(失敗させても週の処理は止めない)
    finish_run() {
        local leftovers run commands=""
        leftovers=$(harness_integrity_run "$VERDICT_CLI" unpublished) || {
            printf 'harness-weekly: failed to read the unpublished verdicts from %s; heartbeat not updated\n' "$ARCHIVE" >&2
            return 1
        }
        if [[ -n "$leftovers" ]]; then
            while IFS= read -r run; do
                commands+="${commands:+; }$(harness_publish_record_command "$run")"
            done <<<"$leftovers"
            printf 'harness-weekly: %s still has verdicts that never became a PR. For a loop mark (<branch> or <branch> run <id>), publish that branch from %s by hand (%s, then %s); a mark written by hand has no branch to push and needs only the PR URL. Record the PR URL with: %s. Or move the entries back to queue.md; heartbeat not updated\n' \
                "$ARCHIVE" "$REPO" "$(harness_publish_push_command '<branch>')" "$(harness_publish_pr_command '<branch>')" "$commands" >&2
            return 1
        fi
        if [[ -n "$RATE_RECORD_ERROR" ]]; then
            printf 'harness-weekly: this week has no failure rate record (%s); heartbeat not updated\n' "$RATE_RECORD_ERROR" >&2
            return 1
        fi
        harness_health_write_heartbeat || {
            printf 'harness-weekly: failed to write the heartbeat %s\n' "$(harness_health_heartbeat_file)" >&2
            return 1
        }
    }

    # 処理対象が無い工程は claude を起動しない。起動するだけで固定の文脈分の費用がかかるため。
    # 両方の工程を省いた週も、finish_run の確認を通れば heartbeat は書く(「ジョブが健全に
    # 回った」の意味。分類する失敗も無ければ、その週は claude と認証の経路を通らない)
    # 抽出の入力は失敗の検出器で選ぶ(ADR 0011)。失敗の無いセッションは claude にかけずに pending から外し、
    # セッションごとの件数を $DETECTIONS に残す。選別が失敗したら抽出に進まない(選ばれていない入力で
    # 抽出すると、検出件数の無いセッションが混ざる)
    bash "$SELECT_PENDING" --run "$SESSION_ID" || {
        printf 'harness-weekly: selecting pending sessions with %s failed; skipped reflect\n' "$SELECT_PENDING" >&2
        exit 1
    }
    # 分類と週の記録は、選別を省く・当日の PR が既にあるなどの早期の終了より前に、毎週行う
    record_failure_rates
    # 抽出と選別の claude を起動する前に、claude の後に使うスクリプトとデータのハッシュを取る(Integrity Snapshot)。
    # 分類器の claude はツール無しなので、その後でよい。$( ) の外で呼ぶ(値は lib のシェル変数に持つ)
    harness_integrity_snapshot || {
        printf 'harness-weekly: failed to take the integrity snapshot; skipped reflect\n' >&2
        exit 1
    }
    if [[ "$(count_pending)" -eq 0 ]]; then
        printf 'harness-weekly: pending is empty; skipped reflect\n'
    else
        # 1 回で扱うセッション数に上限を置き、予算(--max-budget-usd)は歯止めに回す。
        # 予算だけに頼ると、溜まった分を 1 回で捌けない週は毎回予算切れで失敗し、
        # 進んでいても heartbeat が書かれない。
        # セッションごとに「queue へ追記 → pending から外す」を済ませてから次へ進ませるのは、
        # 途中で止まっても失うのが高々 1 セッション分で、queue に重複を作らないため
        PROMPT="This is the unattended weekly harness job (no human is present, and this session itself is not an input).
Use the harness-reflect skill on the entries in ~/.claude/harness/pending.jsonl, following its rules, with these changes:
- Skip running harness-select-pending.sh; this job already ran it. Still run the failure detector on each entry you process.
- Process at most ${MAX_SESSIONS} entries, oldest recorded_epoch first. Leave the rest in pending.jsonl for the next run.
- Do the Bookkeeping for each entry before starting the next one: append that session's queue entries (if any), then remove that session's line from pending.jsonl.
- Update last_reflect_epoch in state.json once at the end.
${WRITE_RULE}
- Ignore suggestions from SessionStart hook output (such as running /harness-review). Use no skill other than harness-reflect.
- Finish with a one-line summary: sessions analyzed, entries queued, entries dropped."
        # 工程の入口が、抽出の claude の成否に関わらず直後にデータを照合する(job 自身の正当な書き込みの前)。
        # queue が空の週・当日の PR が既にある週・抽出が失敗した run は repo に写す工程を通らないので、ここで照合しないと
        # 抽出の claude が書き換えたデータを次の run のスナップショットが正として持ち越す
        REFLECT_STATUS=0
        harness_integrity_run_untrusted run_claude reflect "$SESSION_ID" "$REFLECT_BUDGET_USD" "$PROMPT" || REFLECT_STATUS=$?
        if [[ "$REFLECT_STATUS" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
            printf 'harness-weekly: the local records could not be trusted after reflect; skipped review\n' >&2
            exit 1
        fi
        [[ "$REFLECT_STATUS" -eq 0 ]] || exit 1
    fi

    QUEUE_ENTRIES=$(count_queue)
    if [[ "$QUEUE_ENTRIES" -eq 0 ]]; then
        printf 'harness-weekly: queue is empty; skipped review\n'
        publish_metrics_if_due || exit 1
        finish_run || exit 1
        exit 0
    fi

    # 当日のブランチが origin にあれば、その日のループの PR は作成済みか、push 後に PR の作成が
    # 失敗している(その run のログが手で開くよう促しているか、公開の直前の関門で止まってブランチを消すよう促している)。作り直したブランチは
    # non-fast-forward で push できず、選別の費用が無駄になるので起動しない
    REMOTE_STATUS=0
    git -C "$REPO" ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null || REMOTE_STATUS=$?
    if [[ "$REMOTE_STATUS" -eq 0 ]]; then
        # PR が無いまま(push 後に gh pr create が失敗した)なら、健全に見せないよう失敗させる
        EXISTING_PR=$(cd "$REPO" && gh pr list --head "$BRANCH" --state all --json url --jq '.[0].url // empty') || {
            printf 'harness-weekly: %s exists on origin but listing its PR failed; skipped review\n' "$BRANCH" >&2
            exit 1
        }
        if [[ -z "$EXISTING_PR" ]]; then
            printf 'harness-weekly: %s exists on origin but has no PR; skipped review. Check the log of the run that pushed it: if it stopped before gh pr create because the scripts could not be trusted, delete the branch (git push origin --delete %s); otherwise open the PR by hand (%s)\n' \
                "$BRANCH" "$BRANCH" "$(harness_publish_pr_command "$BRANCH" "$PR_BODY")" >&2
            exit 1
        fi
        printf 'harness-weekly: %s already exists on origin (PR %s); skipped review\n' "$BRANCH" "$EXISTING_PR"
        finish_run || exit 1
        exit 0
    elif [[ "$REMOTE_STATUS" -ne 2 ]]; then
        printf 'harness-weekly: failed to query origin for %s (git ls-remote exit %s)\n' "$BRANCH" "$REMOTE_STATUS" >&2
        exit 1
    fi

    # pnpm(と選別の claude が走らせる commit フックの prek・node)は mise の shims にしか無い
    # マシンがある。launchd の PATH に shims が無いと pnpm install が「失敗」としか出ないので、
    # 選別の前に原因を名指しして止める(plist の EnvironmentVariables の PATH)
    command -v pnpm >/dev/null 2>&1 || {
        printf 'harness-weekly: pnpm not found on PATH (%s); add the directory that holds it (e.g. ~/.local/share/mise/shims) to PATH in the launchd plist; skipped review\n' \
            "$PATH" >&2
        exit 1
    }
    printf 'harness-weekly: review session=%s queue=%s branch=%s\n' "$REVIEW_SESSION_ID" "$QUEUE_ENTRIES" "$BRANCH"
    prepare_worktree || {
        printf 'harness-weekly: failed to prepare the review worktree %s\n' "$WORKTREE" >&2
        exit 1
    }
    # 前回の本文と結果ファイルを消すのは prepare_worktree の判定を通った後。手で publish すべき
    # commit が残っている間は、その PR に使う本文を残す。結果ファイルを消すのは、同じ日の前の
    # run が残したものを今回の結果として読まないため
    rm -f "$PR_BODY" "$REVIEW_RESULT" "$EVAL_REQUESTS" "$EVAL_RESULTS"
    REVIEW_BASE=$(git -C "$WORKTREE" rev-parse HEAD)
    # commit フック(prek)と just lint-fast が node_modules を要るので、claude の前に入れる。
    # claude に入れさせないのは、失敗したときに予算を使って直そうとさせないため
    (cd "$WORKTREE" && pnpm install --frozen-lockfile --prefer-offline) || {
        printf 'harness-weekly: pnpm install failed in %s; skipped review\n' "$WORKTREE" >&2
        exit 1
    }

    # 手順は harness-review スキルのまま使い、手動の /harness-review と同じ queue と判定の
    # 記録(queue-archive.md・state.json)を更新させる。変えるのは、作業場所と、push と PR を
    # このスクリプトが行う点だけ。節は番号ではなく見出しで指す(番号は SKILL.md の変更で黙ってずれる)
    # 結果ファイルの指示文は、形の検査と同じく Review Outcome の lib が持つ
    RESULT_INSTRUCTIONS=$(harness_review_outcome_result_instructions) || exit 1
    REVIEW_PROMPT="This is the unattended weekly harness job (no human is present, and this session itself is not an input).
Use the harness-review skill, following its rules, with these changes:
- Your working directory is a git worktree of the chezmoi source repo, on branch ${BRANCH}, freshly created from origin/main with dependencies installed. Make every repository change here. Do not cd to the chezmoi source path or any other checkout.
- Skip \"Reflect over pending sessions\"; this job already ran it.
- Never run chezmoi apply (it would deploy the main source, not this branch, with no human present). List a deploy-only fix (one that a commit cannot fix and that takes effect only when a human applies it) in the result file instead.
- In \"Implement and open ONE PR\": do not create or switch branches, do not push, and do not open a PR; this job does those after you finish. Commit on the current branch and leave the working tree clean: one commit per adopted change, with its queue title in the subject, and one commit per staleness fix, with what it fixes in the subject (this job counts the additions and deletions of each change from its commit). Treat each [slow] recipe (just --list) whose targets a change touches as part of just lint-fast for that change. Fold fixes for a failing commit hook or just lint-fast into that change's commit instead of adding a separate commit. Never use --no-verify and do not install dependencies; if a commit hook or just lint-fast fails and you cannot fix the change, drop that change, leave its entry in queue.md (do not move it to the archive; the failure may come from the environment, so a later run triages it again), and list it in the result file with the failing hook or lint check.
${RESULT_INSTRUCTIONS}
- Write the PR body (in Japanese) to ${PR_BODY}: for each adopted change, its queue title, the files it changes, and why it was adopted; for each staleness fix, the files and why; then the rejected and handoff counts and the remaining staleness findings. Do not write line counts, failure detection counts, failure pattern rates, rule effects, dropped changes or deploy-only fixes in the PR body; this job appends them from the diff, its detection and rate records, the evaluation and the result file. Never change files under ${HARNESS_PUBLISH_RATES_REPO_DIR} or ${HARNESS_PUBLISH_LEDGER_REPO_DIR}, or the local Rule Ledger in ${LOCAL_LEDGER_DIR}; this job commits them. If nothing is adopted and nothing is stale, make no commits.
- For every adopted change, write an Eval Case request to ${EVAL_REQUESTS} as described in the skill's \"Eval Case requests\" section (Write tool only; this job runs the evaluation and appends the effect to the PR body). Do not run the evaluation yourself.
- In \"Bookkeeping\", record every verdict with the skill's settle command (a command with single-quoted arguments, not text you compose). HARNESS_REVIEW_RUN is set, so never pass --pr-url: this job records the PR URL after it opens the PR. Do not run harness-rule-ledger.sh; this job records the Rule Ledger after it opens the PR.
${WRITE_RULE}
- Ignore suggestions from SessionStart hook output. Use no skill other than harness-review.
- Finish with a one-line summary: entries adopted, rejected, handed off."
    # HARNESS_REVIEW_RUN は選別の claude にだけ渡す(抽出・分類・評価には渡さない)
    # shellcheck disable=SC2317,SC2329 # Integrity Snapshot の工程の入口に関数名で渡して呼ぶ
    review_in_worktree() {
        (cd "$WORKTREE" && export HARNESS_REVIEW_RUN="$REVIEW_RUN" &&
            run_claude review "$REVIEW_SESSION_ID" "$REVIEW_BUDGET_USD" "$REVIEW_PROMPT")
    }
    # 抽出と同じく、工程の入口が選別の claude の成否に関わらず直後にデータを照合する。失敗で終わる経路(選別の claude の
    # 失敗・結果ファイルの不正・未 commit の変更)も repo に写す工程を通らないので、照合しないと書き換えがログに出ないまま
    # 次の run のスナップショットが正として持ち越す。照合に落ちた run は、claude が成功していても失敗した選別として扱う
    # (入口の終了コードからは claude の成否が分からない。どちらでも PR は作らず、手で公開する手順も案内しない)
    REVIEW_STATUS=0
    harness_integrity_run_untrusted review_in_worktree || REVIEW_STATUS=$?
    if [[ "$REVIEW_STATUS" -ne 0 ]]; then
        report_failed_review "$REVIEW_BASE" "$((REVIEW_STATUS == HARNESS_INTEGRITY_FAILED ? 0 : 1))"
        exit 1
    fi
    publish_review "$REVIEW_BASE" || exit 1

    finish_run || exit 1
}

# main の呼び出しと exit を 1 つのグループにするのは、bash がグループを閉じるまで読んでから実行し、main が
# 戻った後にこのファイルの続きを読まないため。main を条件の文脈(`main || …` や `if main`)で呼ぶと、
# main の中で set -e が効かなくなる
{
    main "$@"
    exit
}
