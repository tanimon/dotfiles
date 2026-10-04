#!/usr/bin/env bash
# 自己改善ループの週次ジョブの入口(ADR 0012)。launchd が週 1 回、nono の内側で起動する
# (plist の ProgramArguments が `nono run … -- /bin/bash <このスクリプト>`)。
#
# 工程は 2 つで、それぞれ headless の `claude -p` を 1 回ずつ起動する。
#   1. 抽出: pending のセッションに対して harness-reflect スキルを行う(pending が空なら省く)
#   2. 選別: queue に項目があれば、chezmoi の source リポジトリの使い捨ての worktree で
#      harness-review スキルを行い、採用した変更を commit させる(queue が空なら省く)
# 採用した commit があれば、push と `gh pr create --draft` はこのスクリプトが固定の引数で
# 行う。claude にさせないのは、headless では PreToolUse フックの ask が拒否になり、
# git push guard が変数を含む push に ask を返すため(#429)。
# 両方の工程が成功し、判定の記録に PR にならなかった採用が残っていなければ(finish_run)
# heartbeat(最後に成功した時刻)を書き、briefing と doctor がその古さを表示する。
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

SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
REVIEW_SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
# 記録は起動より前に行い、直近の分だけ残す
printf '%s\n%s\n' "$SESSION_ID" "$REVIEW_SESSION_ID" >>"$JOB_SESSIONS"
tail -n 20 "$JOB_SESSIONS" >"$JOB_SESSIONS.tmp" && mv "$JOB_SESSIONS.tmp" "$JOB_SESSIONS"
strip_job_sessions || {
    rm -rf "$LOCK"
    exit 1
}
PENDING_BEFORE=$(count_pending)
printf 'harness-weekly: start %s session=%s pending=%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SESSION_ID" "$PENDING_BEFORE"
cleanup() {
    local status=$?
    strip_job_sessions || true
    rm -rf "$LOCK"
    printf 'harness-weekly: end %s session=%s exit=%s pending=%s->%s\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$SESSION_ID" "$status" "$PENDING_BEFORE" "$(count_pending)"
}
trap cleanup EXIT
export HARNESS_DISABLE=1

QUEUE="$HARNESS_DIR/queue.md"
ARCHIVE="$HARNESS_DIR/queue-archive.md"
WORKTREE="$HARNESS_DIR/review-worktree"
REVIEW_DATE=$(date +%Y-%m-%d)
# 日付を入れるのは、失敗した run の本文(落とした変更の理由)を次の週の run が消さないため。
# PR を作れたら消す
PR_BODY="$HARNESS_DIR/review-pr-body-$REVIEW_DATE.md"
BRANCH="harness/review-$REVIEW_DATE"
# 選別に書かせる採用の記録。run ごとの印(選別の session id)を入れるのは、同じ日の前の run が
# 失敗して残した adopted (<ブランチ> …) を、今回の PR の URL で上書きしないため(record_pr_url)。
# 前の run の記録は残り、finish_run が知らせる
ADOPTED_MARK="adopted ($BRANCH run $REVIEW_SESSION_ID)"

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
WRITE_RULE="- Write text you compose (queue entries, rule and doc text, the PR body) only with the Write and Edit tools, never with heredocs, echo or printf: in this headless run a hook that asks for confirmation denies the command. Redirecting a command's output to a temp file and moving it into place (the skills' Bookkeeping for pending.jsonl and state.json) is fine; never rewrite those files from a copy you read earlier."

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

