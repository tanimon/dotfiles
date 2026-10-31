#!/usr/bin/env bash
# 週次ジョブ(harness-weekly.sh)の Loop Stall(GLOSSARY.md)の module。source 専用。set は呼び出し側に従う
# (set -euo pipefail 下で動く)。
#
# Loop Stall を見つけて知らせる。知らせるのは 2 種類で、タイトルが重複を避ける鍵なので PR ごと・ブランチごとに分ける:
# - 放置された Loop PR: ループの PR が _HARNESS_LOOP_STALLS_STALE_PR_DAYS 日以上開いたまま(PR ごと)
# - PR にならないループのブランチ: PR にならないまま origin/main に無い commit を持つ、7 日以上前の日付のループのブランチ
#   (ブランチごと)。採用の記録が残る run は Loop PR の module の入口の最後の確認が失敗させ、失敗の Issue が知らせるので、ここでは
#   知らせない。陳腐化の修正だけの commit は記録を残さないので、この判定でしか見つからない。PR があれば(手動の review が
#   残したブランチや squash マージ)知らせない
# 週次ジョブ自身の停止(この run の失敗、前の週に成功しなかったこと)は Loop Stall ではないので、週次ジョブが知らせる。
#
# 持つもの: 2 種類の判定、GitHub への問い合わせ(開いている PR の一覧と、ブランチごとの PR の有無)、Verdict の CLI での
# 採用の確認と、確かめられなかったときの本文の注記(Integrity Snapshot の予約コードもここで受ける)、Issue のタイトルと本文。
# 手で公開するコマンドの綴りは Loop PR の module(harness-loop-pr.bash)の綴りの関数から取り、ここには写さない。
# Issue を送る処理(タイトルでの重複の回避)は持たず、呼び出し元から送る関数を受け取る。lib を読めずに止まった run でも
# 失敗の Issue を作るため、送る処理は週次ジョブの入口スクリプトにだけ置く。
#
# 前提: Integrity Snapshot の lib(harness-integrity.bash)と Loop PR の module がこの順に読み込まれていること。どの run で
# 呼ばれるかの正本は週次ジョブの report_stops のコメント。メモリに載った後は claude がファイルを書き換えてもその run に効かない
# ので、Integrity Snapshot の一覧には載せない。週次ジョブが読み込むので、この lib は Guarded Path(scripts/guarded-paths.txt)に
# 載せてある。
# interface を引数 3 つに保つため、ほかの入力はこの lib の中で決める:
# - Verdict の CLI と判定の記録のパスは、Integrity Snapshot の lib と同じく呼び出しのたびに $HOME から作る(CLI は
#   harness_integrity_executables の行と一致しなければ実行されない)
# - Issue の本文に書くリポジトリのパスは、$HOME の下なら ~ で書く(ローカルアカウント名を公開リポジトリに出さない)
# - 時刻と、ループのブランチを見る基準日(今日の 7 日前)は date から取る
#
# 出す行は週次ジョブのログの行なので harness-weekly: で始める。Issue は公開リポジトリに作るので、本文にログの行やエラー文は
# 貼らない(ローカルのパスを含む)。固定の文言・~ で書いたパス・PR の URL と番号・対処のコマンドだけにする。
# 本文の `…` は Markdown のコードスパンで、人が貼り付けて実行するコマンドの一部なので展開しない。
#
# Interface: harness_loop_stalls_report。
# 関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、失敗は明示的に返す。

# Loop PR を放置とみなす日数(ADR 0012 の Consequences。2 週)
_HARNESS_LOOP_STALLS_STALE_PR_DAYS=14

# 開いている PR の一覧(stdin。`gh pr list --json number,url,headRefName,createdAt` の配列)から、
# ブランチ名が <prefix> で始まり、作られてから _HARNESS_LOOP_STALLS_STALE_PR_DAYS 日以上経ったものを
# `<番号>\t<URL>\t<経過日数>` で出す。
# draft かどうかは見ない: draft を外したがマージもクローズもされていない PR も、承認が止まっている
# 間はループの変更が効かない点で同じ放置だから(知らせる本文の対処は両方に合わせて書く)。
# 一覧を読めなければ失敗を返す。
_harness_loop_stalls_stale_prs() { # <現在の epoch> <ブランチの prefix>
    jq -r --argjson now "$1" --arg prefix "$2" --argjson limit "$_HARNESS_LOOP_STALLS_STALE_PR_DAYS" '
        .[] | select(.headRefName | startswith($prefix))
        | ((($now - (.createdAt | sub("\\.[0-9]+"; "") | fromdateiso8601)) / 86400) | floor) as $days
        | select($days >= $limit)
        | "\(.number)\t\(.url)\t\($days)"'
}

