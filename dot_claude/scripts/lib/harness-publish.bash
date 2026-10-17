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
#
# 週次ジョブは claude の起動前にこの lib を読み込む(Integrity Snapshot の lib の後)。メモリに載った後は
# claude がファイルを書き換えてもその run に効かないので、Integrity Snapshot の一覧には載せない。
# 週次ジョブが読み込むので、この lib は Guarded Path(scripts/guarded-paths.txt)に載せてある。
#
# Interface: HARNESS_PUBLISH_RATES_REPO_DIR / HARNESS_PUBLISH_LEDGER_REPO_DIR / HARNESS_PUBLISH_METRICS_ONLY_WEEKS /
# HARNESS_PUBLISH_AGENT_GIT_CONFIG / harness_publish_init / harness_publish_push_command /
# harness_publish_pr_command / harness_publish_record_command。
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
_HARNESS_PUBLISH_DATE=""
_HARNESS_PUBLISH_RUN=""

# run ごとの値を受け取る。引数は --repo <パス> --worktree <パス> --branch <ブランチ> --loop-branch-prefix <prefix>
# --pr-body <パス> --review-result <パス> --date <YYYY-MM-DD> --run <採用の印> で、すべて必須。空の値と知らない引数は
# 受け付けない。<ブランチ> は <prefix> で始まる
harness_publish_init() {
    local repo="" worktree="" branch="" prefix="" pr_body="" review_result="" date="" run="" missing=""
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