# 選別の結果から PR を作る。commit も本文も無ければ(採用も陳腐化の修正も無い週)PR を
# 作らずに成功する。次はどれも失敗として扱い、heartbeat を書かせない:
#   - commit されていない変更が残った
#   - 本文があるのに commit が無い(commit フックの失敗を疑う。落とした変更があれば
#     本文を必ず書かせているので、全部落ちた run を「採用なし」と取り違えない。deploy-only の
#     修正だけの週は、本文ではなく claude の最終の要約に書かせて、この判定と区別する)
#   - commit があるのに本文が無い
#   - push か PR の作成が失敗した
# 失敗の経路では worktree と本文($PR_BODY)を残す(調べられるように。worktree は次の
# 実行が作り直す)。採用した項目は既に archive に移っているので、push 以降で失敗した run の
# commit は $REPO のローカルブランチ $BRANCH から手で push / PR を作る
publish_review() {
    local base=$1 commits url
    if [[ -n "$(git -C "$WORKTREE" status --porcelain)" ]]; then
        printf 'harness-weekly: review left uncommitted changes in %s; no PR created\n' "$WORKTREE" >&2
        return 1
    fi
    commits=$(git -C "$WORKTREE" rev-list --count "$base..HEAD") || return 1
    if [[ "$commits" -eq 0 ]]; then
        if [[ -s "$PR_BODY" ]]; then
            printf 'harness-weekly: review wrote %s but made no commits (a commit hook may have failed; dropped changes stay in the queue. If it only reports deploy-only fixes, apply them by hand and delete it); no PR created\n' "$PR_BODY" >&2
            return 1
        fi
        printf 'harness-weekly: review committed no changes; no PR created\n'
        remove_worktree
        return 0
    fi
    if [[ ! -s "$PR_BODY" ]]; then
        printf 'harness-weekly: review made %s commit(s) but wrote no PR body; no PR created\n' "$commits" >&2
        return 1
    fi
    net_change_section "$base" >>"$PR_BODY" || return 1
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
    rm -f "$PR_BODY"
    record_pr_url "$url"
    remove_worktree
    # ブランチは origin にあるので、ローカルの分は消す(残すと週ごとに溜まる)
    git -C "$REPO" branch --quiet -D "$BRANCH" >/dev/null 2>&1 ||
        printf 'harness-weekly: WARN could not delete local branch %s in %s\n' "$BRANCH" "$REPO" >&2
}

# 選別の claude が失敗した(予算切れを含む)run の後始末の案内。claude は commit や
# archive への移動を済ませてから失敗しうるので、残った commit の場所と手で PR を作る手順を
# ログに出す。worktree は残す(次の実行が作り直すが、prepare_worktree は origin/main に無い
# commit を持つ当日のブランチを作り直さない)
report_failed_review() {
    local base=$1 commits
    commits=$(git -C "$WORKTREE" rev-list --count "$base..HEAD" 2>/dev/null || printf '?')
    if [[ "$commits" == "0" ]]; then
        printf 'harness-weekly: review failed before committing; worktree %s kept; verdicts already moved to %s stay there\n' \
            "$WORKTREE" "$ARCHIVE" >&2
        return 0
    fi
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
    write_heartbeat
}

# 処理対象が無い工程は claude を起動しない。起動するだけで固定の文脈分の費用がかかるため。
# 両方の工程を省いた週も、finish_run の確認を通れば heartbeat は書く(「ジョブが健全に
# 回った」の意味。その週は claude と認証の経路を通らない)
if [[ "$PENDING_BEFORE" -eq 0 ]]; then
    printf 'harness-weekly: pending is empty; skipped reflect\n'
else
    # 1 回で扱うセッション数に上限を置き、予算(--max-budget-usd)は歯止めに回す。
    # 予算だけに頼ると、溜まった分を 1 回で捌けない週は毎回予算切れで失敗し、
    # 進んでいても heartbeat が書かれない。
    # セッションごとに「queue へ追記 → pending から外す」を済ませてから次へ進ませるのは、
    # 途中で止まっても失うのが高々 1 セッション分で、queue に重複を作らないため
    PROMPT="This is the unattended weekly harness job (no human is present, and this session itself is not an input).
Use the harness-reflect skill on the entries in ~/.claude/harness/pending.jsonl, following its rules, with these changes:
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
# 前回の本文を消すのは prepare_worktree の判定を通った後。手で publish すべき commit が
# 残っている間は、その PR に使う本文を残す
rm -f "$PR_BODY"
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
- Never run chezmoi apply (it would deploy the main source, not this branch, with no human present). Report a deploy-only fix in the PR body instead. If you commit nothing, put deploy-only fixes in your final summary instead and do not write the PR body for them (this job reads a PR body without commits as dropped changes).
- In \"Implement and open ONE PR\": do not create or switch branches, do not push, and do not open a PR; this job does those after you finish. Commit on the current branch and leave the working tree clean: one commit per adopted change, with its queue title in the subject, and one commit per staleness fix, with what it fixes in the subject (this job counts the additions and deletions of each change from its commit). Fold fixes for a failing commit hook or just lint into that change's commit instead of adding a separate commit. Never use --no-verify and do not install dependencies; if a commit hook or just lint fails and you cannot fix the change, drop that change, leave its entry in queue.md (do not move it to the archive; the failure may come from the environment, so a later run triages it again), and list it in the PR body with the failing hook or lint check. Whenever a change was dropped, always write the PR body, even if nothing was committed.
- Write the PR body (in Japanese) to ${PR_BODY}: for each adopted change, its queue title, the files it changes, and why it was adopted; for each staleness fix, the files and why; then the rejected and handoff counts and the remaining staleness findings. Do not write line counts; this job appends the net additions and deletions. If nothing is adopted and nothing is stale, make no commits and do not create that file.
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