# <repo> のローカルブランチのうち、名前が <prefix><日付>(YYYY-MM-DD)で、その日付が <基準日> 以前で、
# origin/main に無い commit を持つものを `<ブランチ>\t<commit 数>` で出す。基準日より新しいブランチ
# (その日の run や、手動の review がまだ公開していないもの)と、名前が日付で終わらないものは見ない。
# PR になったかは見ない(_harness_loop_stalls_report_branches が gh で確かめる)。squash マージされたブランチも commit は
# origin/main に無いままなので、ここでの一致だけでは「PR にならなかった」とは言えない。
# origin/main は最後に fetch した時点のもの。origin/main が無ければ判定できないので失敗を返す。
_harness_loop_stalls_unpublished_branches() { # <repo> <prefix> <基準日 YYYY-MM-DD>
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

# Issue の本文に書くパス。$HOME の下なら ~ で書く
# shellcheck disable=SC2088 # ~ は人が読む表記で、展開しない
_harness_loop_stalls_home_relative() { # <パス>
    case $1 in
    "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;;
    *) printf '%s\n' "$1" ;;
    esac
}

# 放置された Loop PR を知らせる。本文を組み立てられなかったか送れなかったか、現在の時刻か一覧を読めなければ 1 を返す
_harness_loop_stalls_report_prs() { # <repo> <prefix> <送る関数>
    local repo=$1 prefix=$2 send=$3 failed=0 now prs stale number url days body
    # date の失敗を引数の中で消さないよう、先に代入して確かめる
    if ! now=$(date +%s); then
        printf 'harness-weekly: WARN could not read the current time to find loop PRs left for %s days\n' "$_HARNESS_LOOP_STALLS_STALE_PR_DAYS" >&2
        return 1
    fi
    if prs=$(cd "$repo" && gh pr list --state open --limit 100 --json number,url,headRefName,createdAt) &&
        stale=$(_harness_loop_stalls_stale_prs "$now" "$prefix" <<<"$prs"); then
        while IFS=$'\t' read -r number url days; do
            [[ -n "$number" ]] || continue
            # shellcheck disable=SC2016 # 本文の `…` は Markdown のコードスパン
            body=$(printf 'ループの PR %s が作られてから %s 日、マージもクローズもされていない。承認が止まっている間、ループの変更は効かない。\n\n対処(どちらか):\n\n- 採用する: レビューし、draft なら `gh pr ready %s` で draft を外してから、マージする\n- 採用しない: `gh pr close %s` で閉じる\n\nPR が開いていなくなったら、この Issue を閉じる(開いている間は毎週コメントが付く)。\n' \
                "$url" "$days" "$number" "$number") || {
                printf 'harness-weekly: WARN could not build the issue for loop PR #%s\n' "$number" >&2
                failed=1
                continue
            }
            "$send" "harness: ループの PR #${number} が ${_HARNESS_LOOP_STALLS_STALE_PR_DAYS} 日以上放置されている" "$body" || failed=1
        done <<<"$stale"
    else
        printf 'harness-weekly: WARN could not list the open PRs to find loop PRs left for %s days\n' "$_HARNESS_LOOP_STALLS_STALE_PR_DAYS" >&2
        failed=1
    fi
    return "$failed"
}

