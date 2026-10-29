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
# `gh pr create --draft` はこのジョブが固定の引数で行う。選別の経路と Metrics-only PR の手順の正本は Loop PR の module
# (lib/harness-loop-pr.bash)の入口のコメント、本文の節の正本はその内側の本文の lib(lib/harness-pr-body.bash)で、
# このスクリプトは選別の claude を走らせるコマンドを Loop PR の module の入口に渡す。claude にさせないのは、headless では
# PreToolUse フックの ask が拒否になり、git push guard が変数を含む push に ask を返すため(#429)。
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
    # 週の再発率の記録(1 週 1 ファイル)。ローカルに全週を持ち、PR を作る run がリポジトリに無い週の分を、
    # Loop PR の module がこのジョブの commit で足す(リポジトリ内の置き場はその module が持つ)。
    # 1 つのファイルに追記しないのは、記録を含む PR が 2 本開いたときに同じ行の追記どうしで
    # コンフリクトするため(同じ内容の新規ファイルどうしならぶつからない)
    LOCAL_RATES_DIR="$HARNESS_DIR/failure-pattern-rates"
    # 判定の記録を読み書きする Verdict の CLI
    VERDICT_CLI="$HOME/.claude/scripts/harness-verdict.sh"

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
                # 綴りの正本は Loop PR の module。lib を読み込む前に止まった run だけがこの写しを使うので、綴りを変えるときは両方を直す
                # (食い違いは test/harness-weekly.bats の「Loop PR の module を読み込む前に止まった run のブランチの Issue も…」が見つける)
                if declare -F harness_loop_pr_push_command harness_loop_pr_create_command >/dev/null; then
                    push_command=$(harness_loop_pr_push_command "$branch" "$repo")
                    pr_command=$(harness_loop_pr_create_command "$branch")
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
    # 採用したルールの Eval Case の依頼と結果。依頼は選別に書かせ、Loop PR の module が harness-eval-cases.sh で評価して結果を書く(ADR 0011)
    EVAL_REQUESTS="$HARNESS_DIR/eval-requests-$REVIEW_DATE.json"
    EVAL_RESULTS="$HARNESS_DIR/eval-results-$REVIEW_DATE.json"
    EVAL_BUDGET_USD="${HARNESS_WEEKLY_EVAL_BUDGET_USD:-5}"
    # ループのブランチの prefix。正本は scripts/check-guarded-paths.sh(CI はこの prefix でループの PR を見分ける)
    LOOP_BRANCH_PREFIX="harness/review-"
    BRANCH="${LOOP_BRANCH_PREFIX}${REVIEW_DATE}"
    # 選別の採用の印。選別の claude に環境変数 HARNESS_REVIEW_RUN で渡し、Verdict の CLI の settle が採用に付ける
    # (ADR 0017。prompt には書かない)。印の書式は CLI だけが持ち、このスクリプトは印の値で CLI を呼ぶ。
    # run ごとの印(選別の session id)を入れるのは、同じ日の前の run が失敗して残した採用を、今回の PR の URL で
    # 上書きしないため(Loop PR の module の harness_loop_pr_run_review)。前の run の記録は残り、finish_run が知らせる
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
    # heartbeat はこの run が成功すると書き換わるので、起動時に読む
    MISSED_DAYS=$(harness_health_missed_run_days)
    # 前の成功の時刻。失敗の Issue がそれより後に更新されていれば、走らなかった週はその Issue が知らせている
    LAST_SUCCESS=$(harness_health_heartbeat_epoch) || LAST_SUCCESS=""
    # PR の本文の検出件数の期間の始まり(Loop PR の module の初期化に渡す)。前の成功が無ければ直近 7 日にする
    DETECTION_SINCE=${LAST_SUCCESS:-$(($(date +%s) - 7 * 24 * 60 * 60))}
    # Loop PR の module。選別の prompt の指示・手で公開するコマンドの綴り・選別の経路(作業場所の準備・選別の claude の実行・
    # その後の処理と公開)・Metrics-only PR の正本。読み込むときに Review Outcome の lib と本文の lib を読み込み、読めなければ
    # 理由を出して止まる(このスクリプトはその 2 つを読まない)。ほかの lib と同じく、claude の起動前に読んでメモリに載せる。
    # 最後に読むので、この lib を読めずに止まった run の report_stops は綴りの関数を持たない(report_stops がその場合の綴りを
    # 持つ)。このジョブが呼ぶ初期化はこの lib のものだけ
    LOOP_PR_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/harness-loop-pr.bash"
    if [[ ! -r "$LOOP_PR_LIB" ]] || ! "$BASH" -n "$LOOP_PR_LIB" 2>/dev/null; then
        printf 'harness-weekly: %s is missing or broken; run chezmoi apply\n' "$LOOP_PR_LIB" >&2
        exit 1
    fi
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=lib/harness-loop-pr.bash
    source "$LOOP_PR_LIB" || exit 1
    if ! declare -F harness_loop_pr_init harness_loop_pr_review_instructions harness_loop_pr_push_command \
        harness_loop_pr_create_command harness_loop_pr_record_command harness_loop_pr_run_review \
        harness_loop_pr_publish_metrics_only_if_due >/dev/null; then
        printf 'harness-weekly: %s lacks the publish steps; run chezmoi apply\n' "$LOOP_PR_LIB" >&2
        exit 1
    fi
    harness_loop_pr_init --repo "$REPO" --worktree "$WORKTREE" --branch "$BRANCH" --loop-branch-prefix "$LOOP_BRANCH_PREFIX" \
        --pr-body "$PR_BODY" --review-result "$REVIEW_RESULT" --eval-requests "$EVAL_REQUESTS" --eval-results "$EVAL_RESULTS" \
        --eval-budget-usd "$EVAL_BUDGET_USD" --date "$REVIEW_DATE" --run "$REVIEW_RUN" --detections "$DETECTIONS" \
        --detection-since "$DETECTION_SINCE" || exit 1

    # headless の claude を 1 回起動し、結果をログに残してから成否を返す。
    # 非 0 で終わっても結果(費用・エラーの種類)を先に出す。予算の上限などで止まった run も
    # exit 0 で終わりうるので、終了コードだけでなく結果の is_error も見る。読めない結果は
    # 失敗に倒す(heartbeat が嘘をつかないように)。
    # permission_denials は headless で拒否されたツール呼び出し。PreToolUse フックの ask も
    # ここに入る(確認する人がいないため)。エージェントが別の形で再試行して進むこともあるので
    # 失敗にはしないが、黙って成功扱いにしないよう警告を出す
    # shellcheck disable=SC2317,SC2329 # 抽出では工程の入口に、選別では Loop PR の module の選別の経路の入口に関数名で渡す
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

    # 検出した失敗を Failure Pattern に分類し、この run の週の再発率を記録する。期間は分類に成功した
    # 前の週の記録の終わりから(harness-failure-rates.sh の since)。分類に失敗した週も、失敗したことを記録し
    # (推移では「記録なし」になる)、その週の失敗は次の run の期間に含めて分類し直すので、分類の失敗は
    # WARN だけにする。期間を決められない・記録を
    # 書けない週は記録そのものが欠け、推移に「記録なし」とも出ないので、RATE_RECORD_ERROR に残して
    # finish_run で run を失敗させる(週の処理は止めない)。since は前の週の記録が読めないと毎週失敗するので、
    # WARN だけだと以降の週の記録が黙って作られなくなる。Metrics-only PR の push や作成の失敗は、
    # 採用のある PR と同じく run の失敗にする(Loop PR の module の harness_loop_pr_publish_metrics_only_if_due)
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

    # 成功した run の締め。前の run が採用を記録したまま PR にできなかった(push・PR の作成・
    # 選別の claude のどれかが失敗した)ことを、次の週の run が見落とさないよう、heartbeat を
    # 書く前に判定の記録を確かめる(Verdict の CLI の unpublished)。選別は採用に run の印を付けて記録し、PR を
    # 作れた run だけが自分の印を PR の URL に置き換える(Loop PR の module の harness_loop_pr_run_review)。手動の /harness-review は最初から
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
                commands+="${commands:+; }$(harness_loop_pr_record_command "$run")"
            done <<<"$leftovers"
            printf 'harness-weekly: %s still has verdicts that never became a PR. For a loop mark (<branch> or <branch> run <id>), publish that branch from %s by hand (%s, then %s); a mark written by hand has no branch to push and needs only the PR URL. Record the PR URL with: %s. Or move the entries back to queue.md; heartbeat not updated\n' \
                "$ARCHIVE" "$REPO" "$(harness_loop_pr_push_command '<branch>')" "$(harness_loop_pr_create_command '<branch>')" "$commands" >&2
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
        # 選別を省いた週の Metrics-only PR(要否の判定・作業場所の準備・公開は Loop PR の module)
        harness_loop_pr_publish_metrics_only_if_due || exit 1
        finish_run || exit 1
        exit 0
    fi

    # 手順は harness-review スキルのまま使い、手動の /harness-review と同じ queue と判定の
    # 記録(queue-archive.md・state.json)を更新させる。変えるのは、作業場所と、push と PR を
    # このジョブが行う点だけ。節は番号ではなく見出しで指す(番号は SKILL.md の変更で黙ってずれる)
    # 結果ファイル・本文・このジョブが commit する記録の置き場の指示は Loop PR の module が持つ(2 行目に続けて書く)
    REVIEW_INSTRUCTIONS=$(harness_loop_pr_review_instructions) || exit 1
    REVIEW_PROMPT="This is the unattended weekly harness job (no human is present, and this session itself is not an input).
