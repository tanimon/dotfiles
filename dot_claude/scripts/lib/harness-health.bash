#!/usr/bin/env bash
# 自己改善ループの健全性の判定。source 専用。set は呼び出し側に従う(set -euo pipefail 下で動く)。
#
# 判定の正本はここだけで、briefing(SessionStart)と doctor は level を表示に写すだけにする。
# 同じ状態は両方で同じ level になる。表示の形(1 行の状態か、PASS/FAIL の一覧と exit code か)は
# 呼び出し側が決める。
#
# 読み込むのは briefing と doctor と週次ジョブ(harness-weekly.sh。停止を Issue で知らせる判定に
# 使う)。reflect-trigger(SessionEnd)は読み込まない: lib が壊れて止まると、セッションの記録が
# 黙って失われる(briefing なら黙ること自体が合図になる)。
# heartbeat を書くのは週次ジョブで、書く側のファイル名と中身(epoch の数値)の知識はジョブにもある。
# 一致は test/harness-weekly.bats が検査する。
# 週次ジョブが読み込むので、この lib は Evaluator のパス(scripts/evaluator-paths.txt)に載せてある。
#
# Interface: harness_health_dir / harness_health_bootstrap / harness_health_weekly /
# harness_health_heartbeat_days / harness_health_missed_run_days / harness_health_stale_prs /
# harness_health_unpublished_loop_branches。
# パスは呼び出しのたびに $HOME から作る(source した後に HOME が変わっても追従するため)。
# 関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、失敗は明示的に返す。

# 週次ジョブの間隔(7 日)に、スリープ明けの追いつき実行の分の猶予を足す
HARNESS_HEALTH_WEEKLY_STALE_DAYS=8
# ループの PR を放置とみなす日数(ADR 0012 の Consequences。2 週)
HARNESS_HEALTH_STALE_PR_DAYS=14
# $(id -u) はユーザーが貼り付けて実行するコマンドの一部なので展開しない
# shellcheck disable=SC2016
HARNESS_HEALTH_WEEKLY_REMEDY='check ~/Library/Logs/harness-weekly.log, then run launchctl kickstart gui/$(id -u)/local.dotfiles.harness-weekly from a terminal'

# 状態ディレクトリのパスを出す。
harness_health_dir() {
    printf '%s\n' "$HOME/.claude/harness"
}

# 状態ディレクトリと state.json / pending.jsonl / queue.md を、無ければ作る(新しいマシンや手で消した後)。
# 既にあるファイルには触れない。
harness_health_bootstrap() {
    local dir
    dir=$(harness_health_dir) || return 1
    mkdir -p "$dir" || return 1
    if [[ ! -f "$dir/state.json" ]]; then
        printf '{"version":1}\n' >"$dir/state.json" || return 1
    fi
    if [[ ! -f "$dir/pending.jsonl" ]]; then
        : >"$dir/pending.jsonl" || return 1
    fi
    if [[ ! -f "$dir/queue.md" ]]; then
        printf '# Harness improvement queue\n\nAppended by /harness-reflect; processed by /harness-review.\n' \
            >"$dir/queue.md" || return 1
    fi
}

# 最後に成功した週次ジョブ(heartbeat)からの経過日数を出す。heartbeat が無いか数値でなければ
# 何も出さずに 1 を返す。
harness_health_heartbeat_days() {
    local dir heartbeat
    dir=$(harness_health_dir) || return 1
    [[ -f "$dir/weekly-heartbeat" ]] || return 1
    heartbeat=$(tr -d '[:space:]' <"$dir/weekly-heartbeat" 2>/dev/null) || return 1
    [[ "$heartbeat" =~ ^[0-9]+$ ]] || return 1
    # 10# を付けないと、先頭 0 付きの値(0899 など)が 8 進数として解釈されて算術展開が落ちる
    printf '%s\n' "$((($(date +%s) - 10#$heartbeat) / 86400))"
}

