#!/usr/bin/env bash
# 週次ジョブ(harness-weekly.sh)が Loop PR を公開するための module。source 専用。set は呼び出し側に従う
# (set -euo pipefail 下で動く)。
#
# 持つもの:
# - 公開に使う定数(リポジトリ内の記録の置き場、Metrics-only PR を作る週数、署名用の git 設定)。週次ジョブは
#   値を写さずにこの定数を参照する。
# - run ごとの値の初期化(harness_publish_init)。Loop PR のブランチの prefix だけは週次ジョブが持ち、ここへ渡す。
#   この lib を読めずに止まった run の停止の通知も、ループのブランチを prefix で探すため。
# - 手で公開するコマンドの綴り(push、draft PR の作成、判定の記録への PR の URL の記録)。週次ジョブの案内文は
#   文を各箇所に持ち、コマンドの綴りだけをここから受け取る。綴りの関数は初期化の値を読まず、引数だけで組み立てる
#   (案内文ごとにリポジトリの表記とブランチが違い、初期化の前に止まった run の通知も使うため)。
# - Metrics-only PR が要るかの判定。worktree を作る前の絞り込み(harness_publish_metrics_only_maybe_due。ローカルの
#   記録の件数と開いている Loop PR)と、base を使った判定(harness_publish_metrics_only_due。origin/main に無い週の件数と
#   開いている Loop PR)の 2 段。gh の失敗は WARN を出して「要らない」に倒す。当日のブランチが origin にあるかの照会、
#   worktree の準備、依存のインストールは週次ジョブが行う。
# - 公開の入口 2 つと片付け: 選別の結果の公開(harness_publish_review)、Metrics-only PR の公開
#   (harness_publish_metrics_only)、公開しないで片付けること(harness_publish_discard)。入口ごとの手順・失敗の扱い・
#   本文の節を誰が書くかの正本は、それぞれの入口の関数のコメント。
#
# 返り値は成功(公開した、または公開するものが無かった)と失敗の 2 値。Integrity Snapshot の照合の失敗
# (HARNESS_INTEGRITY_FAILED)は入口の中で受け、外には出さない。失敗の理由と手で直す手順はこの lib がログに出す。
# 公開の手順が出す行は週次ジョブのログの行なので harness-weekly: で始め、この lib 自身の使い方の誤り
# (初期化の引数など)だけを harness-publish: で出す。
#
# 週次ジョブは claude の起動前にこの lib を読み込む(Integrity Snapshot の lib の後。その照合と関門を使う)。
# メモリに載った後は claude がファイルを書き換えてもその run に効かないので、Integrity Snapshot の一覧には載せない。
# 週次ジョブが読み込むので、この lib は Guarded Path(scripts/guarded-paths.txt)に載せてある。
# ローカルの記録の置き場、判定の記録、Verdict の CLI と Rule Ledger のスクリプトのパスは、Integrity Snapshot の lib と
# 同じく呼び出しのたびに $HOME から作る(2 つのスクリプトは harness_integrity_executables の行と一致しなければ実行されない)。
#
# Interface: HARNESS_PUBLISH_RATES_REPO_DIR / HARNESS_PUBLISH_LEDGER_REPO_DIR / HARNESS_PUBLISH_METRICS_ONLY_WEEKS /
# HARNESS_PUBLISH_AGENT_GIT_CONFIG / harness_publish_init / harness_publish_push_command /
# harness_publish_pr_command / harness_publish_record_command / harness_publish_metrics_only_maybe_due /
# harness_publish_metrics_only_due / harness_publish_review / harness_publish_metrics_only / harness_publish_discard。
# 関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、失敗は明示的に返す。

# 週の再発率の記録(1 週 1 ファイル)のリポジトリ内の置き場。週次ジョブの commit だけが書く
# shellcheck disable=SC2034 # 週次ジョブが参照する
HARNESS_PUBLISH_RATES_REPO_DIR="docs/harness/failure-pattern-rates"
# Rule Ledger の記録のリポジトリ内の置き場。harness-rule-ledger.sh の export が書き出す先と同じでなければならない
# shellcheck disable=SC2034 # 週次ジョブが参照する
HARNESS_PUBLISH_LEDGER_REPO_DIR="docs/harness/rule-ledger"
# origin/main に無い週の記録がこの件数たまったら、採用が無くても Metrics-only PR を作る
# shellcheck disable=SC2034 # 週次ジョブが参照する
HARNESS_PUBLISH_METRICS_ONLY_WEEKS=4
# 週次ジョブ自身の commit が使う git の設定。launchd の環境には GIT_CONFIG_GLOBAL が無く(Claude Code の子プロセスには
# settings.json の env が渡す)、~/.gitconfig の署名は 1Password に頼るので、無人の run では止まる。Claude Code の git と
# 同じ設定(ローカルの署名鍵)を使う
# shellcheck disable=SC2034 # 週次ジョブが参照する
HARNESS_PUBLISH_AGENT_GIT_CONFIG="$HOME/.config/git/claude-code.inc"

