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
# 採用した commit があれば(または採用が無くても週の再発率の記録がたまっていれば。
# publish_metrics_only)、push と `gh pr create --draft` はこのスクリプトが固定の引数で
# 行う。claude にさせないのは、headless では PreToolUse フックの ask が拒否になり、
# git push guard が変数を含む push に ask を返すため(#429)。
# 両方の工程が成功するか省かれ、判定の記録に PR にならなかった採用が残っていなければ(finish_run)
# heartbeat(最後に成功した時刻)を書き、briefing と doctor がその古さを表示する。
# 停止(この run の失敗・前の週に成功しなかったこと・ループの PR の放置・PR にならないループの
# ブランチ)は、EXIT trap の report_stops が GitHub Issue で知らせる。
#
# PR のブランチ名は `harness/review-<日付>`。CI はこの prefix で自己改善ループの PR を
# 見分け、Evaluator のパス(scripts/evaluator-paths.txt)に触れた PR を落とす
# (scripts/check-evaluator-guard.sh)。手動の /harness-review が使う名前も同じで、
# harness-review スキルの「Implement and open ONE PR」節が指定する
#
# nono をこのスクリプトの中で掛けないのは、このファイルが nono の内側から書き換えられる
# (~/.claude は claude-seal で read+write)ため。境界の外で無人実行されるのは、
# 内側から書けない nono の実体と plist だけにする
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
HEARTBEAT="$HARNESS_DIR/weekly-heartbeat"
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
# RATES_REPO_DIR に無い週の分をこのスクリプトの commit で足す(commit_rate_records)。
# 1 つのファイルに追記しないのは、記録を含む PR が 2 本開いたときに同じ行の追記どうしで
# コンフリクトするため(同じ内容の新規ファイルどうしならぶつからない)
LOCAL_RATES_DIR="$HARNESS_DIR/failure-pattern-rates"
RATES_REPO_DIR="docs/harness/failure-pattern-rates"
# origin/main に無い週の記録がこの件数たまったら、採用が無くても記録だけの draft PR を作る
METRICS_ONLY_WEEKS=4
# このスクリプト自身の commit が使う git の設定。launchd の環境には GIT_CONFIG_GLOBAL が無く
# (Claude Code の子プロセスには settings.json の env が渡す)、~/.gitconfig の署名は 1Password に
# 頼るので、無人の run では止まる。Claude Code の git と同じ設定(ローカルの署名鍵)を使う
AGENT_GIT_CONFIG="$HOME/.config/git/claude-code.inc"

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

