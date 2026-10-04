#!/usr/bin/env bash
# 自己改善ループの健全性の判定。source 専用。set は呼び出し側に従う(set -euo pipefail 下で動く)。
#
# 判定の正本はここだけで、briefing(SessionStart)と doctor は level を表示に写すだけにする。
# 同じ状態は両方で同じ level になる。表示の形(1 行の状態か、PASS/FAIL の一覧と exit code か)は
# 呼び出し側が決める。
#
# 読み込むのは briefing と doctor だけ。reflect-trigger(SessionEnd)は読み込まない: lib が壊れて
# 止まると、セッションの記録が黙って失われる(briefing なら黙ること自体が合図になる)。
# heartbeat を書く週次ジョブ(harness-weekly.sh)も読み込まないので、heartbeat のファイル名と
# 中身(epoch の数値)の知識はジョブとここの 2 か所にある。一致は test/harness-weekly.bats が検査する。
#
# Interface: harness_health_dir / harness_health_bootstrap / harness_health_weekly。
# パスは呼び出しのたびに $HOME から作る(source した後に HOME が変わっても追従するため)。
# 関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、失敗は明示的に返す。

# 週次ジョブの間隔(7 日)に、スリープ明けの追いつき実行の分の猶予を足す
HARNESS_HEALTH_WEEKLY_STALE_DAYS=8
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

# 週次ジョブ(ADR 0012)の健全性を判定し、stdout に次の行を出す(区切りは TAB、文言に TAB は含めない)。
#   <level>\t<message>   level は ok / warn / fail。message は fail と warn なら対処を含む
#   summary\t<text>      briefing が OK の行に出す値(`weekly: 3d ago`)。plist があるときだけ
# 何も出さないのは、launchd の無いマシンで plist も無いとき(ジョブを動かす前提が無い)。
# 判定できたら 0 を返す(level が fail でも 0)。
harness_health_weekly() {
    local dir plist entry heartbeat_file heartbeat days remedy
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
        heartbeat=$(tr -d '[:space:]' <"$heartbeat_file" 2>/dev/null) || heartbeat=""
        if [[ ! "$heartbeat" =~ ^[0-9]+$ ]]; then
            printf 'fail\tweekly-heartbeat is not a number — delete %s and %s\n' "$heartbeat_file" "$remedy"
            return 0
        fi
        days=$((($(date +%s) - heartbeat) / 86400))
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