# run ごとの値。harness_publish_init が入れる
_HARNESS_PUBLISH_REPO=""
_HARNESS_PUBLISH_WORKTREE=""
_HARNESS_PUBLISH_BRANCH=""
_HARNESS_PUBLISH_LOOP_BRANCH_PREFIX=""
_HARNESS_PUBLISH_PR_BODY=""
_HARNESS_PUBLISH_REVIEW_RESULT=""
_HARNESS_PUBLISH_EVAL_RESULTS=""
_HARNESS_PUBLISH_DATE=""
_HARNESS_PUBLISH_RUN=""

# run ごとの値を受け取る。引数は --repo <パス> --worktree <パス> --branch <ブランチ> --loop-branch-prefix <prefix>
# --pr-body <パス> --review-result <パス> --eval-results <パス> --date <YYYY-MM-DD> --run <採用の印> で、すべて必須。
# <評価の結果> は週次ジョブの評価の工程が書いて封印するファイルで、封印されたときだけ Rule Ledger の記録に渡す。空の値と知らない引数は
# 受け付けない。<ブランチ> は <prefix> で始まる
harness_publish_init() {
    local repo="" worktree="" branch="" prefix="" pr_body="" review_result="" eval_results="" date="" run="" missing=""
    while [[ $# -gt 0 ]]; do
        if [[ $# -lt 2 ]]; then
            printf 'harness-publish: %s needs a value\n' "$1" >&2
            return 1
        fi
        case $1 in
        --repo) repo=$2 ;;
        --worktree) worktree=$2 ;;
        --branch) branch=$2 ;;
        --loop-branch-prefix) prefix=$2 ;;
        --pr-body) pr_body=$2 ;;
        --review-result) review_result=$2 ;;
        --eval-results) eval_results=$2 ;;
        --date) date=$2 ;;
        --run) run=$2 ;;
        *)
            printf 'harness-publish: unknown argument %s to harness_publish_init\n' "$1" >&2
            return 1
            ;;
        esac
        shift 2
    done
    [[ -n "$repo" ]] || missing+=" --repo"
    [[ -n "$worktree" ]] || missing+=" --worktree"
    [[ -n "$branch" ]] || missing+=" --branch"
    [[ -n "$prefix" ]] || missing+=" --loop-branch-prefix"
    [[ -n "$pr_body" ]] || missing+=" --pr-body"
    [[ -n "$review_result" ]] || missing+=" --review-result"
    [[ -n "$eval_results" ]] || missing+=" --eval-results"
    [[ -n "$date" ]] || missing+=" --date"
    [[ -n "$run" ]] || missing+=" --run"
    if [[ -n "$missing" ]]; then
        printf 'harness-publish: harness_publish_init needs a value for%s\n' "$missing" >&2
        return 1
    fi
    if [[ "$branch" != "$prefix"* ]]; then
        printf 'harness-publish: branch %s does not start with the loop branch prefix %s\n' "$branch" "$prefix" >&2
        return 1
    fi
    _HARNESS_PUBLISH_REPO=$repo
    _HARNESS_PUBLISH_WORKTREE=$worktree
    _HARNESS_PUBLISH_BRANCH=$branch
    _HARNESS_PUBLISH_LOOP_BRANCH_PREFIX=$prefix
    _HARNESS_PUBLISH_PR_BODY=$pr_body
    _HARNESS_PUBLISH_REVIEW_RESULT=$review_result
    _HARNESS_PUBLISH_EVAL_RESULTS=$eval_results
    _HARNESS_PUBLISH_DATE=$date
    _HARNESS_PUBLISH_RUN=$run
}

# ブランチを origin に push するコマンドを、末尾の改行なしで出す。<リポジトリ> を渡せば -C で指す。
# <リポジトリ> は案内文の読み手に合わせた表記(ログなら絶対パス、公開リポジトリの Issue なら ~ で書いたパス)
harness_publish_push_command() { # <ブランチ> [<リポジトリ>]
    if [[ -n "${2:-}" ]]; then
        printf 'git -C %s push origin %s' "$2" "$1"
    else
        printf 'git push origin %s' "$1"
    fi
}

# draft PR を作るコマンドを、末尾の改行なしで出す。<本文> を渡せば --body-file で指す
harness_publish_pr_command() { # <ブランチ> [<本文のパス>]
    printf 'gh pr create --draft --base main --head %s' "$1"
    [[ -z "${2:-}" ]] || printf ' --body-file %s' "$2"
}

# 印 <run> の採用を PR の URL で記録するコマンドを、ログにそのまま貼れる 1 行で、末尾の改行なしで出す。
# 印は空白を含むのでシングルクォートで囲み、手書きの印に入りうる ' は '\'' に置き換える
harness_publish_record_command() { # <run>
    local quote="'\\''"
    printf "bash ~/.claude/scripts/harness-verdict.sh publish --run '%s' --pr-url <PR URL>" "${1//\'/$quote}"
}