# PR にならないループのブランチを知らせる。本文を組み立てられなかったか送れなかったか、基準日を作れなかったか、問い合わせか
# Verdict の CLI の読み取りに失敗したら 1 を返す。
# 前の週から残ったブランチだけを見る(その日の run と、手動の review がまだ公開していないものを除く)。
# 基準日は今日の 7 日前で固定なので、前の週の run がスリープ明けなどで遅れて走ったブランチは、
# 今週は外れて次の週に知らせる(1 週遅れる)。基準日を近づけると作業中の手動の review を知らせてしまう
_harness_loop_stalls_report_branches() { # <repo> <prefix> <送る関数>
    local repo=$1 prefix=$2 send=$3 failed=0 now cutoff branches shown_repo branch count verdict_status verdict_note marks pr_count
    local push_command pr_command body
    local verdict_cli="$HOME/.claude/scripts/harness-verdict.sh" archive="$HOME/.claude/harness/queue-archive.md"
    # 算術式の中の $(date +%s) は失敗しても空として評価され、基準日が 1970 年より前になってどのブランチも当たらなくなるので、
    # 先に代入して確かめる
    if ! now=$(date +%s) ||
        ! cutoff=$(jq -rn --argjson epoch "$((now - 7 * 86400))" '$epoch | localtime | strftime("%Y-%m-%d")'); then
        printf 'harness-weekly: WARN could not compute the cutoff date to find the loop branches in %s\n' "$repo" >&2
        return 1
    fi
    if ! branches=$(_harness_loop_stalls_unpublished_branches "$repo" "$prefix" "$cutoff"); then
        printf 'harness-weekly: WARN could not list the loop branches in %s (is origin/main fetched?)\n' "$repo" >&2
        return 1
    fi
    shown_repo=$(_harness_loop_stalls_home_relative "$repo")
    while IFS=$'\t' read -r branch count; do
        [[ -n "$branch" ]] || continue
        # PR になっていない採用が残るブランチは Loop PR の module の入口の最後の確認がジョブを失敗させ、失敗の Issue が知らせる。
        # Verdict の CLI は Integrity Snapshot の入口を通してだけ呼ぶ。スナップショットの前に止まった run と、照合に落ちた
        # run では CLI を呼ばず、採用の有無を確かめずにブランチの Issue を作って、そのことを本文に書く(通知は止めない)
        verdict_note=""
        if ! harness_integrity_ready; then
            verdict_note='Verdict CLI を確かめられなかった(この run は改ざんの検出の準備の前に止まった)ため、このブランチに PR になっていない採用が残っているかは確かめていない。'
        else
            verdict_status=0
            marks=$(harness_integrity_run "$verdict_cli" unpublished --branch "$branch") || verdict_status=$?
            if [[ "$verdict_status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
                # shellcheck disable=SC2016 # 本文の `…` は Markdown のコードスパン
                verdict_note='Verdict CLI を信頼できなかった(claude の起動後に週次ジョブが使うスクリプトが書き換えられていた。ログの `harness-integrity:` の行を参照)ため、このブランチに PR になっていない採用が残っているかは確かめていない。'
            elif [[ "$verdict_status" -ne 0 ]]; then
                printf 'harness-weekly: WARN could not read the unpublished verdicts of %s from %s\n' "$branch" "$archive" >&2
                failed=1
                continue
            elif [[ -n "$marks" ]]; then
                printf 'harness-weekly: %s has an adopted verdict in %s; the failure issue reports it\n' "$branch" "$archive"
                continue
            fi
        fi
        [[ -z "$verdict_note" ]] || verdict_note+=$'\n\n'
        pr_count=$(cd "$repo" && gh pr list --head "$branch" --state all --json number --jq length) || {
            printf 'harness-weekly: WARN could not check whether %s has a PR\n' "$branch" >&2
            failed=1
            continue
        }
        if [[ "$pr_count" != 0 ]]; then
            # PR になったブランチ(squash マージを含む)は残っている限り毎週照会されるので、消し方を残す
            printf 'harness-weekly: %s already has a PR; delete it with git -C %s branch -D %s to stop checking it\n' "$branch" "$repo" "$branch"
            continue
        fi
        # 綴りは外の module から受け取るので、その module が変わっても手順が空の本文を送らないよう、先に代入して確かめる
        # shellcheck disable=SC2016 # 本文の `…` は Markdown のコードスパン
        if ! push_command=$(harness_loop_pr_push_command "$branch" "$shown_repo") ||
            ! pr_command=$(harness_loop_pr_create_command "$branch") ||
            ! body=$(printf 'ループのブランチ `%s` が、PR にならないまま `%s` に残っている(origin/main に無い commit: %s 件)。週次ジョブはこのブランチを公開しない。\n\n%s対処(どちらか):\n\n- 公開する: `%s` の後に、`%s` で `%s`\n- 要らなければ消す: `git -C %s branch -D %s`\n\nどちらかをしたら、この Issue を閉じる。\n' \
                "$branch" "$shown_repo" "$count" "$verdict_note" "$push_command" "$shown_repo" "$pr_command" "$shown_repo" "$branch"); then
            printf 'harness-weekly: WARN could not build the issue for %s\n' "$branch" >&2
            failed=1
            continue
        fi
        "$send" "harness: ループのブランチ ${branch} が PR になっていない" "$body" || failed=1
    done <<<"$branches"
    return "$failed"
}

# Loop Stall を見つけ、知らせるものごとに <送る関数> <タイトル> <本文> を呼ぶ(本文は複数行)。<prefix> はループのブランチの
# prefix(正本は scripts/check-guarded-paths.sh。週次ジョブが Loop PR の module にも渡す値)。2 種類のどちらかで送れなかった
# ものか、本文を組み立てられなかったものか問い合わせに失敗したものがあれば、WARN を出したうえで残りも知らせてから
# 1 を返し、無ければ 0 を返す。
harness_loop_stalls_report() { # <リポジトリ> <ループのブランチの prefix> <送る関数>
    local failed=0
    _harness_loop_stalls_report_prs "$1" "$2" "$3" || failed=1
    _harness_loop_stalls_report_branches "$1" "$2" "$3" || failed=1
    return "$failed"
}