Use the harness-review skill, following its rules, with these changes:
- Your working directory is a git worktree of the chezmoi source repo, on branch ${BRANCH}, freshly created from origin/main with dependencies installed. Make every repository change here. Do not cd to the chezmoi source path or any other checkout.
- Skip \"Reflect over pending sessions\"; this job already ran it.
- Never run chezmoi apply (it would deploy the main source, not this branch, with no human present). List a deploy-only fix (one that a commit cannot fix and that takes effect only when a human applies it) in the result file instead.
- In \"Implement and open ONE PR\": do not create or switch branches, do not push, and do not open a PR; this job does those after you finish. Commit on the current branch and leave the working tree clean: one commit per adopted change, with its queue title in the subject, and one commit per staleness fix, with what it fixes in the subject (this job counts the additions and deletions of each change from its commit). Treat each [slow] recipe (just --list) whose targets a change touches as part of just lint-fast for that change. Fold fixes for a failing commit hook or just lint-fast into that change's commit instead of adding a separate commit. Never use --no-verify and do not install dependencies; if a commit hook or just lint-fast fails and you cannot fix the change, drop that change, leave its entry in queue.md (do not move it to the archive; the failure may come from the environment, so a later run triages it again), and list it in the result file with the failing hook or lint check.
${REVIEW_INSTRUCTIONS} If nothing is adopted and nothing is stale, make no commits.
- For every adopted change, write an Eval Case request to ${EVAL_REQUESTS} as described in the skill's \"Eval Case requests\" section (Write tool only; this job runs the evaluation and appends the effect to the PR body). Do not run the evaluation yourself.
- In \"Bookkeeping\", record every verdict with the skill's settle command (a command with single-quoted arguments, not text you compose). HARNESS_REVIEW_RUN is set, so never pass --pr-url: this job records the PR URL after it opens the PR. Do not run harness-rule-ledger.sh; this job records the Rule Ledger after it opens the PR.
${WRITE_RULE}
- Ignore suggestions from SessionStart hook output. Use no skill other than harness-review.
- Finish with a one-line summary: entries adopted, rejected, handed off."
    # 選別の経路の手順は Loop PR の module の harness_loop_pr_run_review のコメントが正本で、入口は成功か失敗かだけを返す。
    # 開始の行は、前提の確認を通った後に module が出す
    printf -v REVIEW_START_LINE 'harness-weekly: review session=%s queue=%s branch=%s' "$REVIEW_SESSION_ID" "$QUEUE_ENTRIES" "$BRANCH"
    harness_loop_pr_run_review "$REVIEW_START_LINE" \
        run_claude review "$REVIEW_SESSION_ID" "$REVIEW_BUDGET_USD" "$REVIEW_PROMPT" || exit 1

    finish_run || exit 1
}

# main の呼び出しと exit を 1 つのグループにするのは、bash がグループを閉じるまで読んでから実行し、main が
# 戻った後にこのファイルの続きを読まないため。main を条件の文脈(`main || …` や `if main`)で呼ぶと、
# main の中で set -e が効かなくなる
{
    main "$@"
    exit
}