# 公開の手順が数えた件数。_harness_publish_commit_rate_records と _harness_publish_commit_ledger_records が入れる
_HARNESS_PUBLISH_RATE_RECORDS_COMMITTED=0
_HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED=0
# _harness_publish_push_and_create が作った PR の URL
_HARNESS_PUBLISH_PR_URL=""

# 週の再発率の記録のローカルの置き場(1 週 1 ファイル。全週を持つ)
_harness_publish_local_rates_dir() {
    printf '%s\n' "$HOME/.claude/harness/failure-pattern-rates"
}

# Rule Ledger のローカルの置き場(1 採用 1 ファイル)
_harness_publish_local_ledger_dir() {
    printf '%s\n' "$HOME/.claude/harness/rule-ledger"
}

_harness_publish_rule_ledger() {
    printf '%s\n' "$HOME/.claude/scripts/harness-rule-ledger.sh"
}

_harness_publish_verdict_cli() {
    printf '%s\n' "$HOME/.claude/scripts/harness-verdict.sh"
}

# 判定の記録(Verdict の CLI が読み書きする)
_harness_publish_archive() {
    printf '%s\n' "$HOME/.claude/harness/queue-archive.md"
}

# 週次ジョブ自身の commit に使う git。GIT_CONFIG_GLOBAL が無ければ HARNESS_PUBLISH_AGENT_GIT_CONFIG で署名する
_harness_publish_git() {
    if [[ -z "${GIT_CONFIG_GLOBAL:-}" && -f "$HARNESS_PUBLISH_AGENT_GIT_CONFIG" ]]; then
        GIT_CONFIG_GLOBAL="$HARNESS_PUBLISH_AGENT_GIT_CONFIG" git "$@"
    else
        git "$@"
    fi
}

# ローカルの週の記録(<日付>.json)のパスを 1 行に 1 つ出す。置き場が無ければ何も出さない
_harness_publish_local_rate_records() {
    local rates_dir file
    rates_dir=$(_harness_publish_local_rates_dir) || return 1
    for file in "$rates_dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json; do
        [[ ! -f "$file" ]] || printf '%s\n' "$file"
    done
}

# worktree を <revision> に戻し、<置き場>(リポジトリ内のパス)に写しかけた追跡されていないファイルを消す
_harness_publish_reset_worktree() { # <revision> <置き場>
    git -C "$_HARNESS_PUBLISH_WORKTREE" reset --quiet --hard "$1" || return 1
    git -C "$_HARNESS_PUBLISH_WORKTREE" clean --quiet -fd -- "$2" || return 1
}

_harness_publish_remove_worktree() {
    git -C "$_HARNESS_PUBLISH_REPO" worktree remove --force "$_HARNESS_PUBLISH_WORKTREE" >/dev/null 2>&1 ||
        rm -rf "$_HARNESS_PUBLISH_WORKTREE"
}

# ローカルの週の記録のうち、base(origin/main)の HARNESS_PUBLISH_RATES_REPO_DIR に無いものを出す。閉じた PR や
# 未マージの PR に入っていた週も、origin/main に無ければ出す(ローカルの印では判定しない)。
# この run の日付の記録だけは、origin/main にあっても中身が違えば出す。同じ日の再実行がその日の記録を
# 書き直すため(harness-failure-rates.sh の since)。リポジトリ側は oxfmt を通してあるので、バイト列では
# なく JSON として比べ、どちらかが JSON として読めなければ違うものとして出す。ほかの日付は中身を比べない:
# origin/main の記録を人が直したときにローカルの古い写しで戻さないためと、前の週の claude が書き換えた
# 記録(この run のハッシュでは見つけられない。_harness_publish_commit_rate_records)でマージ済みの記録を上書きしないため。
# 再実行が選別を省いた(当日のブランチが origin にある)週は、書き直した記録はローカルにだけ残る
_harness_publish_uncommitted_rate_records() { # <base>
    local base=$1 files file committed local_record
    files=$(_harness_publish_local_rate_records) || return 1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if ! git -C "$_HARNESS_PUBLISH_WORKTREE" cat-file -e "$base:$HARNESS_PUBLISH_RATES_REPO_DIR/${file##*/}" 2>/dev/null; then
            printf '%s\n' "$file"
        elif [[ "${file##*/}" == "$_HARNESS_PUBLISH_DATE.json" ]]; then
            if ! committed=$(git -C "$_HARNESS_PUBLISH_WORKTREE" show "$base:$HARNESS_PUBLISH_RATES_REPO_DIR/${file##*/}" | jq -S -c . 2>/dev/null) ||
                ! local_record=$(jq -S -c . "$file" 2>/dev/null) || [[ "$committed" != "$local_record" ]]; then
                printf '%s\n' "$file"
            fi
        fi
    done <<<"$files"
}