write_heartbeat() {
    local tmp
    tmp=$(mktemp "$HARNESS_DIR/.weekly-heartbeat.XXXXXX")
    date +%s >"$tmp"
    mv "$tmp" "$HEARTBEAT"
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

# PR の本文の検出件数の期間の始まり(detection_section)。この run が heartbeat を書き換える前に読む。
# heartbeat が無いか壊れていれば直近 7 日にする
DETECTION_SINCE=$(($(date +%s) - 7 * 24 * 60 * 60))
if [[ -f "$HEARTBEAT" ]] && read -r heartbeat_epoch <"$HEARTBEAT" && [[ "$heartbeat_epoch" =~ ^[0-9]+$ ]]; then
    # 10# で先頭 0 を落とす。0 付きのままだと jq の --argjson と date が読めず、節が省かれる
    DETECTION_SINCE=$((10#$heartbeat_epoch))
fi

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
open_issue() { # <タイトル>
    local issues
    issues=$(cd "$REPO" && gh issue list --label "$ALERT_LABEL" --state open --json number,title,updatedAt --limit 100) &&
        jq -r --arg title "$1" '[.[] | select(.title == $title)][0]
            | if . == null then empty
              else "\(.number)\t\(.updatedAt | sub("\\.[0-9]+"; "") | fromdateiso8601)" end' <<<"$issues"
}

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
# shellcheck disable=SC2016,SC2088
report_stops() { # <この run の終了コード>
    local status=$1 failed=0 reported_failure=0 failed_issue="" log remedy prs stale number url days branches branch count pr_count repo cutoff
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
            # 採用の記録が残るブランチは finish_run がジョブを失敗させ、失敗の Issue が知らせる
            # (記録の形は finish_run と同じ。PR の URL で置き換わる前の adopted (<ブランチ> …))
            if [[ -f "$ARCHIVE" ]] && grep -qF -e "adopted ($branch)" -e "adopted ($branch run " "$ARCHIVE"; then
                printf 'harness-weekly: %s has an adopted verdict in %s; the failure issue reports it\n' "$branch" "$ARCHIVE"
                continue
            fi
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
            alert_issue "harness: ループのブランチ ${branch} が PR になっていない" "$(printf 'ループのブランチ `%s` が、PR にならないまま `%s` に残っている(origin/main に無い commit: %s 件)。週次ジョブはこのブランチを公開しない。\n\n対処(どちらか):\n\n- 公開する: `git -C %s push origin %s` の後に、`%s` で `gh pr create --draft --base main --head %s`\n- 要らなければ消す: `git -C %s branch -D %s`\n\nどちらかをしたら、この Issue を閉じる。\n' \
                "$branch" "$repo" "$count" "$repo" "$branch" "$repo" "$branch" "$repo" "$branch")" || failed=1
        done <<<"$branches"
    else
        printf 'harness-weekly: WARN could not list the loop branches in %s (is origin/main fetched?)\n' "$REPO" >&2
        failed=1
    fi
    return "$failed"
}

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
# 選別に毎回書かせる結果ファイル。Dropped Change と Deploy-only Fix を人が読める 1 行の
# 文字列の配列で持つ({"dropped": [...], "deploy_only": [...]})。選別の成否の判定は本文の
# 有無ではなくこのファイルで行い、本文の 2 つの節もこのファイルからこのスクリプトが作る
REVIEW_RESULT="$HARNESS_DIR/review-result-$REVIEW_DATE.json"
# Deploy-only Fix の報告先。PR の有無にかかわらず日付付きで追記し、空でない間は
# briefing が警告する(人が適用したら消す)
DEPLOY_ONLY="$HARNESS_DIR/deploy-only.md"
# 採用したルールの Eval Case の依頼。選別に書かせ、harness-eval-cases.sh が評価して結果を書く(ADR 0011)
EVAL_CASES="$HOME/.claude/scripts/harness-eval-cases.sh"
EVAL_REQUESTS="$HARNESS_DIR/eval-requests-$REVIEW_DATE.json"
EVAL_RESULTS="$HARNESS_DIR/eval-results-$REVIEW_DATE.json"
EVAL_BUDGET_USD="${HARNESS_WEEKLY_EVAL_BUDGET_USD:-5}"
# ループのブランチの prefix。正本は scripts/check-evaluator-guard.sh(CI はこの prefix でループの PR を見分ける)
LOOP_BRANCH_PREFIX="harness/review-"
BRANCH="${LOOP_BRANCH_PREFIX}${REVIEW_DATE}"
# 選別に書かせる採用の記録。run ごとの印(選別の session id)を入れるのは、同じ日の前の run が
# 失敗して残した adopted (<ブランチ> …) を、今回の PR の URL で上書きしないため(record_pr_url)。
# 前の run の記録は残り、finish_run が知らせる
ADOPTED_MARK="adopted ($BRANCH run $REVIEW_SESSION_ID)"

# 停止の判定(前の成功の古さ・PR の放置・PR にならないループのブランチ)は健全性の lib にある。
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
declare -F harness_health_heartbeat_epoch harness_health_missed_run_days harness_health_stale_prs harness_health_unpublished_loop_branches >/dev/null || {
    printf 'harness-weekly: %s lacks the stop checks; run chezmoi apply\n' "$HEALTH_LIB" >&2
    exit 1
}
# heartbeat はこの run が成功すると書き換わるので、起動時に読む
MISSED_DAYS=$(harness_health_missed_run_days)
# 前の成功の時刻。失敗の Issue がそれより後に更新されていれば、走らなかった週はその Issue が知らせている
LAST_SUCCESS=$(harness_health_heartbeat_epoch) || LAST_SUCCESS=""

# headless の claude を 1 回起動し、結果をログに残してから成否を返す。
# 非 0 で終わっても結果(費用・エラーの種類)を先に出す。予算の上限などで止まった run も
# exit 0 で終わりうるので、終了コードだけでなく結果の is_error も見る。読めない結果は
# 失敗に倒す(heartbeat が嘘をつかないように)。
# permission_denials は headless で拒否されたツール呼び出し。PreToolUse フックの ask も
# ここに入る(確認する人がいないため)。エージェントが別の形で再試行して進むこともあるので
# 失敗にはしないが、黙って成功扱いにしないよう警告を出す
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

remove_worktree() {
    git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
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

# 判定の記録で、この run の選別が書いた $ADOPTED_MARK を PR の URL に置き換える。
# 置き換えが 0 件になるのは、陳腐化の修正だけの PR(正常)か、選別が決めた書式で記録
# しなかったときで、ここでは区別できないので、両方の読み方を添えて知らせる
record_pr_url() {
    local from="$ADOPTED_MARK" to="adopted (PR $1)" count=0 tmp
    if [[ -f "$ARCHIVE" ]]; then
        count=$(grep -cF -- "$from" "$ARCHIVE" || true)
    fi
    if [[ "$count" -eq 0 ]]; then
        printf 'harness-weekly: no "%s" verdict in %s; PR URL not recorded (normal if the PR only fixes stale rules; otherwise the review did not record its verdicts in the expected form)\n' \
            "$from" "$ARCHIVE" >&2
        return 0
    fi
    tmp=$(mktemp "$HARNESS_DIR/.queue-archive.XXXXXX")
    awk -v from="$from" -v to="$to" '{
        out = ""
        while ((i = index($0, from)) > 0) {
            out = out substr($0, 1, i - 1) to
            $0 = substr($0, i + length(from))
        }
        print out $0
    }' "$ARCHIVE" >"$tmp" || {
        rm -f "$tmp"
        printf 'harness-weekly: WARN failed to rewrite %s; PR URL not recorded\n' "$ARCHIVE" >&2
        return 0
    }
    mv "$tmp" "$ARCHIVE"
    printf 'harness-weekly: recorded the PR URL on %s verdict(s)\n' "$count"
}

# 結果ファイルが決めた形(object で、dropped と deploy_only が文字列の配列)かを確かめる。
# キーの欠落を空配列として読まない(jq の .dropped | length は null に 0 を返す)
review_result_valid() {
    jq -e 'type == "object"
        and (.dropped | type == "array") and (.deploy_only | type == "array")
        and all(.dropped[], .deploy_only[]; type == "string")' "$REVIEW_RESULT" >/dev/null 2>&1
}

# 結果ファイルの配列 1 つの要素を、1 行の文字列に整えて出す。改行は空白に潰し(リストを
# 崩さないため)、前後の空白と、claude が付けた箇条書きの印(「- 」「* 」)を外す。空になった
# 要素は捨てる(中身の無い項目を deploy-only.md に足したり、Dropped Change と数えたりしない)
# shellcheck disable=SC2016 # $key は jq の変数
RESULT_ITEMS_FILTER='.[$key][] | gsub("[\r\n]+"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "")
    | sub("^[-*](\\s+|$)"; "") | select(length > 0)'

# 整えた要素を Markdown のリストにする
result_items() {
    jq -r --arg key "$1" "$RESULT_ITEMS_FILTER"' | "- " + .' "$REVIEW_RESULT"
}

result_count() {
    jq -r --arg key "$1" "[$RESULT_ITEMS_FILTER] | length" "$REVIEW_RESULT"
}

# Deploy-only Fix を $DEPLOY_ONLY に日付の見出し付きで追記する。既に同じ行があるものと、
# 同じ結果ファイルの中で重なったものは足さない(失敗した run の後に同じ日・次の週に
# 再実行すると、同じ修正がまた報告されるため)
record_deploy_only() {
    local items item new_items="" count=0
    items=$(result_items deploy_only) || return 1
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        if [[ -f "$DEPLOY_ONLY" ]] && grep -qxF -- "$item" "$DEPLOY_ONLY"; then
            continue
        fi
        if [[ -n "$new_items" ]] && grep -qxF -- "$item" <<<"$new_items"; then
            continue
        fi
        new_items+="${item}"$'\n'
        count=$((count + 1))
    done <<<"$items"
    [[ "$count" -gt 0 ]] || return 0
    # 同じ日の再実行では、最後の見出しが今日のものならその下に足し、見出しを重ねない
    if [[ -f "$DEPLOY_ONLY" ]] && [[ "$(grep '^## ' "$DEPLOY_ONLY" | tail -n 1)" == "## $REVIEW_DATE" ]]; then
        printf '%s\n' "$new_items" >>"$DEPLOY_ONLY" || return 1
    else
        printf '## %s\n\n%s\n' "$REVIEW_DATE" "$new_items" >>"$DEPLOY_ONLY" || return 1
    fi
    printf 'harness-weekly: recorded %s deploy-only fix(es) in %s; apply them by hand, then delete it\n' \
        "$count" "$DEPLOY_ONLY"
}

# PR の本文に付ける Dropped Change と Deploy-only Fix の節。claude には本文に書かせず、
# 結果ファイルから作る(純増の節と同じ扱い)
result_sections() {
    local dropped deploy_only
    dropped=$(result_items dropped) || return 1
    deploy_only=$(result_items deploy_only) || return 1
    if [[ -n "$dropped" ]]; then
        printf '\n## 落とした変更\n\ncommit フックか lint を通せずに commit しなかった変更。queue に残してあり、次の選別にかけ直す。\n\n%s\n' "$dropped"
    fi
    if [[ -n "$deploy_only" ]]; then
        # 本文は公開リポジトリの PR になるので、ローカルアカウント名を含む $HOME を ~ で書く
        printf '\n## deploy-only の修正\n\nこの PR の commit では直らず、人が適用して初めて効く修正。%s にも記録した(適用したら消す)。\n\n%s\n' \
            "~${DEPLOY_ONLY#"$HOME"}" "$deploy_only"
    fi
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
# WARN だけだと以降の週の記録が黙って作られなくなる。記録だけの PR の push や作成の失敗は、
# 採用のある PR と同じく run の失敗にする(publish_metrics_only)
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

# ローカルの週の記録の「ファイル名 ハッシュ」を 1 行ずつ出す。抽出と選別の claude は
# --dangerously-skip-permissions で動き、~/.claude/harness に書ける(queue.md などを書くため)ので、
# claude を起動する前に取った値と commit の前に取った値を比べ、ローカルの記録の書き換えを見つける
# (commit_rate_records)。値はこのスクリプトのシェル変数にだけ持つ(ファイルに置くと claude が書き換えられる)
rate_record_digests() {
    local file digest
    [[ -d "$LOCAL_RATES_DIR" ]] || return 0
    for file in "$LOCAL_RATES_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json; do
        [[ -f "$file" ]] || continue
        digest=$(git hash-object -- "$file") || return 1
        printf '%s %s\n' "${file##*/}" "$digest"
    done
}
RATE_RECORD_DIGESTS=""

# 再発率の推移の節を、組み立てに成功したときだけ本文に足す(検出件数の節と同じ扱い)
append_rates_section() {
    local section
    if section=$(bash "$FAILURE_RATES" trend --weeks 4); then
        printf '%s\n' "$section" >>"$PR_BODY"
    else
        printf 'harness-weekly: WARN failed to build the failure rate trend; left it out of %s\n' "$PR_BODY" >&2
    fi
}

# 判定の記録のうち、この run の選別が採用した($ADOPTED_MARK を持つ)項目の見出し(`## ` より後ろ)を 1 行ずつ出す。
# record_pr_url が印を PR の URL に置き換える前に読む
adopted_titles() {
    [[ -f "$ARCHIVE" ]] || return 0
    awk -v mark="$ADOPTED_MARK" '/^## / { title = substr($0, 4) } index($0, mark) > 0 && title != "" { print title; title = "" }' "$ARCHIVE"
}

# 採用したルールの Eval Case を評価し、効果の節を本文に足す。採用したのに結果にも免除にも無いものは、節が
# 名前で出す(依頼が無ければ全件がそうなる)。評価の工程の失敗は WARN にとどめて PR の公開は止めないが、
# 本文に評価できなかったことを書く(黙って節を省くと、効果が測られていないことが PR から見えない)
append_eval_section() {
    local adopted="$HARNESS_DIR/.eval-adopted-$REVIEW_DATE" section
    adopted_titles >"$adopted" || {
        printf 'harness-weekly: WARN could not read the adopted verdicts from %s for the eval section\n' "$ARCHIVE" >&2
        : >"$adopted"
    }
    if [[ ! -f "$EVAL_REQUESTS" ]]; then
        printf 'harness-weekly: review wrote no eval requests %s; the PR body lists every adopted rule as unevaluated\n' "$EVAL_REQUESTS"
        printf '{"cases": []}\n' >"$EVAL_REQUESTS"
    fi
    if HARNESS_EVAL_BUDGET_USD="$EVAL_BUDGET_USD" bash "$EVAL_CASES" run \
        --requests "$EVAL_REQUESTS" --date "$REVIEW_DATE" --out "$EVAL_RESULTS" &&
        section=$(bash "$EVAL_CASES" section --results "$EVAL_RESULTS" --adopted "$adopted"); then
        printf '%s\n' "$section" >>"$PR_BODY"
    else
        printf 'harness-weekly: WARN evaluating the eval cases with %s failed; the PR body says so\n' "$EVAL_CASES" >&2
        printf '\n## ルールの効果\n\n評価の工程が失敗したため、この PR のルールの効果は測っていない(週次ジョブのログを参照)。\n' >>"$PR_BODY"
    fi
    rm -f "$adopted"
}

job_git() {
    if [[ -z "${GIT_CONFIG_GLOBAL:-}" && -f "$AGENT_GIT_CONFIG" ]]; then
        GIT_CONFIG_GLOBAL="$AGENT_GIT_CONFIG" git "$@"
    else
        git "$@"
    fi
}

# ローカルの週の記録のうち、base(origin/main)の $RATES_REPO_DIR に無いものを出す。閉じた PR や
# 未マージの PR に入っていた週も、origin/main に無ければ出す(ローカルの印では判定しない)。
# この run の日付の記録だけは、origin/main にあっても中身が違えば出す。同じ日の再実行がその日の記録を
# 書き直すため(harness-failure-rates.sh の since)。リポジトリ側は oxfmt を通してあるので、バイト列では
# なく JSON として比べ、どちらかが JSON として読めなければ違うものとして出す。ほかの日付は中身を比べない:
# origin/main の記録を人が直したときにローカルの古い写しで戻さないためと、前の週の claude が書き換えた
# 記録(この run のハッシュでは見つけられない。commit_rate_records)でマージ済みの記録を上書きしないため。
# 再実行が選別を省いた(当日のブランチが origin にある)週は、書き直した記録はローカルにだけ残る
uncommitted_rate_records() {
    local base=$1 file committed local_record
    [[ -d "$LOCAL_RATES_DIR" ]] || return 0
    for file in "$LOCAL_RATES_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json; do
        [[ -f "$file" ]] || continue
        if ! git -C "$WORKTREE" cat-file -e "$base:$RATES_REPO_DIR/${file##*/}" 2>/dev/null; then
            printf '%s\n' "$file"
        elif [[ "${file##*/}" == "$REVIEW_DATE.json" ]]; then
            if ! committed=$(git -C "$WORKTREE" show "$base:$RATES_REPO_DIR/${file##*/}" | jq -S -c . 2>/dev/null) ||
                ! local_record=$(jq -S -c . "$file" 2>/dev/null) || [[ "$committed" != "$local_record" ]]; then
                printf '%s\n' "$file"
            fi
        fi
    done
}

# origin/main に無い週の記録を worktree に写し、このスクリプトの commit 1 つにする。抽出と選別の claude
# には書かせない(改善する側が指標を書き換えられないように)。リポジトリ側の書き換えは publish_review が、
# ローカルの記録の書き換えは claude を起動する前に取ったハッシュ(RATE_RECORD_DIGESTS)との比較が見つける。
# 書き換えを見つけたら commit せずに 2 を返す。比べられるのはこの run の claude による書き換えまでで、
# 前の週から持ち越した記録をその週の claude が書き換えていた場合は、この run のハッシュがそれを正として
# 取るので見つけられない(ローカルの置き場は claude の書ける ~/.claude/harness の中にしか無い)。
# oxfmt を通すのは、commit フックが JSON の書式を検査するため。写した件数を RATE_RECORDS_COMMITTED に入れる
RATE_RECORDS_COMMITTED=0
commit_rate_records() {
    local base=$1 files file digests
    RATE_RECORDS_COMMITTED=0
    digests=$(rate_record_digests) || return 1
    if [[ "$digests" != "$RATE_RECORD_DIGESTS" ]]; then
        printf 'harness-weekly: the weekly failure rate records in %s changed after the claude runs started (only this job writes them); not committed. Before: [%s] After: [%s]\n' \
            "$LOCAL_RATES_DIR" "$(tr '\n' ' ' <<<"$RATE_RECORD_DIGESTS")" "$(tr '\n' ' ' <<<"$digests")" >&2
        return 2
    fi
    files=$(uncommitted_rate_records "$base")
    [[ -n "$files" ]] || return 0
    mkdir -p "$WORKTREE/$RATES_REPO_DIR" || return 1
    while IFS= read -r file; do
        cp "$file" "$WORKTREE/$RATES_REPO_DIR/" || return 1
        RATE_RECORDS_COMMITTED=$((RATE_RECORDS_COMMITTED + 1))
    done <<<"$files"
    (cd "$WORKTREE" && pnpm exec oxfmt "$RATES_REPO_DIR") || return 1
    git -C "$WORKTREE" add -- "$RATES_REPO_DIR" || return 1
    job_git -C "$WORKTREE" commit --quiet -m "harness: Failure Pattern の再発率の週の記録を足す" || return 1
}

# 開いている自己改善ループの PR(ブランチ harness/review-*)の URL を出す。無ければ空
open_loop_pr() {
    (cd "$REPO" && gh pr list --state open --json headRefName,url \
        --jq '[.[] | select(.headRefName | startswith("harness/review-"))][0].url // empty')
}

# 記録だけの draft PR を作るべきか。origin/main に無い週の記録が METRICS_ONLY_WEEKS 件以上あり、
# 開いているループの PR が無いとき。開いている PR があれば作らない(その PR に記録が入っているか、
# 次に採用のある PR がまとめて足す。作ると毎週 1 本ずつ増える)
metrics_only_due() {
    local base=$1 count open_pr
    count=$(uncommitted_rate_records "$base" | grep -c . || true)
    if [[ "$count" -lt "$METRICS_ONLY_WEEKS" ]]; then
        printf 'harness-weekly: %s weekly failure rate record(s) not on origin/main; carried over in %s (a metrics-only PR needs %s)\n' \
            "$count" "$LOCAL_RATES_DIR" "$METRICS_ONLY_WEEKS"
        return 1
    fi
    open_pr=$(open_loop_pr) || {
        printf 'harness-weekly: WARN listing open loop PRs failed; no metrics-only PR this week\n' >&2
        return 1
    }
    if [[ -n "$open_pr" ]]; then
        printf 'harness-weekly: %s weekly failure rate record(s) not on origin/main, but loop PR %s is open; carried over\n' \
            "$count" "$open_pr"
        return 1
    fi
}

# 採用の無い週に、週の記録だけの draft PR を作る。worktree と依存は用意済みの前提
publish_metrics_only() {
    local base=$1 url
    commit_rate_records "$base" || {
        printf 'harness-weekly: failed to commit the weekly failure rate records in %s; no PR created\n' "$WORKTREE" >&2
        return 1
    }
    printf '採用した変更は無い。origin/main に無い週の Failure Pattern の再発率の記録が %s 週分たまったので、記録だけを commit した。\n' \
        "$RATE_RECORDS_COMMITTED" >"$PR_BODY"
    append_rates_section
    append_detection_section
    git -C "$WORKTREE" push --quiet origin "HEAD:refs/heads/$BRANCH" || {
        printf 'harness-weekly: push of %s failed; no PR created. To publish by hand: git -C %s push origin %s, then gh pr create --draft --base main --head %s --body-file %s\n' \
            "$BRANCH" "$REPO" "$BRANCH" "$BRANCH" "$PR_BODY" >&2
        return 1
    }
    url=$(cd "$WORKTREE" && gh pr create --draft --base main --head "$BRANCH" \
        --title "harness: 週次の指標 $REVIEW_DATE" --body-file "$PR_BODY") || {
        printf 'harness-weekly: pushed %s but gh pr create failed; open the PR by hand with gh pr create --draft --base main --head %s --body-file %s\n' \
            "$BRANCH" "$BRANCH" "$PR_BODY" >&2
        return 1
    }
    url=${url##*$'\n'}
    printf 'harness-weekly: opened metrics-only draft PR %s (%s weekly record(s))\n' "$url" "$RATE_RECORDS_COMMITTED"
    rm -f "$PR_BODY" "$REVIEW_RESULT"
    remove_worktree
    git -C "$REPO" branch --quiet -D "$BRANCH" >/dev/null 2>&1 ||
        printf 'harness-weekly: WARN could not delete local branch %s in %s\n' "$BRANCH" "$REPO" >&2
}

# queue が空で選別を省いた週に、記録だけの PR が要るかを確かめて作る。worktree を作る前に、ローカルの
# 記録の件数(origin/main に無い件数の上限)と開いているループの PR で絞る。当日のブランチが origin に
# あれば、その日の PR は作成済みか手で作るのを待っているので作らない
publish_metrics_if_due() {
    local local_count=0 file open_pr remote_status=0 base
    for file in "$LOCAL_RATES_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json; do
        [[ -f "$file" ]] && local_count=$((local_count + 1))
    done
    if [[ "$local_count" -lt "$METRICS_ONLY_WEEKS" ]]; then
        printf 'harness-weekly: at most %s weekly failure rate record(s) not on origin/main; carried over in %s (a metrics-only PR needs %s)\n' \
            "$local_count" "$LOCAL_RATES_DIR" "$METRICS_ONLY_WEEKS"
        return 0
    fi
    open_pr=$(open_loop_pr) || {
        printf 'harness-weekly: WARN listing open loop PRs failed; no metrics-only PR this week\n' >&2
        return 0
    }
    if [[ -n "$open_pr" ]]; then
        printf 'harness-weekly: loop PR %s is open; weekly failure rate records carried over\n' "$open_pr"
        return 0
    fi
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
    if ! metrics_only_due "$base"; then
        remove_worktree
        return 0
    fi
    (cd "$WORKTREE" && pnpm install --frozen-lockfile --prefer-offline) || {
        printf 'harness-weekly: pnpm install failed in %s; no metrics-only PR\n' "$WORKTREE" >&2
        return 1
    }
    publish_metrics_only "$base"
}

# 選別の結果から PR を作る。判定は結果ファイルと commit の数で行い、本文の有無は
# Dropped Change の判定に使わない(本文には採用 0 件の週にも指標などが載りうるため)。
#   - commit 0 件・dropped が空 → 成功。PR は作らない(deploy-only だけの週を含む)。ただし
#     origin/main に無い週の再発率の記録がたまっていれば、記録だけの PR を作る(metrics_only_due)
#   - commit 0 件・dropped が空でない → 失敗(すべてが Dropped Change)
#   - commit 1 件以上 → PR を作る。dropped は queue に残っており、次の選別にかけ直される。
#     origin/main に無い週の再発率の記録を、このスクリプトの commit で足す(commit_rate_records)
# 次はどれも失敗として扱い、heartbeat を書かせない:
#   - commit されていない変更が残った
#   - 結果ファイルが無い、または決めた形でない
#   - commit があるのに本文が無い
#   - 選別の claude の commit が週の再発率の記録($RATES_REPO_DIR)に触れた
#   - push か PR の作成が失敗した
# Deploy-only Fix は、結果ファイルを読めた時点で、未 commit の変更を含むどの失敗の判定よりも
# 先に $DEPLOY_ONLY へ残す。commit 0 件で成功する週は本文を PR にしないので捨てる(採用も
# 陳腐化の修正も無い週の本文は件数と残った陳腐化だけで、次の選別がまた数える)。
# 失敗の経路では worktree・本文・結果ファイルを残す(調べられるように。worktree は次の
# 実行が作り直す)。採用した項目は既に archive に移っているので、push 以降で失敗した run の
# commit は $REPO のローカルブランチ $BRANCH から手で push / PR を作る
publish_review() {
    local base=$1 commits url dropped_count dropped_items touched commit_status=0
    if ! review_result_valid; then
        printf 'harness-weekly: review did not write a valid result file %s (a JSON object with string arrays "dropped" and "deploy_only"); no PR created\n' \
            "$REVIEW_RESULT" >&2
        return 1
    fi
    record_deploy_only || {
        printf 'harness-weekly: failed to record deploy-only fixes from %s in %s\n' "$REVIEW_RESULT" "$DEPLOY_ONLY" >&2
        return 1
    }
    if [[ -n "$(git -C "$WORKTREE" status --porcelain)" ]]; then
        printf 'harness-weekly: review left uncommitted changes in %s; no PR created\n' "$WORKTREE" >&2
        return 1
    fi
    commits=$(git -C "$WORKTREE" rev-list --count "$base..HEAD") || return 1
    dropped_count=$(result_count dropped) || return 1
    if [[ "$commits" -eq 0 ]]; then
        if [[ "$dropped_count" -gt 0 ]]; then
            dropped_items=$(result_items dropped) || return 1
            printf 'harness-weekly: review dropped %s change(s) and committed nothing (a commit hook or lint failed; the entries stay in the queue); no PR created. Dropped (see %s):\n%s\n' \
                "$dropped_count" "$REVIEW_RESULT" "$dropped_items" >&2
            return 1
        fi
        if metrics_only_due "$base"; then
            printf 'harness-weekly: review committed no changes; opening a metrics-only PR\n'
            publish_metrics_only "$base"
            return
        fi
        printf 'harness-weekly: review committed no changes; no PR created\n'
        rm -f "$PR_BODY" "$REVIEW_RESULT"
        remove_worktree
        return 0
    fi
    if [[ ! -s "$PR_BODY" ]]; then
        printf 'harness-weekly: review made %s commit(s) but wrote no PR body; no PR created\n' "$commits" >&2
        return 1
    fi
    touched=$(git -C "$WORKTREE" diff --name-only "$base" HEAD -- "$RATES_REPO_DIR") || return 1
    if [[ -n "$touched" ]]; then
        printf 'harness-weekly: review commits touched %s (only this job writes the weekly failure rate records); no PR created\n' \
            "$RATES_REPO_DIR" >&2
        return 1
    fi
    result_sections >>"$PR_BODY" || return 1
    append_detection_section
    append_rates_section
    append_eval_section
    # 純増は選別の commit だけで数える(記録の commit を混ぜると、ルールの肥大の数字に記録の行が入る)
    net_change_section "$base" >>"$PR_BODY" || return 1
    commit_rate_records "$base" || commit_status=$?
    if [[ "$commit_status" -eq 2 ]]; then
        # 書き換えられた記録を正として持ち越さないよう、PR を作らずに失敗させて人に見せる
        printf 'harness-weekly: no PR created; check %s by hand\n' "$LOCAL_RATES_DIR" >&2
        return 1
    elif [[ "$commit_status" -eq 0 ]]; then
        [[ "$RATE_RECORDS_COMMITTED" -eq 0 ]] ||
            printf 'harness-weekly: committed %s weekly failure rate record(s)\n' "$RATE_RECORDS_COMMITTED"
    else
        # 記録は ~/.claude/harness に残り、次の PR がまとめて足す。採用の公開は止めない
        printf 'harness-weekly: WARN failed to commit the weekly failure rate records; they stay in %s for the next PR\n' \
            "$LOCAL_RATES_DIR" >&2
        git -C "$WORKTREE" reset --quiet --hard HEAD || return 1
        git -C "$WORKTREE" clean --quiet -fd -- "$RATES_REPO_DIR" || return 1
    fi
    git -C "$WORKTREE" push --quiet origin "HEAD:refs/heads/$BRANCH" || {
        printf 'harness-weekly: push of %s failed; no PR created. To publish by hand: git -C %s push origin %s, then gh pr create --draft --base main --head %s --body-file %s\n' \
            "$BRANCH" "$REPO" "$BRANCH" "$BRANCH" "$PR_BODY" >&2
        return 1
    }
    url=$(cd "$WORKTREE" && gh pr create --draft --base main --head "$BRANCH" \
        --title "harness: 週次レビュー $REVIEW_DATE" --body-file "$PR_BODY") || {
        printf 'harness-weekly: pushed %s but gh pr create failed; open the PR by hand with gh pr create --draft --base main --head %s --body-file %s (verdicts in %s still say %s)\n' \
            "$BRANCH" "$BRANCH" "$PR_BODY" "$ARCHIVE" "$ADOPTED_MARK" >&2
        return 1
    }
    url=${url##*$'\n'}
    printf 'harness-weekly: opened draft PR %s (%s commit(s))\n' "$url" "$commits"
    rm -f "$PR_BODY" "$REVIEW_RESULT"
    record_pr_url "$url"
    remove_worktree
    # ブランチは origin にあるので、ローカルの分は消す(残すと週ごとに溜まる)
    git -C "$REPO" branch --quiet -D "$BRANCH" >/dev/null 2>&1 ||
        printf 'harness-weekly: WARN could not delete local branch %s in %s\n' "$BRANCH" "$REPO" >&2
}

# 選別の claude が失敗した(予算切れを含む)run の後始末の案内。claude は commit や
# archive への移動を済ませてから失敗しうるので、残った commit の場所と手で PR を作る手順を
# ログに出す。worktree は残す(次の実行が作り直すが、prepare_worktree は origin/main に無い
# commit を持つ当日のブランチを作り直さない)。claude は結果ファイルを書いてから失敗しうる
# ので、結果ファイルが決めた形なら Deploy-only Fix はここでも $DEPLOY_ONLY に残す(結果
# ファイルは日付付きで、次の週の run は読まない)。結果ファイルは run の前に消してあるので、
# ここで読むのはこの run の claude が書いたものだけ。commit が残っていれば、手で作る PR の
# 本文にも Dropped Change と Deploy-only Fix の節を足す(claude には本文に書かせないため、
# 足さないと落とした変更の一覧が結果ファイルにしか残らない)
report_failed_review() {
    local base=$1 commits result_ok=0
    if [[ -f "$REVIEW_RESULT" ]] && review_result_valid; then
        result_ok=1
        record_deploy_only ||
            printf 'harness-weekly: failed to record deploy-only fixes from %s in %s\n' "$REVIEW_RESULT" "$DEPLOY_ONLY" >&2
    fi
    commits=$(git -C "$WORKTREE" rev-list --count "$base..HEAD" 2>/dev/null || printf '?')
    if [[ "$commits" == "0" ]]; then
        printf 'harness-weekly: review failed before committing; worktree %s kept; verdicts already moved to %s stay there\n' \
            "$WORKTREE" "$ARCHIVE" >&2
        return 0
    fi
    if [[ "$result_ok" -eq 1 ]]; then
        result_sections >>"$PR_BODY" ||
            printf 'harness-weekly: failed to add the sections from %s to %s\n' "$REVIEW_RESULT" "$PR_BODY" >&2
    fi
    append_detection_section
    append_rates_section
    printf 'harness-weekly: review failed after %s commit(s) on local branch %s (worktree %s, PR body %s); verdicts in %s may already say %s. To publish by hand: git -C %s push origin %s, then gh pr create --draft --base main --head %s --body-file %s\n' \
        "$commits" "$BRANCH" "$WORKTREE" "$PR_BODY" "$ARCHIVE" "$ADOPTED_MARK" "$REPO" "$BRANCH" "$BRANCH" "$PR_BODY" >&2
}

# 成功した run の締め。前の run が採用を記録したまま PR にできなかった(push・PR の作成・
# 選別の claude のどれかが失敗した)ことを、次の週の run が見落とさないよう、heartbeat を
# 書く前に判定の記録を確かめる。選別は採用を adopted (<ループのブランチ> run <id>) と記録し、PR を
# 作れた run だけが自分の記録を PR の URL に置き換える(record_pr_url)。手動の /harness-review は最初から
# adopted (PR <url>) と書くので一致しない。ローカルの harness/review-* ブランチの有無で
# 判定しないのは、手動の手順もローカルにブランチを残すため。
# 残っていれば heartbeat を書かずに失敗し、briefing の古さの警告で人に知らせる。その週の抽出と
# 選別は済ませてから確かめる(失敗させても週の処理は止めない)
finish_run() {
    local leftovers="" status=0
    if [[ -f "$ARCHIVE" ]]; then
        leftovers=$(grep -oE 'adopted \(harness/review-[^)]*\)' "$ARCHIVE") || status=$?
        if [[ "$status" -gt 1 ]]; then
            printf 'harness-weekly: failed to read %s (grep exit %s); heartbeat not updated\n' "$ARCHIVE" "$status" >&2
            return 1
        fi
    fi
    if [[ -n "$leftovers" ]]; then
        printf 'harness-weekly: %s still has verdicts that never became a PR: %s. Publish each branch from %s by hand (git push origin <branch>, then gh pr create --draft --base main --head <branch>) and replace the verdict with "adopted (PR <url>)", or move the entries back to queue.md; heartbeat not updated\n' \
            "$ARCHIVE" "$(printf '%s\n' "$leftovers" | sort -u | tr '\n' ' ')" "$REPO" >&2
        return 1
    fi
    if [[ -n "$RATE_RECORD_ERROR" ]]; then
        printf 'harness-weekly: this week has no failure rate record (%s); heartbeat not updated\n' "$RATE_RECORD_ERROR" >&2
        return 1
    fi
    write_heartbeat
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
# 抽出と選別の claude を起動する前に、ローカルの週の記録のハッシュを取る(commit_rate_records が比べる)
RATE_RECORD_DIGESTS=$(rate_record_digests) || {
    printf 'harness-weekly: failed to hash the weekly failure rate records in %s\n' "$LOCAL_RATES_DIR" >&2
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
    run_claude reflect "$SESSION_ID" "$REFLECT_BUDGET_USD" "$PROMPT" || exit 1
fi

QUEUE_ENTRIES=$(count_queue)
if [[ "$QUEUE_ENTRIES" -eq 0 ]]; then
    printf 'harness-weekly: queue is empty; skipped review\n'
    publish_metrics_if_due || exit 1
    finish_run || exit 1
    exit 0
fi

# 当日のブランチが origin にあれば、その日のループの PR は作成済みか、push 後に PR の作成が
# 失敗している(その run のログが手で開くよう促している)。作り直したブランチは
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
        printf 'harness-weekly: %s exists on origin but has no PR; open it by hand (gh pr create --draft --base main --head %s --body-file %s); skipped review\n' \
            "$BRANCH" "$BRANCH" "$PR_BODY" >&2
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
# commit フック(prek)と just lint が node_modules を要るので、claude の前に入れる。
# claude に入れさせないのは、失敗したときに予算を使って直そうとさせないため
(cd "$WORKTREE" && pnpm install --frozen-lockfile --prefer-offline) || {
    printf 'harness-weekly: pnpm install failed in %s; skipped review\n' "$WORKTREE" >&2
    exit 1
}

# 手順は harness-review スキルのまま使い、手動の /harness-review と同じ queue と判定の
# 記録(queue-archive.md・state.json)を更新させる。変えるのは、作業場所と、push と PR を
# このスクリプトが行う点だけ。節は番号ではなく見出しで指す(番号は SKILL.md の変更で黙ってずれる)
REVIEW_PROMPT="This is the unattended weekly harness job (no human is present, and this session itself is not an input).
Use the harness-review skill, following its rules, with these changes:
- Your working directory is a git worktree of the chezmoi source repo, on branch ${BRANCH}, freshly created from origin/main with dependencies installed. Make every repository change here. Do not cd to the chezmoi source path or any other checkout.
- Skip \"Reflect over pending sessions\"; this job already ran it.
- Never run chezmoi apply (it would deploy the main source, not this branch, with no human present). List a deploy-only fix (one that a commit cannot fix and that takes effect only when a human applies it) in the result file instead.
- In \"Implement and open ONE PR\": do not create or switch branches, do not push, and do not open a PR; this job does those after you finish. Commit on the current branch and leave the working tree clean: one commit per adopted change, with its queue title in the subject, and one commit per staleness fix, with what it fixes in the subject (this job counts the additions and deletions of each change from its commit). Fold fixes for a failing commit hook or just lint into that change's commit instead of adding a separate commit. Never use --no-verify and do not install dependencies; if a commit hook or just lint fails and you cannot fix the change, drop that change, leave its entry in queue.md (do not move it to the archive; the failure may come from the environment, so a later run triages it again), and list it in the result file with the failing hook or lint check.
- Always write the result file ${REVIEW_RESULT} before you finish, even if nothing happened: a JSON object {\"dropped\": [...], \"deploy_only\": [...]} whose elements are one-line strings (in Japanese). In \"dropped\", put each dropped change with its queue title and the failing hook or lint check; in \"deploy_only\", each deploy-only fix with what to apply and why. Use empty arrays when there are none. This job decides whether the run failed from this file, not from the PR body.
- Write the PR body (in Japanese) to ${PR_BODY}: for each adopted change, its queue title, the files it changes, and why it was adopted; for each staleness fix, the files and why; then the rejected and handoff counts and the remaining staleness findings. Do not write line counts, failure detection counts, failure pattern rates, rule effects, dropped changes or deploy-only fixes in the PR body; this job appends them from the diff, its detection and rate records, the evaluation and the result file. Never change files under ${RATES_REPO_DIR}; this job commits them. If nothing is adopted and nothing is stale, make no commits.
- For every adopted change, write an Eval Case request to ${EVAL_REQUESTS} as described in the skill's \"Eval Case requests\" section (Write tool only; this job runs the evaluation and appends the effect to the PR body). Do not run the evaluation yourself.
- In \"Bookkeeping\", record each adopted verdict as \"${ADOPTED_MARK}\" exactly; this job replaces it with the PR URL.
${WRITE_RULE}
- Ignore suggestions from SessionStart hook output. Use no skill other than harness-review.
- Finish with a one-line summary: entries adopted, rejected, handed off."
(cd "$WORKTREE" && run_claude review "$REVIEW_SESSION_ID" "$REVIEW_BUDGET_USD" "$REVIEW_PROMPT") || {
    report_failed_review "$REVIEW_BASE"
    exit 1
}
publish_review "$REVIEW_BASE" || exit 1

finish_run || exit 1