# 週次ジョブ(ADR 0012)の健全性を判定し、stdout に次の行を出す(区切りは TAB、文言に TAB は含めない)。
#   <level>\t<message>   level は ok / warn / fail。message は fail と warn なら対処を含む
#   summary\t<text>      briefing が OK の行に出す値(`weekly: 3d ago`)。plist があるときだけ
# 何も出さないのは、launchd の無いマシンで plist も無いとき(ジョブを動かす前提が無い)。
# 判定できたら 0 を返す(level が fail でも 0)。
harness_health_weekly() {
    local dir plist entry heartbeat_file days remedy
    dir=$(harness_health_dir) || return 1
    plist="$HOME/Library/LaunchAgents/local.dotfiles.harness-weekly.plist"
    entry="$HOME/.claude/scripts/harness-weekly.sh"
    heartbeat_file="$dir/weekly-heartbeat"
    remedy=$HARNESS_HEALTH_WEEKLY_REMEDY

    # briefing のフックと plist はどちらも chezmoi apply で置かれるので、macOS で plist だけが
    # 無いのは異常として扱う
    if [[ ! -f "$plist" ]]; then
        if [[ "$(uname -s)" == Darwin ]]; then
            printf "warn\tweekly job not installed (%s missing) — run 'chezmoi apply'\n" "$plist"
        fi
        return 0
    fi

    if [[ -x "$entry" ]]; then
        printf 'ok\tharness-weekly.sh deployed and executable\n'
    else
        printf "fail\tharness-weekly.sh is not deployed or not executable — run 'chezmoi apply'\n"
    fi

    if [[ -f "$heartbeat_file" ]]; then
        if ! days=$(harness_health_heartbeat_days); then
            printf 'fail\tweekly-heartbeat is not a number — delete %s and %s\n' "$heartbeat_file" "$remedy"
            return 0
        fi
        if [[ "$days" -ge "$HARNESS_HEALTH_WEEKLY_STALE_DAYS" ]]; then
            printf 'fail\tweekly job last succeeded %sd ago — %s\n' "$days" "$remedy"
        else
            printf 'ok\tweekly job last succeeded %sd ago\n' "$days"
        fi
        printf 'summary\tweekly: %sd ago\n' "$days"
        return 0
    fi

    # heartbeat が無いのは、plist を置いてから 1 周期経っていなければ初回がまだ来ていないだけ、
    # 経っていれば一度も成功していない。find の -mtime +N は「N+1 日以上前」なので 1 引く
    # (heartbeat 側の -ge と揃える)
    if [[ -n "$(find "$plist" -mtime +"$((HARNESS_HEALTH_WEEKLY_STALE_DAYS - 1))" 2>/dev/null)" ]]; then
        printf 'fail\tweekly job has never succeeded since it was installed — %s\n' "$remedy"
    else
        printf 'ok\tweekly job has not run yet (installed less than %sd ago)\n' "$HARNESS_HEALTH_WEEKLY_STALE_DAYS"
    fi
    printf 'summary\tweekly: never\n'
}

# 前の成功(heartbeat)が 1 周期より古ければ、その経過日数を出す。週次ジョブが起動時(heartbeat を
# 書き換える前)に呼び、走らなかった・成功しなかった週を Issue で知らせる。ジョブは走らなければ
# 自分の停止を知らせられないので、知らせるのは次に走った run になる。launchd が起動しなくなった
# ままなら briefing の表示だけが残る。heartbeat が無い・数値でないときは何も出さない(初回の run か、
# harness_health_weekly が別に fail にする)。
harness_health_missed_run_days() {
    local days
    days=$(harness_health_heartbeat_days) || return 0
    if [[ "$days" -ge "$HARNESS_HEALTH_WEEKLY_STALE_DAYS" ]]; then
        printf '%s\n' "$days"
    fi
}

# 開いている PR の一覧(stdin。`gh pr list --json number,url,headRefName,createdAt` の配列)から、
# ブランチ名が <prefix> で始まり、作られてから HARNESS_HEALTH_STALE_PR_DAYS 日以上経ったものを
# `<番号>\t<URL>\t<経過日数>` で出す。prefix は引数で受ける(正本は scripts/check-evaluator-guard.sh)。
# 一覧を読めなければ失敗を返す。
harness_health_stale_prs() { # <現在の epoch> <ブランチの prefix>
    jq -r --argjson now "$1" --arg prefix "$2" --argjson limit "$HARNESS_HEALTH_STALE_PR_DAYS" '
        .[] | select(.headRefName | startswith($prefix))
        | ((($now - (.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601)) / 86400) | floor) as $days
        | select($days >= $limit)
        | "\(.number)\t\(.url)\t\($days)"'
}

# <repo> のローカルブランチのうち、名前が <prefix><日付>(YYYY-MM-DD)で、その日付が <基準日> 以前で、
# origin/main に無い commit を持つものを `<ブランチ>\t<commit 数>` で出す。基準日より新しいブランチ
# (その日の run や、手動の review がまだ公開していないもの)と、名前が日付で終わらないものは見ない。
# PR になったかは見ない(呼び出し側が gh で確かめる)。squash マージされたブランチも commit は
# origin/main に無いままなので、ここでの一致だけでは「PR にならなかった」とは言えない。
# origin/main は最後に fetch した時点のもの。origin/main が無ければ判定できないので失敗を返す。
harness_health_unpublished_loop_branches() { # <repo> <prefix> <基準日 YYYY-MM-DD>
    local repo=$1 prefix=$2 cutoff=$3 branches branch day count
    git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null || return 1
    branches=$(git -C "$repo" for-each-ref --format='%(refname:short)' "refs/heads/$prefix*") || return 1
    while IFS= read -r branch; do
        day=${branch#"$prefix"}
        [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
        # 同じ桁数の YYYY-MM-DD は文字列の順が日付の順になる
        [[ ! "$day" > "$cutoff" ]] || continue
        count=$(git -C "$repo" rev-list --count "refs/remotes/origin/main..refs/heads/$branch") || return 1
        if [[ "$count" -gt 0 ]]; then
            printf '%s\t%s\n' "$branch" "$count"
        fi
    done <<<"$branches"
}