# origin/main に無い週の記録を worktree に写し、週次ジョブの commit 1 つにする。抽出と選別の claude
# には書かせない(改善する側が指標を書き換えられないように)。リポジトリ側の書き換えは週次ジョブが選別の commit の
# 検査で、ローカルの記録の書き換えは写す直前のデータの照合(Integrity Snapshot)が見つける。書き換えか照合できない
# 記録を見つけたら、commit せずに HARNESS_INTEGRITY_FAILED を返す。前の週から持ち越した記録を
# その週の claude が書き換えていた場合は見つけられない(Integrity Snapshot の lib のヘッダの残存リスク)。
# oxfmt を通すのは、commit フックが JSON の書式を検査するため。写した件数を _HARNESS_PUBLISH_RATE_RECORDS_COMMITTED に入れる
_harness_publish_commit_rate_records() { # <base>
    local base=$1 files file
    _HARNESS_PUBLISH_RATE_RECORDS_COMMITTED=0
    harness_integrity_check_data || return "$HARNESS_INTEGRITY_FAILED"
    files=$(_harness_publish_uncommitted_rate_records "$base") || return 1
    [[ -n "$files" ]] || return 0
    mkdir -p "$_HARNESS_PUBLISH_WORKTREE/$HARNESS_PUBLISH_RATES_REPO_DIR" || return 1
    while IFS= read -r file; do
        cp "$file" "$_HARNESS_PUBLISH_WORKTREE/$HARNESS_PUBLISH_RATES_REPO_DIR/" || return 1
        _HARNESS_PUBLISH_RATE_RECORDS_COMMITTED=$((_HARNESS_PUBLISH_RATE_RECORDS_COMMITTED + 1))
    done <<<"$files"
    (cd "$_HARNESS_PUBLISH_WORKTREE" && pnpm exec oxfmt "$HARNESS_PUBLISH_RATES_REPO_DIR") || return 1
    git -C "$_HARNESS_PUBLISH_WORKTREE" add -- "$HARNESS_PUBLISH_RATES_REPO_DIR" || return 1
    _harness_publish_git -C "$_HARNESS_PUBLISH_WORKTREE" commit --quiet -m "harness: Failure Pattern の再発率の週の記録を足す" || return 1
}

# Rule Ledger の commit に失敗したときに、worktree を <revision> に戻して写しかけの記録を消す。記録はローカルに残る
_harness_publish_drop_ledger_commit() { # <revision>
    printf 'harness-weekly: WARN failed to commit the Rule Ledger records; they stay in %s for a later PR\n' "$(_harness_publish_local_ledger_dir)" >&2
    _harness_publish_reset_worktree "$1" "$HARNESS_PUBLISH_LEDGER_REPO_DIR"
}

# base(origin/main)に無いローカルの Rule Ledger の記録を worktree に写し、週次ジョブの commit 1 つにする。
# 写す記録の選び方(マージされた PR と、この run の PR の記録だけ)と仕事の識別子の検査・伏せ字は
# harness-rule-ledger.sh export が行う。選別の claude には書かせない(週次ジョブが選別の commit を、写す直前の
# データの照合がローカルの記録を確かめる)。写した件数を _HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED に入れる。
# 失敗しても記録はローカルに残り、後の PR が足す。照合に落ちたら HARNESS_INTEGRITY_FAILED を返す
_harness_publish_commit_ledger_records() { # <base> [この run の PR の番号]
    local base=$1 rule_ledger output count pr_args=()
    _HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED=0
    [[ -z "${2:-}" ]] || pr_args=(--pr "$2")
    harness_integrity_check_data || return "$HARNESS_INTEGRITY_FAILED"
    rule_ledger=$(_harness_publish_rule_ledger) || return 1
    # identity leak guard のローカルのパターン(gitignore 済み)は worktree に無いので、リポジトリ本体のものを渡す。
    # export は書き出した形を rule-ledger/exported/ に残す(封印しない)ので、この後にデータを照合しないこと
    output=$(SENSITIVE_PATTERNS_LOCAL="${SENSITIVE_PATTERNS_LOCAL-$_HARNESS_PUBLISH_REPO/scripts/sensitive-patterns.local.txt}" \
        harness_integrity_run "$rule_ledger" export --base "$base" --worktree "$_HARNESS_PUBLISH_WORKTREE" ${pr_args[@]+"${pr_args[@]}"}) || return $?
    printf '%s\n' "$output"
    count=$(sed -n 's/^harness-rule-ledger: exported \([0-9][0-9]*\) record(s)$/\1/p' <<<"$output")
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    [[ "$count" -gt 0 ]] || return 0
    (cd "$_HARNESS_PUBLISH_WORKTREE" && pnpm exec oxfmt "$HARNESS_PUBLISH_LEDGER_REPO_DIR") || return 1
    git -C "$_HARNESS_PUBLISH_WORKTREE" add -- "$HARNESS_PUBLISH_LEDGER_REPO_DIR" || return 1
    _harness_publish_git -C "$_HARNESS_PUBLISH_WORKTREE" commit --quiet -m "harness: Rule Ledger の記録を足す" || return 1
    _HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED=$count
}

# 公開(push と gh pr create)の直前の関門。照合の失敗を取りこぼした呼び出し元があっても、書き換えられた run の PR を作らない
_harness_publish_trusted_before() { # <これから行う操作>
    harness_integrity_gate && return 0
    printf 'harness-weekly: stopped before %s on %s; no PR created, because the scripts the job runs could not be trusted\n' "$1" "$_HARNESS_PUBLISH_BRANCH" >&2
    # gh pr create の直前で止まったときはブランチが origin にあり、同じ日の再実行は手で PR を作るよう案内してしまう
    [[ "$1" != 'gh pr create' ]] ||
        printf 'harness-weekly: %s is already on origin; do not open a PR from it as it is. Find what changed the scripts, then delete the branch (git push origin --delete %s)\n' \
            "$_HARNESS_PUBLISH_BRANCH" "$_HARNESS_PUBLISH_BRANCH" >&2
    return 1
}

# 関門 → push → 関門 → draft PR の作成。作った PR の URL を _HARNESS_PUBLISH_PR_URL に入れる。失敗したら手で公開する
# 案内を出して 1 を返し、worktree・ローカルブランチ・本文は残す(手で公開するときに使う)。
# <案内の続き> は PR の作成に失敗したときの案内の末尾に足す文(PR を作った後に入口がすることを手で行う手順)
_harness_publish_push_and_create() { # <PR のタイトル> [<案内の続き>]
    local title=$1 hint=${2:-} url
    _HARNESS_PUBLISH_PR_URL=""
    _harness_publish_trusted_before push || return 1
    git -C "$_HARNESS_PUBLISH_WORKTREE" push --quiet origin "HEAD:refs/heads/$_HARNESS_PUBLISH_BRANCH" || {
        printf 'harness-weekly: push of %s failed; no PR created. To publish by hand: %s, then %s\n' \
            "$_HARNESS_PUBLISH_BRANCH" "$(harness_publish_push_command "$_HARNESS_PUBLISH_BRANCH" "$_HARNESS_PUBLISH_REPO")" \
            "$(harness_publish_pr_command "$_HARNESS_PUBLISH_BRANCH" "$_HARNESS_PUBLISH_PR_BODY")" >&2
        return 1
    }
    _harness_publish_trusted_before 'gh pr create' || return 1
    url=$(cd "$_HARNESS_PUBLISH_WORKTREE" && gh pr create --draft --base main --head "$_HARNESS_PUBLISH_BRANCH" \
        --title "$title" --body-file "$_HARNESS_PUBLISH_PR_BODY") || {
        printf 'harness-weekly: pushed %s but gh pr create failed; open the PR by hand with %s%s\n' \
            "$_HARNESS_PUBLISH_BRANCH" "$(harness_publish_pr_command "$_HARNESS_PUBLISH_BRANCH" "$_HARNESS_PUBLISH_PR_BODY")" "$hint" >&2
        return 1
    }
    # gh は URL を最後の行に出す
    _HARNESS_PUBLISH_PR_URL=${url##*$'\n'}
}

# PR を作った後の後片付け。ブランチは origin にあるので、worktree とローカルのブランチを消す(残すと週ごとに溜まる)
_harness_publish_cleanup_published() {
    _harness_publish_remove_worktree
    git -C "$_HARNESS_PUBLISH_REPO" branch --quiet -D "$_HARNESS_PUBLISH_BRANCH" >/dev/null 2>&1 ||
        printf 'harness-weekly: WARN could not delete local branch %s in %s\n' "$_HARNESS_PUBLISH_BRANCH" "$_HARNESS_PUBLISH_REPO" >&2
}

# 開いている Loop PR(ブランチが初期化で受け取った prefix で始まる)の URL を出す。無ければ空。gh が失敗すれば非 0
_harness_publish_open_loop_pr() {
    local prefix
    # prefix は JSON の文字列にして式に埋める(gh の --jq は --arg を取れない)
    prefix=$(jq -n --arg prefix "$_HARNESS_PUBLISH_LOOP_BRANCH_PREFIX" '$prefix') || return 1
    (cd "$_HARNESS_PUBLISH_REPO" && gh pr list --state open --json headRefName,url \
        --jq "[.[] | select(.headRefName | startswith($prefix))][0].url // empty")
}

# 開いている Loop PR が無ければ 0。あれば <書式> に <引数> と PR の URL(最後の %s)を当てて出し、1 を返す。
# gh が失敗すれば WARN を出して 1 を返す(Metrics-only PR は作らない側に倒す)
_harness_publish_no_open_loop_pr() { # <書式> [<引数>...]
    local format=$1 open_pr
    shift
    open_pr=$(_harness_publish_open_loop_pr) || {
        printf 'harness-weekly: WARN listing open loop PRs failed; no metrics-only PR this week\n' >&2
        return 1
    }
    [[ -n "$open_pr" ]] || return 0
    # shellcheck disable=SC2059 # 書式は呼び出し側の固定の文字列
    printf "$format" "$@" "$open_pr"
    return 1
}

# Metrics-only PR が要るかの 1 段目。worktree を作る前に、ローカルの記録の件数(origin/main に無い件数の上限)と
# 開いている Loop PR で絞る。要るかもしれなければ 0、要らなければ理由を出して 1 を返す(gh の失敗も 1)。
# 開いている Loop PR があれば作らない(その PR に記録が入っているか、次に採用のある PR がまとめて足す。作ると毎週 1 本ずつ増える)
harness_publish_metrics_only_maybe_due() {
    local rates_dir records local_count
    rates_dir=$(_harness_publish_local_rates_dir) || return 1
    records=$(_harness_publish_local_rate_records) || return 1
    local_count=$(grep -c . <<<"$records" || true)
    if [[ "$local_count" -lt "$HARNESS_PUBLISH_METRICS_ONLY_WEEKS" ]]; then
        printf 'harness-weekly: at most %s weekly failure rate record(s) not on origin/main; carried over in %s (a metrics-only PR needs %s)\n' \
            "$local_count" "$rates_dir" "$HARNESS_PUBLISH_METRICS_ONLY_WEEKS"
        return 1
    fi
    _harness_publish_no_open_loop_pr 'harness-weekly: loop PR %s is open; weekly failure rate records carried over\n'
}

# Metrics-only PR が要るかの 2 段目。origin/main に無い週の記録(<base> は worktree の origin/main)が
# HARNESS_PUBLISH_METRICS_ONLY_WEEKS 件以上あり、開いている Loop PR が無ければ 0。要らなければ理由を出して 1 を返す
harness_publish_metrics_only_due() { # <base>
    local base=$1 count
    count=$(_harness_publish_uncommitted_rate_records "$base" | grep -c . || true)
    if [[ "$count" -lt "$HARNESS_PUBLISH_METRICS_ONLY_WEEKS" ]]; then
        printf 'harness-weekly: %s weekly failure rate record(s) not on origin/main; carried over in %s (a metrics-only PR needs %s)\n' \
            "$count" "$(_harness_publish_local_rates_dir)" "$HARNESS_PUBLISH_METRICS_ONLY_WEEKS"
        return 1
    fi
    _harness_publish_no_open_loop_pr 'harness-weekly: %s weekly failure rate record(s) not on origin/main, but loop PR %s is open; carried over\n' \
        "$count"
}

# 判定の記録で、この run の選別の採用(初期化で受け取った印)を PR の URL に置き換える(Verdict の CLI の publish)。
# 置き換えが 0 件になるのは、陳腐化の修正だけの PR(正常)か、選別が settle で記録しなかったときで、
# ここでは区別できないので、両方の読み方を添えて知らせる。失敗しても WARN だけにする(残った印は週次ジョブの
# finish_run が捕まえる)。Integrity Snapshot の照合に落ちたら、CLI を呼ばずに HARNESS_INTEGRITY_FAILED を返す
_harness_publish_record_pr_url() { # <PR の URL>
    local verdict_cli count status=0
    verdict_cli=$(_harness_publish_verdict_cli) || status=1
    [[ "$status" -ne 0 ]] || count=$(harness_integrity_run "$verdict_cli" publish --run "$_HARNESS_PUBLISH_RUN" --pr-url "$1") || status=$?
    [[ "$status" -ne "$HARNESS_INTEGRITY_FAILED" ]] || return "$status"
    if [[ "$status" -ne 0 ]]; then
        printf 'harness-weekly: WARN failed to record the PR URL in %s; finish_run reports the unpublished verdicts\n' "$(_harness_publish_archive)" >&2
        return 0
    fi
    if [[ "$count" == 0 ]]; then
        printf 'harness-weekly: no verdict adopted in run "%s" in %s; PR URL not recorded (normal if the PR only fixes stale rules; otherwise the review did not record its verdicts with the settle command)\n' \
            "$_HARNESS_PUBLISH_RUN" "$(_harness_publish_archive)" >&2
        return 0
    fi
    printf 'harness-weekly: recorded the PR URL on %s verdict(s)\n' "$count"
}

# PR を作った後に、この run の採用を Rule Ledger に記録し、base に無い記録(マージされた PR から持ち越した分を
# 含む)を週次ジョブの commit で足して push し直す。PR 番号は PR を作るまで決まらないので、PR を作る前の
# commit には入れられない。照合のほかで失敗しても PR と採用の公開は止めない: 記録はローカルに残り、この PR が
# マージされた後に PR を作る run が足す。記録そのもの(record)に失敗したときは、判定の記録の
# PR の URL を持つ採用から手で作り直せる。Integrity Snapshot の照合に落ちたら、記録を足さずに HARNESS_INTEGRITY_FAILED を返す
_harness_publish_record_ledger() { # <base> <PR の URL>
    local base=$1 url=$2 pushed_revision rule_ledger output status=0 id ledger_dir results=()
    ledger_dir=$(_harness_publish_local_ledger_dir)
    rule_ledger=$(_harness_publish_rule_ledger) || return 0
    pushed_revision=$(git -C "$_HARNESS_PUBLISH_WORKTREE" rev-parse HEAD) || return 0
    # 評価の工程が書いて封印した結果だけを渡す。評価が失敗した run では渡さず、採用を「測っていない」として
    # 記録する(選別の claude が置いた偽の得点を記録しない)。封印の後の書き換えは次のデータの照合が見つける
    if harness_integrity_sealed "$_HARNESS_PUBLISH_EVAL_RESULTS"; then
        results=(--results "$_HARNESS_PUBLISH_EVAL_RESULTS")
    fi
    # record は分類の記録と評価の結果から記録を作るので、その直前にデータを照合する
    harness_integrity_check_data || return "$HARNESS_INTEGRITY_FAILED"
    output=$(harness_integrity_run "$rule_ledger" record --pr-url "$url" --date "$_HARNESS_PUBLISH_DATE" --via weekly ${results[@]+"${results[@]}"}) ||
        status=$?
    [[ -z "$output" ]] || printf '%s\n' "$output"
    [[ "$status" -ne "$HARNESS_INTEGRITY_FAILED" ]] || return "$status"
    [[ "$status" -eq 0 ]] ||
        printf 'harness-weekly: WARN failed to record the adoptions of %s in the Rule Ledger %s; record them by hand with bash %s record --pr-url %s --date %s --via weekly\n' \
            "$url" "$ledger_dir" "$rule_ledger" "$url" "$_HARNESS_PUBLISH_DATE" >&2
    # record が作った記録だけを封印する(それ以外に増えた記録はデータの照合が追加として見つける)
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        harness_integrity_seal "$ledger_dir/$id.json" || return "$HARNESS_INTEGRITY_FAILED"
    done <<<"$(sed -n 's/^harness-rule-ledger: recorded \([^ ][^ ]*\)$/\1/p' <<<"$output")"
    status=0
    _harness_publish_commit_ledger_records "$base" "${url##*/}" || status=$?
    if [[ "$status" -ne 0 ]]; then
        # PR は作成済みなので、戻せなくても失敗にしない(worktree は後片付けが消す)
        _harness_publish_drop_ledger_commit "$pushed_revision" || true
        [[ "$status" -ne "$HARNESS_INTEGRITY_FAILED" ]] || return "$status"
        return 0
    fi
    [[ "$_HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED" -gt 0 ]] || return 0
    harness_integrity_gate || return "$HARNESS_INTEGRITY_FAILED"
    if git -C "$_HARNESS_PUBLISH_WORKTREE" push --quiet origin "HEAD:refs/heads/$_HARNESS_PUBLISH_BRANCH"; then
        printf 'harness-weekly: committed %s Rule Ledger record(s) to %s\n' "$_HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED" "$url"
    else
        printf 'harness-weekly: WARN push of the Rule Ledger records to %s failed; they stay in %s for a PR after this one merges\n' \
            "$_HARNESS_PUBLISH_BRANCH" "$ledger_dir" >&2
    fi
}

# 選別の commit(1 件以上)を Loop PR として公開する。worktree と依存は用意済みで、本文は週次ジョブが書き終えている
# 前提(純増を記録の commit より前に数えるため)。
# 手順: 再発率の記録の commit → 関門 → push → 関門 → PR の作成 → 本文と結果ファイルを消す → 判定の記録への URL の
# 置き換え → Rule Ledger の記録・封印・commit・関門・再 push → 後片付け。失敗の扱い:
# - 再発率の記録が照合に落ちた: PR を作らずに失敗する(書き換えられた記録を正として持ち越さないよう、人に見せる)
# - 再発率の記録をほかの理由で commit できなかった: WARN を出し、写しかけを戻して公開を続ける(記録はローカルに残り、
#   次の PR がまとめて足す)
# - 関門・push・PR の作成の失敗: 案内を出して失敗し、worktree・ローカルブランチ・本文を残す
# - PR を作った後の照合の失敗(URL の置き換えか Rule Ledger の記録): 後片付けをしたうえで PR を残して失敗する
#   (heartbeat で健全に見せない)。それ以外の失敗は WARN にとどめる
harness_publish_review() { # <base>
    local base=$1 commits commit_status=0 post_status=0
    commits=$(git -C "$_HARNESS_PUBLISH_WORKTREE" rev-list --count "$base..HEAD") || return 1
    _harness_publish_commit_rate_records "$base" || commit_status=$?
    if [[ "$commit_status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        printf 'harness-weekly: no PR created; check %s by hand\n' "$(_harness_publish_local_rates_dir)" >&2
        return 1
    elif [[ "$commit_status" -eq 0 ]]; then
        [[ "$_HARNESS_PUBLISH_RATE_RECORDS_COMMITTED" -eq 0 ]] ||
            printf 'harness-weekly: committed %s weekly failure rate record(s)\n' "$_HARNESS_PUBLISH_RATE_RECORDS_COMMITTED"
    else
        printf 'harness-weekly: WARN failed to commit the weekly failure rate records; they stay in %s for the next PR\n' \
            "$(_harness_publish_local_rates_dir)" >&2
        _harness_publish_reset_worktree HEAD "$HARNESS_PUBLISH_RATES_REPO_DIR" || return 1
    fi
    _harness_publish_push_and_create "harness: 週次レビュー $_HARNESS_PUBLISH_DATE" \
        ", then record its URL with $(harness_publish_record_command "$_HARNESS_PUBLISH_RUN")" || return 1
    printf 'harness-weekly: opened draft PR %s (%s commit(s))\n' "$_HARNESS_PUBLISH_PR_URL" "$commits"
    rm -f "$_HARNESS_PUBLISH_PR_BODY" "$_HARNESS_PUBLISH_REVIEW_RESULT"
    _harness_publish_record_pr_url "$_HARNESS_PUBLISH_PR_URL" || post_status=$?
    [[ "$post_status" -ne 0 ]] || _harness_publish_record_ledger "$base" "$_HARNESS_PUBLISH_PR_URL" || post_status=$?
    _harness_publish_cleanup_published
    if [[ "$post_status" -ne 0 ]]; then
        printf 'harness-weekly: opened %s, but the scripts or records the job uses after it could not be trusted; check the PR and the Rule Ledger by hand\n' \
            "$_HARNESS_PUBLISH_PR_URL" >&2
        return 1
    fi
}

# 採用の無い週に、週の記録だけの draft PR(Metrics-only PR)を作る。worktree と依存は用意済みの前提。
# 手順: 再発率の記録の commit(できなければ PR を作らずに失敗) → 持ち越した Rule Ledger の記録の commit(照合に
# 落ちたら PR を作らずに失敗し、ほかの失敗は戻して続ける) → 本文の先頭の件数の文 → <節を足す関数> → 関門 → push →
# 関門 → PR の作成 → 後片付け。
# 件数の文は commit の後にしか書けず、節(推移と検出件数)は週次ジョブが組み立てるので、本文は件数の文で書き始めて
# (前の内容は捨てる)から <節を足す関数> を呼ぶ。節の関数を記録の commit の後に呼ぶのは、推移の節の入口の照合を
# 記録の commit より後に保つため(先に呼ぶと、実行物が書き換えられた run のログと、ローカルに残る commit が変わる)。
# <節を足す関数> が非 0 を返したら PR を作らずに失敗する(PR を作らない理由はその関数が出す)。関門・push・PR の作成の
# 失敗は harness_publish_review と同じく、案内を出して失敗し、worktree・ローカルブランチ・本文を残す
harness_publish_metrics_only() { # <base> <節を本文に足す関数>
    local base=$1 sections=${2:-} rate_records_revision status=0
    if [[ -z "$sections" ]] || ! declare -F "$sections" >/dev/null; then
        printf 'harness-publish: harness_publish_metrics_only needs the name of a function that appends the body sections\n' >&2
        return 1
    fi
    _harness_publish_commit_rate_records "$base" || {
        printf 'harness-weekly: failed to commit the weekly failure rate records in %s; no PR created\n' "$_HARNESS_PUBLISH_WORKTREE" >&2
        return 1
    }
    rate_records_revision=$(git -C "$_HARNESS_PUBLISH_WORKTREE" rev-parse HEAD) || return 1
    _harness_publish_commit_ledger_records "$base" || status=$?
    if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        printf 'harness-weekly: the Rule Ledger records could not be trusted; no PR created\n' >&2
        return 1
    fi
    [[ "$status" -eq 0 ]] || _harness_publish_drop_ledger_commit "$rate_records_revision" || return 1
    printf '採用した変更は無い。origin/main に無い週の Failure Pattern の再発率の記録が %s 週分たまったので、記録だけを commit した。\n' \
        "$_HARNESS_PUBLISH_RATE_RECORDS_COMMITTED" >"$_HARNESS_PUBLISH_PR_BODY"
    [[ "$_HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED" -eq 0 ]] ||
        printf '\nマージ済みの PR の Rule Ledger の記録のうち、まだ載っていなかった %s 件も足した(%s)。\n' \
            "$_HARNESS_PUBLISH_LEDGER_RECORDS_COMMITTED" "$HARNESS_PUBLISH_LEDGER_REPO_DIR" >>"$_HARNESS_PUBLISH_PR_BODY"
    "$sections" || return 1
    _harness_publish_push_and_create "harness: 週次の指標 $_HARNESS_PUBLISH_DATE" || return 1
    printf 'harness-weekly: opened metrics-only draft PR %s (%s weekly record(s))\n' "$_HARNESS_PUBLISH_PR_URL" "$_HARNESS_PUBLISH_RATE_RECORDS_COMMITTED"
    rm -f "$_HARNESS_PUBLISH_PR_BODY" "$_HARNESS_PUBLISH_REVIEW_RESULT"
    _harness_publish_cleanup_published
    return 0
}

# 公開しない週の片付け。本文・選別の結果ファイル・worktree を消す。ローカルのブランチは消さない(公開しない週の
# ブランチは origin/main から切ったままで、次の run の worktree の準備が作り直す)。worktree を消せなければ 1 を返す
harness_publish_discard() {
    rm -f "$_HARNESS_PUBLISH_PR_BODY" "$_HARNESS_PUBLISH_REVIEW_RESULT" || return 1
    _harness_publish_remove_worktree
}
