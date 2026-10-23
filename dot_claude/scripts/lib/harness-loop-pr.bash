#!/usr/bin/env bash
# 週次ジョブ(harness-weekly.sh)の Loop PR(GLOSSARY.md)の module。source 専用。set は呼び出し側に従う
# (set -euo pipefail 下で動く)。
#
# 持つもの:
# - run ごとの値の初期化(harness_loop_pr_init)。週次ジョブが呼ぶ初期化はこれだけで、Review Outcome の lib と本文の lib の
#   初期化はここから呼ぶ。Loop PR のブランチの prefix だけは週次ジョブが持ち、ここへ渡す。この lib を読めずに止まった run
#   の停止の通知も、ループのブランチを prefix で探すため。
# - 公開に使う値(リポジトリ内の記録の置き場、Metrics-only PR を作る週数、署名用の git 設定)。interface には出さない。
#   記録の置き場は、初期化で Review Outcome の lib と本文の lib に渡す。
# - 選別の prompt に埋める指示(harness_loop_pr_review_instructions)。結果ファイルの指示(Review Outcome の lib)、本文の
#   指示(本文の lib)、記録の置き場に触れさせない指示をまとめて返す。
# - 手で公開するコマンドの綴り(push、draft PR の作成、判定の記録への PR の URL の記録)。週次ジョブの案内文は
#   文を各箇所に持ち、コマンドの綴りだけをここから受け取る。綴りの関数は初期化の値を読まず、引数だけで組み立てる
#   (案内文ごとにリポジトリの表記とブランチが違い、初期化の前に止まった run の通知も使うため)。
# - 選別の経路(harness_loop_pr_run_review): 作業場所の準備、選別の claude の実行(週次ジョブから受け取ったコマンドを、
#   worktree の中で採用の印を渡し、Integrity Snapshot の工程の入口を通して走らせる。ADR 0017)、Review Outcome の分類、
#   Eval Case の評価と結果の封印、本文、公開、Rule Ledger の記録、選別が失敗した run の案内。選別が何も commit しなかった週の
#   振り分けは、選別を省いた週の Metrics-only PR(harness_loop_pr_publish_metrics_only_if_due)と同じ判定
#   (_harness_loop_pr_metrics_only_or_discard)を通る。
# - 作業場所の準備。当日のブランチの origin への照会、pnpm の確認、worktree の準備、依存のインストールを 2 つの入口で共有し、
#   当日のブランチが origin にあるときの扱いだけを入口ごとに判定する。worktree の作成から削除までをこの lib が持つ。
# - Metrics-only PR が要るかの判定。worktree を作る前の絞り込み(_harness_loop_pr_metrics_only_maybe_due。ローカルの
#   記録の件数と開いている Loop PR)と、base を使った判定(_harness_loop_pr_metrics_only_due。origin/main に無い週の件数と
#   開いている Loop PR)の 2 段。gh の失敗は WARN を出して「要らない」に倒す。
# - 本文・選別の結果ファイル・Eval Case の依頼と結果を消すこと。消すのは次の場面だけで、失敗した run(選別の失敗・照合の
#   失敗・公開の失敗)のものは調べられるように残す。
#   - 選別の前(同じ日の前の run が残したもの。_harness_loop_pr_clear_review_files): 本文・結果ファイル・Eval Case の依頼と結果
#   - 選別を省いた週の Metrics-only PR の判定の前、公開した後、公開しない週の片付け: 本文と結果ファイルだけ
#   - 評価の前(_harness_loop_pr_evaluate_rules): Eval Case の結果だけ(選別の claude が置いたものを記録しないため)
# 入口ごとの手順と失敗の扱いの正本は、それぞれの入口の関数のコメント。本文の中身はこの lib では書かず、本文の lib
# (lib/harness-pr-body.bash)が書く。
#
# 入口の返り値は成功(公開した、変更が無かった、当日の PR が既にあった、Metrics-only PR が要らなかった)と失敗の 2 値。
# Integrity Snapshot の照合の失敗(HARNESS_INTEGRITY_FAILED)は入口の中で受け、外には出さない。失敗の理由と手で直す手順はこの lib がログに出す。
# 公開の手順が出す行は週次ジョブのログの行なので harness-weekly: で始め、この lib 自身の使い方の誤り
# (初期化の引数など)だけを harness-loop-pr: で出す。
#
# 週次ジョブは claude の起動前に、Integrity Snapshot の lib の後でこの lib だけを読み込み、この lib が読み込むときに
# Review Outcome の lib と本文の lib をこの順に読み込む(Integrity Snapshot の照合と関門、Review Outcome と本文の lib の
# 初期化と入口を使う。依存はこの lib から 2 つの lib への一方向で、2 つの lib はこの lib を読まない)。メモリに載った後は
# claude がファイルを書き換えてもその run に効かないので、Integrity Snapshot の一覧には載せない。週次ジョブが読み込むので、
# この lib は Guarded Path(scripts/guarded-paths.txt)に載せてある。
# ローカルの記録の置き場、判定の記録、Verdict の CLI・Rule Ledger と Eval Case のスクリプトのパスは、Integrity Snapshot の
# lib と同じく呼び出しのたびに $HOME から作る(3 つのスクリプトは harness_integrity_executables の行と一致しなければ実行されない)。
#
# Interface: harness_loop_pr_init / harness_loop_pr_review_instructions / harness_loop_pr_push_command /
# harness_loop_pr_create_command / harness_loop_pr_record_command / harness_loop_pr_run_review /
# harness_loop_pr_publish_metrics_only_if_due。
# 関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、失敗は明示的に返す。

# Review Outcome の lib と本文の lib を読み込む。読めなければ理由を出して 1 を返す(source の呼び出し元が止まる)。
# 素の source は、無い・構文エラー・空の lib で黙って落ちるので、無いか構文が壊れていないか、入口の関数が揃うかの順に
# 確かめる。本文の lib は Review Outcome の lib の節を使うので、その後に読む
_HARNESS_LOOP_PR_LIB_DIR=$(dirname "${BASH_SOURCE[0]}")
if [[ ! -r "$_HARNESS_LOOP_PR_LIB_DIR/harness-review-outcome.bash" ]] ||
    ! "$BASH" -n "$_HARNESS_LOOP_PR_LIB_DIR/harness-review-outcome.bash" 2>/dev/null; then
    printf 'harness-weekly: %s is missing or broken; run chezmoi apply\n' "$_HARNESS_LOOP_PR_LIB_DIR/harness-review-outcome.bash" >&2
    return 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness-review-outcome.bash
source "$_HARNESS_LOOP_PR_LIB_DIR/harness-review-outcome.bash" || return 1
if ! declare -F harness_review_outcome_init harness_review_outcome_result_instructions harness_review_outcome_classify \
    harness_review_outcome_sections >/dev/null; then
    printf 'harness-weekly: %s lacks the review outcome checks; run chezmoi apply\n' "$_HARNESS_LOOP_PR_LIB_DIR/harness-review-outcome.bash" >&2
    return 1
fi
if [[ ! -r "$_HARNESS_LOOP_PR_LIB_DIR/harness-pr-body.bash" ]] ||
    ! "$BASH" -n "$_HARNESS_LOOP_PR_LIB_DIR/harness-pr-body.bash" 2>/dev/null; then
    printf 'harness-weekly: %s is missing or broken; run chezmoi apply\n' "$_HARNESS_LOOP_PR_LIB_DIR/harness-pr-body.bash" >&2
    return 1
fi
# shellcheck source-path=SCRIPTDIR
# shellcheck source=harness-pr-body.bash
source "$_HARNESS_LOOP_PR_LIB_DIR/harness-pr-body.bash" || return 1
if ! declare -F harness_pr_body_init harness_pr_body_review_instructions harness_pr_body_adopted_titles harness_pr_body_review \
    harness_pr_body_metrics_only harness_pr_body_failed_review >/dev/null; then
    printf 'harness-weekly: %s lacks the PR body sections; run chezmoi apply\n' "$_HARNESS_LOOP_PR_LIB_DIR/harness-pr-body.bash" >&2
    return 1
fi

# 週の再発率の記録(1 週 1 ファイル)のリポジトリ内の置き場。週次ジョブの commit だけが書く
_HARNESS_LOOP_PR_RATES_REPO_DIR="docs/harness/failure-pattern-rates"
# Rule Ledger の記録のリポジトリ内の置き場。harness-rule-ledger.sh の export が書き出す先と同じでなければならない
_HARNESS_LOOP_PR_LEDGER_REPO_DIR="docs/harness/rule-ledger"
# origin/main に無い週の記録がこの件数たまったら、採用が無くても Metrics-only PR を作る
_HARNESS_LOOP_PR_METRICS_ONLY_WEEKS=4
# 週次ジョブ自身の commit が使う git の設定。launchd の環境には GIT_CONFIG_GLOBAL が無く(Claude Code の子プロセスには
# settings.json の env が渡す)、~/.gitconfig の署名は 1Password に頼るので、無人の run では止まる。Claude Code の git と
# 同じ設定(ローカルの署名鍵)を使う
_HARNESS_LOOP_PR_AGENT_GIT_CONFIG="$HOME/.config/git/claude-code.inc"

# run ごとの値。harness_loop_pr_init が入れる
_HARNESS_LOOP_PR_REPO=""
_HARNESS_LOOP_PR_WORKTREE=""
_HARNESS_LOOP_PR_BRANCH=""
_HARNESS_LOOP_PR_LOOP_BRANCH_PREFIX=""
_HARNESS_LOOP_PR_PR_BODY=""
_HARNESS_LOOP_PR_REVIEW_RESULT=""
_HARNESS_LOOP_PR_EVAL_REQUESTS=""
_HARNESS_LOOP_PR_EVAL_RESULTS=""
_HARNESS_LOOP_PR_EVAL_BUDGET_USD=""
_HARNESS_LOOP_PR_DATE=""
_HARNESS_LOOP_PR_RUN=""

# run ごとの値を受け取り、Review Outcome の lib と本文の lib を初期化する。引数は --repo <パス> --worktree <パス>
# --branch <ブランチ> --loop-branch-prefix <prefix> --pr-body <パス> --review-result <パス> --eval-requests <パス>
# --eval-results <パス> --eval-budget-usd <金額> --date <YYYY-MM-DD> --run <採用の印> --detections <パス>
# --detection-since <epoch> で、すべて必須。
# <Eval Case の依頼> は選別の claude に書かせるファイル(週次ジョブが選別の prompt にパスを書く)。<評価の結果> はこの lib の
# 評価の工程が書いて封印するファイルで、封印されたときだけ Rule Ledger の記録に渡す。<金額> は評価の予算。
# <検出件数の記録> と <epoch> は本文の検出件数の節に渡す(<epoch> は期間の始まり。週次ジョブが前の成功から決める)。
# 空の値と知らない引数は受け付けない。<ブランチ> は <prefix> で始まる
harness_loop_pr_init() {
    local repo="" worktree="" branch="" prefix="" pr_body="" review_result="" eval_requests="" eval_results="" eval_budget=""
    local date="" run="" detections="" since="" missing=""
    while [[ $# -gt 0 ]]; do
        if [[ $# -lt 2 ]]; then
            printf 'harness-loop-pr: %s needs a value\n' "$1" >&2
            return 1
        fi
        case $1 in
        --repo) repo=$2 ;;
        --worktree) worktree=$2 ;;
        --branch) branch=$2 ;;
        --loop-branch-prefix) prefix=$2 ;;
        --pr-body) pr_body=$2 ;;
        --review-result) review_result=$2 ;;
        --eval-requests) eval_requests=$2 ;;
        --eval-results) eval_results=$2 ;;
        --eval-budget-usd) eval_budget=$2 ;;
        --date) date=$2 ;;
        --run) run=$2 ;;
        --detections) detections=$2 ;;
        --detection-since) since=$2 ;;
        *)
            printf 'harness-loop-pr: unknown argument %s to harness_loop_pr_init\n' "$1" >&2
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
    [[ -n "$eval_requests" ]] || missing+=" --eval-requests"
    [[ -n "$eval_results" ]] || missing+=" --eval-results"
    [[ -n "$eval_budget" ]] || missing+=" --eval-budget-usd"
    [[ -n "$date" ]] || missing+=" --date"
    [[ -n "$run" ]] || missing+=" --run"
    [[ -n "$detections" ]] || missing+=" --detections"
    [[ -n "$since" ]] || missing+=" --detection-since"
    if [[ -n "$missing" ]]; then
        printf 'harness-loop-pr: harness_loop_pr_init needs a value for%s\n' "$missing" >&2
        return 1
    fi
    if [[ "$branch" != "$prefix"* ]]; then
        printf 'harness-loop-pr: branch %s does not start with the loop branch prefix %s\n' "$branch" "$prefix" >&2
        return 1
    fi
    # 公開に使う値は interface に出さないので、週次ジョブではなくここで確かめる。空の週数は数の比較で 0 と読まれ、
    # 記録の無い週にも Metrics-only PR を作ってしまう
    if [[ -z "${_HARNESS_LOOP_PR_RATES_REPO_DIR:-}" || -z "${_HARNESS_LOOP_PR_LEDGER_REPO_DIR:-}" ||
        -z "${_HARNESS_LOOP_PR_AGENT_GIT_CONFIG:-}" || ! "${_HARNESS_LOOP_PR_METRICS_ONLY_WEEKS:-}" =~ ^[1-9][0-9]*$ ]]; then
        printf 'harness-loop-pr: the publish values of this lib are empty or broken; run chezmoi apply\n' >&2
        return 1
    fi
    harness_review_outcome_init --worktree "$worktree" --review-result "$review_result" --pr-body "$pr_body" --run "$run" \
        --date "$date" --rates-repo-dir "$_HARNESS_LOOP_PR_RATES_REPO_DIR" --ledger-repo-dir "$_HARNESS_LOOP_PR_LEDGER_REPO_DIR" ||
        return 1
    harness_pr_body_init --pr-body "$pr_body" --worktree "$worktree" --review-result "$review_result" \
        --detections "$detections" --detection-since "$since" --run "$run" --ledger-repo-dir "$_HARNESS_LOOP_PR_LEDGER_REPO_DIR" ||
        return 1
    _HARNESS_LOOP_PR_REPO=$repo
    _HARNESS_LOOP_PR_WORKTREE=$worktree
    _HARNESS_LOOP_PR_BRANCH=$branch
    _HARNESS_LOOP_PR_LOOP_BRANCH_PREFIX=$prefix
    _HARNESS_LOOP_PR_PR_BODY=$pr_body
    _HARNESS_LOOP_PR_REVIEW_RESULT=$review_result
    _HARNESS_LOOP_PR_EVAL_REQUESTS=$eval_requests
    _HARNESS_LOOP_PR_EVAL_RESULTS=$eval_results
    _HARNESS_LOOP_PR_EVAL_BUDGET_USD=$eval_budget
    _HARNESS_LOOP_PR_DATE=$date
    _HARNESS_LOOP_PR_RUN=$run
}

# 選別の prompt に埋める指示の 2 行(末尾の改行なし。週次ジョブが 2 行目に続けて書く)。1 行目は結果ファイルの指示
# (Review Outcome の lib)、2 行目は本文の指示(本文の lib)に、記録の置き場に触れさせない指示を続けたもの。記録は
# 週次ジョブの commit だけが書く(改善する側が指標を書き換えられないように)。リポジトリ内の置き場への commit は Review Outcome
# の lib の分類が、ローカルの Rule Ledger の書き換えは Integrity Snapshot のデータの照合が見つける
harness_loop_pr_review_instructions() {
    local result_instructions body_instructions
    result_instructions=$(harness_review_outcome_result_instructions) || return 1
    body_instructions=$(harness_pr_body_review_instructions) || return 1
    printf '%s\n%s Never change files under %s or %s, or the local Rule Ledger in %s; this job commits them.' \
        "$result_instructions" "$body_instructions" "$_HARNESS_LOOP_PR_RATES_REPO_DIR" "$_HARNESS_LOOP_PR_LEDGER_REPO_DIR" \
        "$(_harness_loop_pr_local_ledger_dir)"
}

# ブランチを origin に push するコマンドを、末尾の改行なしで出す。<リポジトリ> を渡せば -C で指す。
# <リポジトリ> は案内文の読み手に合わせた表記(ログなら絶対パス、公開リポジトリの Issue なら ~ で書いたパス)
harness_loop_pr_push_command() { # <ブランチ> [<リポジトリ>]
    if [[ -n "${2:-}" ]]; then
        printf 'git -C %s push origin %s' "$2" "$1"
    else
        printf 'git push origin %s' "$1"
    fi
}

# draft PR を作るコマンドを、末尾の改行なしで出す。<本文> を渡せば --body-file で指す
harness_loop_pr_create_command() { # <ブランチ> [<本文のパス>]
    printf 'gh pr create --draft --base main --head %s' "$1"
    [[ -z "${2:-}" ]] || printf ' --body-file %s' "$2"
}

# 印 <run> の採用を PR の URL で記録するコマンドを、ログにそのまま貼れる 1 行で、末尾の改行なしで出す。
# 印は空白を含むのでシングルクォートで囲み、手書きの印に入りうる ' は '\'' に置き換える
harness_loop_pr_record_command() { # <run>
    local quote="'\\''"
    printf "bash ~/.claude/scripts/harness-verdict.sh publish --run '%s' --pr-url <PR URL>" "${1//\'/$quote}"
}

# 公開の手順が数えた件数。_harness_loop_pr_commit_rate_records と _harness_loop_pr_commit_ledger_records が入れる
_HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED=0
_HARNESS_LOOP_PR_LEDGER_RECORDS_COMMITTED=0
# _harness_loop_pr_push_and_create が作った PR の URL
_HARNESS_LOOP_PR_PR_URL=""

# 当日のブランチが origin にあるかを照会する。git ls-remote の終了コード(0: ある、2: 無い、ほか: 照会の失敗)を返す。
# 当日のブランチが origin にあるときの扱いは入口ごとに違うので、判定は入口が行う
_harness_loop_pr_branch_on_origin() {
    git -C "$_HARNESS_LOOP_PR_REPO" ls-remote --exit-code --heads origin "refs/heads/$_HARNESS_LOOP_PR_BRANCH" >/dev/null
}

# pnpm(と選別の claude が走らせる commit フックの prek・node)は mise の shims にしか無いマシンがある。launchd の PATH に
# shims が無いと pnpm install が「失敗」としか出ないので、worktree を作る前に原因を名指しして止める(plist の
# EnvironmentVariables の PATH)。<省くもの> は、失敗したときに入口が省くものを告げる語句で、失敗の行の末尾に付ける
_harness_loop_pr_require_pnpm() { # <省くもの>
    command -v pnpm >/dev/null 2>&1 && return 0
    printf 'harness-weekly: pnpm not found on PATH (%s); add the directory that holds it (e.g. ~/.local/share/mise/shims) to PATH in the launchd plist; %s\n' \
        "$PATH" "$1" >&2
    return 1
}

# worktree に依存を入れる。commit フック(prek)・just lint-fast・記録の整形(oxfmt)が node_modules を要る。
# <省くもの> は _harness_loop_pr_require_pnpm と同じ
_harness_loop_pr_install_dependencies() { # <省くもの>
    (cd "$_HARNESS_LOOP_PR_WORKTREE" && pnpm install --frozen-lockfile --prefer-offline) && return 0
    printf 'harness-weekly: pnpm install failed in %s; %s\n' "$_HARNESS_LOOP_PR_WORKTREE" "$1" >&2
    return 1
}

# worktree を準備する(_harness_loop_pr_make_worktree)。失敗したら入口から受け取った <失敗の行> を出して 1 を返す
_harness_loop_pr_prepare_worktree() { # <失敗の行>
    _harness_loop_pr_make_worktree && return 0
    printf '%s\n' "$1" >&2
    return 1
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
# その判定は fetch の要る新しい worktree(<worktree>.new)で行い、通ってから前回の
# worktree を消して置き換える。判定の前に消すと、失敗した run を調べるための状態を失う
_harness_loop_pr_make_worktree() {
    local ahead repo=$_HARNESS_LOOP_PR_REPO worktree=$_HARNESS_LOOP_PR_WORKTREE branch=$_HARNESS_LOOP_PR_BRANCH
    local fresh="$worktree.new"
    git -C "$repo" worktree remove --force "$fresh" >/dev/null 2>&1 || true
    rm -rf "$fresh"
    git -C "$repo" worktree add --quiet --force --detach "$fresh" HEAD || return 1
    git -C "$fresh" fetch --quiet origin main || return 1
    if git -C "$fresh" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
        ahead=$(git -C "$fresh" rev-list --count "FETCH_HEAD..refs/heads/$branch") || return 1
        if [[ "$ahead" -gt 0 ]]; then
            git -C "$repo" worktree remove --force "$fresh" >/dev/null 2>&1 || rm -rf "$fresh"
            printf 'harness-weekly: local branch %s in %s has %s commit(s) not on origin/main; push / open the PR by hand (PR body %s, if present) or delete the branch, then rerun\n' \
                "$branch" "$repo" "$ahead" "$_HARNESS_LOOP_PR_PR_BODY" >&2
            return 1
        fi
    fi
    git -C "$repo" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$worktree"
    git -C "$repo" worktree move --force "$fresh" "$worktree" || return 1
    git -C "$worktree" switch --quiet --no-track -C "$branch" FETCH_HEAD || {
        printf 'harness-weekly: could not reset branch %s (is it checked out in another worktree of %s?)\n' \
            "$branch" "$repo" >&2
        return 1
    }
}

# 週の再発率の記録のローカルの置き場(1 週 1 ファイル。全週を持つ)
_harness_loop_pr_local_rates_dir() {
    printf '%s\n' "$HOME/.claude/harness/failure-pattern-rates"
}

# Rule Ledger のローカルの置き場(1 採用 1 ファイル)
_harness_loop_pr_local_ledger_dir() {
    printf '%s\n' "$HOME/.claude/harness/rule-ledger"
}

_harness_loop_pr_rule_ledger() {
    printf '%s\n' "$HOME/.claude/scripts/harness-rule-ledger.sh"
}

_harness_loop_pr_verdict_cli() {
    printf '%s\n' "$HOME/.claude/scripts/harness-verdict.sh"
}

# 採用したルールの Eval Case を評価するスクリプト(ADR 0011)
_harness_loop_pr_eval_cases() {
    printf '%s\n' "$HOME/.claude/scripts/harness-eval-cases.sh"
}

# 判定の記録(Verdict の CLI が読み書きする)
_harness_loop_pr_archive() {
    printf '%s\n' "$HOME/.claude/harness/queue-archive.md"
}

# 週次ジョブ自身の commit に使う git。GIT_CONFIG_GLOBAL が無ければ _HARNESS_LOOP_PR_AGENT_GIT_CONFIG で署名する
_harness_loop_pr_git() {
    if [[ -z "${GIT_CONFIG_GLOBAL:-}" && -f "$_HARNESS_LOOP_PR_AGENT_GIT_CONFIG" ]]; then
        GIT_CONFIG_GLOBAL="$_HARNESS_LOOP_PR_AGENT_GIT_CONFIG" git "$@"
    else
        git "$@"
    fi
}

# ローカルの週の記録(<日付>.json)のパスを 1 行に 1 つ出す。置き場が無ければ何も出さない
_harness_loop_pr_local_rate_records() {
    local rates_dir file
    rates_dir=$(_harness_loop_pr_local_rates_dir) || return 1
    for file in "$rates_dir"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json; do
        [[ ! -f "$file" ]] || printf '%s\n' "$file"
    done
}

# worktree を <revision> に戻し、<置き場>(リポジトリ内のパス)に写しかけた追跡されていないファイルを消す
_harness_loop_pr_reset_worktree() { # <revision> <置き場>
    git -C "$_HARNESS_LOOP_PR_WORKTREE" reset --quiet --hard "$1" || return 1
    git -C "$_HARNESS_LOOP_PR_WORKTREE" clean --quiet -fd -- "$2" || return 1
}

_harness_loop_pr_remove_worktree() {
    git -C "$_HARNESS_LOOP_PR_REPO" worktree remove --force "$_HARNESS_LOOP_PR_WORKTREE" >/dev/null 2>&1 ||
        rm -rf "$_HARNESS_LOOP_PR_WORKTREE"
}

# ローカルの週の記録のうち、base(origin/main)の _HARNESS_LOOP_PR_RATES_REPO_DIR に無いものを出す。閉じた PR や
# 未マージの PR に入っていた週も、origin/main に無ければ出す(ローカルの印では判定しない)。
# この run の日付の記録だけは、origin/main にあっても中身が違えば出す。同じ日の再実行がその日の記録を
# 書き直すため(harness-failure-rates.sh の since)。リポジトリ側は oxfmt を通してあるので、バイト列では
# なく JSON として比べ、どちらかが JSON として読めなければ違うものとして出す。ほかの日付は中身を比べない:
# origin/main の記録を人が直したときにローカルの古い写しで戻さないためと、前の週の claude が書き換えた
# 記録(この run のハッシュでは見つけられない。_harness_loop_pr_commit_rate_records)でマージ済みの記録を上書きしないため。
# 再実行が選別を省いた(当日のブランチが origin にある)週は、書き直した記録はローカルにだけ残る
_harness_loop_pr_uncommitted_rate_records() { # <base>
    local base=$1 files file committed local_record
    files=$(_harness_loop_pr_local_rate_records) || return 1
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        if ! git -C "$_HARNESS_LOOP_PR_WORKTREE" cat-file -e "$base:$_HARNESS_LOOP_PR_RATES_REPO_DIR/${file##*/}" 2>/dev/null; then
            printf '%s\n' "$file"
        elif [[ "${file##*/}" == "$_HARNESS_LOOP_PR_DATE.json" ]]; then
            if ! committed=$(git -C "$_HARNESS_LOOP_PR_WORKTREE" show "$base:$_HARNESS_LOOP_PR_RATES_REPO_DIR/${file##*/}" | jq -S -c . 2>/dev/null) ||
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
# oxfmt を通すのは、commit フックが JSON の書式を検査するため。写した件数を _HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED に入れる
_harness_loop_pr_commit_rate_records() { # <base>
    local base=$1 files file
    _HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED=0
    harness_integrity_check_data || return "$HARNESS_INTEGRITY_FAILED"
    files=$(_harness_loop_pr_uncommitted_rate_records "$base") || return 1
    [[ -n "$files" ]] || return 0
    mkdir -p "$_HARNESS_LOOP_PR_WORKTREE/$_HARNESS_LOOP_PR_RATES_REPO_DIR" || return 1
    while IFS= read -r file; do
        cp "$file" "$_HARNESS_LOOP_PR_WORKTREE/$_HARNESS_LOOP_PR_RATES_REPO_DIR/" || return 1
        _HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED=$((_HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED + 1))
    done <<<"$files"
    (cd "$_HARNESS_LOOP_PR_WORKTREE" && pnpm exec oxfmt "$_HARNESS_LOOP_PR_RATES_REPO_DIR") || return 1
    git -C "$_HARNESS_LOOP_PR_WORKTREE" add -- "$_HARNESS_LOOP_PR_RATES_REPO_DIR" || return 1
    _harness_loop_pr_git -C "$_HARNESS_LOOP_PR_WORKTREE" commit --quiet -m "harness: Failure Pattern の再発率の週の記録を足す" || return 1
}

# Rule Ledger の commit に失敗したときに、worktree を <revision> に戻して写しかけの記録を消す。記録はローカルに残る
_harness_loop_pr_drop_ledger_commit() { # <revision>
    printf 'harness-weekly: WARN failed to commit the Rule Ledger records; they stay in %s for a later PR\n' "$(_harness_loop_pr_local_ledger_dir)" >&2
    _harness_loop_pr_reset_worktree "$1" "$_HARNESS_LOOP_PR_LEDGER_REPO_DIR"
}

# base(origin/main)に無いローカルの Rule Ledger の記録を worktree に写し、週次ジョブの commit 1 つにする。
# 写す記録の選び方(マージされた PR と、この run の PR の記録だけ)と仕事の識別子の検査・伏せ字は
# harness-rule-ledger.sh export が行う。選別の claude には書かせない(週次ジョブが選別の commit を、写す直前の
# データの照合がローカルの記録を確かめる)。写した件数を _HARNESS_LOOP_PR_LEDGER_RECORDS_COMMITTED に入れる。
# 失敗しても記録はローカルに残り、後の PR が足す。照合に落ちたら HARNESS_INTEGRITY_FAILED を返す
_harness_loop_pr_commit_ledger_records() { # <base> [この run の PR の番号]
    local base=$1 rule_ledger output count pr_args=()
    _HARNESS_LOOP_PR_LEDGER_RECORDS_COMMITTED=0
    [[ -z "${2:-}" ]] || pr_args=(--pr "$2")
    harness_integrity_check_data || return "$HARNESS_INTEGRITY_FAILED"
    rule_ledger=$(_harness_loop_pr_rule_ledger) || return 1
    # identity leak guard のローカルのパターン(gitignore 済み)は worktree に無いので、リポジトリ本体のものを渡す。
    # export は書き出した形を rule-ledger/exported/ に残す(封印しない)ので、この後にデータを照合しないこと
    output=$(SENSITIVE_PATTERNS_LOCAL="${SENSITIVE_PATTERNS_LOCAL-$_HARNESS_LOOP_PR_REPO/scripts/sensitive-patterns.local.txt}" \
        harness_integrity_run "$rule_ledger" export --base "$base" --worktree "$_HARNESS_LOOP_PR_WORKTREE" ${pr_args[@]+"${pr_args[@]}"}) || return $?
    printf '%s\n' "$output"
    count=$(sed -n 's/^harness-rule-ledger: exported \([0-9][0-9]*\) record(s)$/\1/p' <<<"$output")
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    [[ "$count" -gt 0 ]] || return 0
    (cd "$_HARNESS_LOOP_PR_WORKTREE" && pnpm exec oxfmt "$_HARNESS_LOOP_PR_LEDGER_REPO_DIR") || return 1
    git -C "$_HARNESS_LOOP_PR_WORKTREE" add -- "$_HARNESS_LOOP_PR_LEDGER_REPO_DIR" || return 1
    _harness_loop_pr_git -C "$_HARNESS_LOOP_PR_WORKTREE" commit --quiet -m "harness: Rule Ledger の記録を足す" || return 1
    _HARNESS_LOOP_PR_LEDGER_RECORDS_COMMITTED=$count
}

# 公開(push と gh pr create)の直前の関門。照合の失敗を取りこぼした呼び出し元があっても、書き換えられた run の PR を作らない
_harness_loop_pr_trusted_before() { # <これから行う操作>
    harness_integrity_gate && return 0
    printf 'harness-weekly: stopped before %s on %s; no PR created, because the scripts the job runs could not be trusted\n' "$1" "$_HARNESS_LOOP_PR_BRANCH" >&2
    # gh pr create の直前で止まったときはブランチが origin にあり、同じ日の再実行は手で PR を作るよう案内してしまう
    [[ "$1" != 'gh pr create' ]] ||
        printf 'harness-weekly: %s is already on origin; do not open a PR from it as it is. Find what changed the scripts, then delete the branch (git push origin --delete %s)\n' \
            "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_BRANCH" >&2
    return 1
}

# 関門 → push → 関門 → draft PR の作成。作った PR の URL を _HARNESS_LOOP_PR_PR_URL に入れる。失敗したら手で公開する
# 案内を出して 1 を返し、worktree・ローカルブランチ・本文は残す(手で公開するときに使う)。
# <案内の続き> は PR の作成に失敗したときの案内の末尾に足す文(PR を作った後に入口がすることを手で行う手順)
_harness_loop_pr_push_and_create() { # <PR のタイトル> [<案内の続き>]
    local title=$1 hint=${2:-} url
    _HARNESS_LOOP_PR_PR_URL=""
    _harness_loop_pr_trusted_before push || return 1
    git -C "$_HARNESS_LOOP_PR_WORKTREE" push --quiet origin "HEAD:refs/heads/$_HARNESS_LOOP_PR_BRANCH" || {
        printf 'harness-weekly: push of %s failed; no PR created. To publish by hand: %s, then %s\n' \
            "$_HARNESS_LOOP_PR_BRANCH" "$(harness_loop_pr_push_command "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_REPO")" \
            "$(harness_loop_pr_create_command "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_PR_BODY")" >&2
        return 1
    }
    _harness_loop_pr_trusted_before 'gh pr create' || return 1
    url=$(cd "$_HARNESS_LOOP_PR_WORKTREE" && gh pr create --draft --base main --head "$_HARNESS_LOOP_PR_BRANCH" \
        --title "$title" --body-file "$_HARNESS_LOOP_PR_PR_BODY") || {
        printf 'harness-weekly: pushed %s but gh pr create failed; open the PR by hand with %s%s\n' \
            "$_HARNESS_LOOP_PR_BRANCH" "$(harness_loop_pr_create_command "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_PR_BODY")" "$hint" >&2
        return 1
    }
    # gh は URL を最後の行に出す
    _HARNESS_LOOP_PR_PR_URL=${url##*$'\n'}
}

# PR を作った後の後片付け。ブランチは origin にあるので、worktree とローカルのブランチを消す(残すと週ごとに溜まる)
_harness_loop_pr_cleanup_published() {
    _harness_loop_pr_remove_worktree
    git -C "$_HARNESS_LOOP_PR_REPO" branch --quiet -D "$_HARNESS_LOOP_PR_BRANCH" >/dev/null 2>&1 ||
        printf 'harness-weekly: WARN could not delete local branch %s in %s\n' "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_REPO" >&2
}

# 開いている Loop PR(ブランチが初期化で受け取った prefix で始まる)の URL を出す。無ければ空。gh が失敗すれば非 0
_harness_loop_pr_open_loop_pr() {
    local prefix
    # prefix は JSON の文字列にして式に埋める(gh の --jq は --arg を取れない)
    prefix=$(jq -n --arg prefix "$_HARNESS_LOOP_PR_LOOP_BRANCH_PREFIX" '$prefix') || return 1
    (cd "$_HARNESS_LOOP_PR_REPO" && gh pr list --state open --json headRefName,url \
        --jq "[.[] | select(.headRefName | startswith($prefix))][0].url // empty")
}

# 開いている Loop PR が無ければ 0。あれば <書式> に <引数> と PR の URL(最後の %s)を当てて出し、1 を返す。
# gh が失敗すれば WARN を出して 1 を返す(Metrics-only PR は作らない側に倒す)
_harness_loop_pr_no_open_loop_pr() { # <書式> [<引数>...]
    local format=$1 open_pr
    shift
    open_pr=$(_harness_loop_pr_open_loop_pr) || {
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
_harness_loop_pr_metrics_only_maybe_due() {
    local rates_dir records local_count
    rates_dir=$(_harness_loop_pr_local_rates_dir) || return 1
    records=$(_harness_loop_pr_local_rate_records) || return 1
    local_count=$(grep -c . <<<"$records" || true)
    if [[ "$local_count" -lt "$_HARNESS_LOOP_PR_METRICS_ONLY_WEEKS" ]]; then
        printf 'harness-weekly: at most %s weekly failure rate record(s) not on origin/main; carried over in %s (a metrics-only PR needs %s)\n' \
            "$local_count" "$rates_dir" "$_HARNESS_LOOP_PR_METRICS_ONLY_WEEKS"
        return 1
    fi
    _harness_loop_pr_no_open_loop_pr 'harness-weekly: loop PR %s is open; weekly failure rate records carried over\n'
}

# Metrics-only PR が要るかの 2 段目。origin/main に無い週の記録(<base> は worktree の origin/main)が
# _HARNESS_LOOP_PR_METRICS_ONLY_WEEKS 件以上あり、開いている Loop PR が無ければ 0。要らなければ理由を出して 1 を返す
_harness_loop_pr_metrics_only_due() { # <base>
    local base=$1 count
    count=$(_harness_loop_pr_uncommitted_rate_records "$base" | grep -c . || true)
    if [[ "$count" -lt "$_HARNESS_LOOP_PR_METRICS_ONLY_WEEKS" ]]; then
        printf 'harness-weekly: %s weekly failure rate record(s) not on origin/main; carried over in %s (a metrics-only PR needs %s)\n' \
            "$count" "$(_harness_loop_pr_local_rates_dir)" "$_HARNESS_LOOP_PR_METRICS_ONLY_WEEKS"
        return 1
    fi
    _harness_loop_pr_no_open_loop_pr 'harness-weekly: %s weekly failure rate record(s) not on origin/main, but loop PR %s is open; carried over\n' \
        "$count"
}

# 判定の記録で、この run の選別の採用(初期化で受け取った印)を PR の URL に置き換える(Verdict の CLI の publish)。
# 置き換えが 0 件になるのは、陳腐化の修正だけの PR(正常)か、選別が settle で記録しなかったときで、
# ここでは区別できないので、両方の読み方を添えて知らせる。失敗しても WARN だけにする(残った印は週次ジョブの
# finish_run が捕まえる)。Integrity Snapshot の照合に落ちたら、CLI を呼ばずに HARNESS_INTEGRITY_FAILED を返す
_harness_loop_pr_record_pr_url() { # <PR の URL>
    local verdict_cli count status=0
    verdict_cli=$(_harness_loop_pr_verdict_cli) || status=1
    [[ "$status" -ne 0 ]] || count=$(harness_integrity_run "$verdict_cli" publish --run "$_HARNESS_LOOP_PR_RUN" --pr-url "$1") || status=$?
    [[ "$status" -ne "$HARNESS_INTEGRITY_FAILED" ]] || return "$status"
    if [[ "$status" -ne 0 ]]; then
        printf 'harness-weekly: WARN failed to record the PR URL in %s; finish_run reports the unpublished verdicts\n' "$(_harness_loop_pr_archive)" >&2
        return 0
    fi
    if [[ "$count" == 0 ]]; then
        printf 'harness-weekly: no verdict adopted in run "%s" in %s; PR URL not recorded (normal if the PR only fixes stale rules; otherwise the review did not record its verdicts with the settle command)\n' \
            "$_HARNESS_LOOP_PR_RUN" "$(_harness_loop_pr_archive)" >&2
        return 0
    fi
    printf 'harness-weekly: recorded the PR URL on %s verdict(s)\n' "$count"
}

# PR を作った後に、この run の採用を Rule Ledger に記録し、base に無い記録(マージされた PR から持ち越した分を
# 含む)を週次ジョブの commit で足して push し直す。PR 番号は PR を作るまで決まらないので、PR を作る前の
# commit には入れられない。照合のほかで失敗しても PR と採用の公開は止めない: 記録はローカルに残り、この PR が
# マージされた後に PR を作る run が足す。記録そのもの(record)に失敗したときは、判定の記録の
# PR の URL を持つ採用から手で作り直せる。Integrity Snapshot の照合に落ちたら、記録を足さずに HARNESS_INTEGRITY_FAILED を返す
_harness_loop_pr_record_ledger() { # <base> <PR の URL>
    local base=$1 url=$2 pushed_revision rule_ledger output status=0 id ledger_dir results=()
    ledger_dir=$(_harness_loop_pr_local_ledger_dir)
    rule_ledger=$(_harness_loop_pr_rule_ledger) || return 0
    pushed_revision=$(git -C "$_HARNESS_LOOP_PR_WORKTREE" rev-parse HEAD) || return 0
    # 評価の工程が書いて封印した結果だけを渡す。評価が失敗した run では渡さず、採用を「測っていない」として
    # 記録する(選別の claude が置いた偽の得点を記録しない)。封印の後の書き換えは次のデータの照合が見つける
    if harness_integrity_sealed "$_HARNESS_LOOP_PR_EVAL_RESULTS"; then
        results=(--results "$_HARNESS_LOOP_PR_EVAL_RESULTS")
    fi
    # record は分類の記録と評価の結果から記録を作るので、その直前にデータを照合する
    harness_integrity_check_data || return "$HARNESS_INTEGRITY_FAILED"
    output=$(harness_integrity_run "$rule_ledger" record --pr-url "$url" --date "$_HARNESS_LOOP_PR_DATE" --via weekly ${results[@]+"${results[@]}"}) ||
        status=$?
    [[ -z "$output" ]] || printf '%s\n' "$output"
    [[ "$status" -ne "$HARNESS_INTEGRITY_FAILED" ]] || return "$status"
    [[ "$status" -eq 0 ]] ||
        printf 'harness-weekly: WARN failed to record the adoptions of %s in the Rule Ledger %s; record them by hand with bash %s record --pr-url %s --date %s --via weekly\n' \
            "$url" "$ledger_dir" "$rule_ledger" "$url" "$_HARNESS_LOOP_PR_DATE" >&2
    # record が作った記録だけを封印する(それ以外に増えた記録はデータの照合が追加として見つける)
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        harness_integrity_seal "$ledger_dir/$id.json" || return "$HARNESS_INTEGRITY_FAILED"
    done <<<"$(sed -n 's/^harness-rule-ledger: recorded \([^ ][^ ]*\)$/\1/p' <<<"$output")"
    status=0
    _harness_loop_pr_commit_ledger_records "$base" "${url##*/}" || status=$?
    if [[ "$status" -ne 0 ]]; then
        # PR は作成済みなので、戻せなくても失敗にしない(worktree は後片付けが消す)
        _harness_loop_pr_drop_ledger_commit "$pushed_revision" || true
        [[ "$status" -ne "$HARNESS_INTEGRITY_FAILED" ]] || return "$status"
        return 0
    fi
    [[ "$_HARNESS_LOOP_PR_LEDGER_RECORDS_COMMITTED" -gt 0 ]] || return 0
    harness_integrity_gate || return "$HARNESS_INTEGRITY_FAILED"
    if git -C "$_HARNESS_LOOP_PR_WORKTREE" push --quiet origin "HEAD:refs/heads/$_HARNESS_LOOP_PR_BRANCH"; then
        printf 'harness-weekly: committed %s Rule Ledger record(s) to %s\n' "$_HARNESS_LOOP_PR_LEDGER_RECORDS_COMMITTED" "$url"
    else
        printf 'harness-weekly: WARN push of the Rule Ledger records to %s failed; they stay in %s for a PR after this one merges\n' \
            "$_HARNESS_LOOP_PR_BRANCH" "$ledger_dir" >&2
    fi
}

# 本文と選別の結果ファイルを消す。<パス> を渡せば一緒に消す。消す場面と、失敗した run のものを残す理由はこの lib のヘッダ
_harness_loop_pr_remove_review_files() { # [<パス>…]
    rm -f "$_HARNESS_LOOP_PR_PR_BODY" "$_HARNESS_LOOP_PR_REVIEW_RESULT" "$@"
}

# 選別の commit(1 件以上)を Loop PR として公開する。worktree と依存は用意済みで、本文は _harness_loop_pr_publish_review_outcome が
# 本文の lib の harness_pr_body_review で書き終えている前提(純増を記録の commit より前に数えるため)。
# 手順: 再発率の記録の commit → 関門 → push → 関門 → PR の作成 → 本文と結果ファイルを消す → 判定の記録への URL の
# 置き換え → Rule Ledger の記録・封印・commit・関門・再 push → 後片付け。失敗の扱い:
# - 再発率の記録が照合に落ちた: PR を作らずに失敗する(書き換えられた記録を正として持ち越さないよう、人に見せる)
# - 再発率の記録をほかの理由で commit できなかった: WARN を出し、写しかけを戻して公開を続ける(記録はローカルに残り、
#   次の PR がまとめて足す)
# - 関門・push・PR の作成の失敗: 案内を出して失敗し、worktree・ローカルブランチ・本文を残す
# - PR を作った後の照合の失敗(URL の置き換えか Rule Ledger の記録): 後片付けをしたうえで PR を残して失敗する
#   (heartbeat で健全に見せない)。それ以外の失敗は WARN にとどめる
_harness_loop_pr_publish_review() { # <base>
    local base=$1 commits commit_status=0 post_status=0
    commits=$(git -C "$_HARNESS_LOOP_PR_WORKTREE" rev-list --count "$base..HEAD") || return 1
    _harness_loop_pr_commit_rate_records "$base" || commit_status=$?
    if [[ "$commit_status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        printf 'harness-weekly: no PR created; check %s by hand\n' "$(_harness_loop_pr_local_rates_dir)" >&2
        return 1
    elif [[ "$commit_status" -eq 0 ]]; then
        [[ "$_HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED" -eq 0 ]] ||
            printf 'harness-weekly: committed %s weekly failure rate record(s)\n' "$_HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED"
    else
        printf 'harness-weekly: WARN failed to commit the weekly failure rate records; they stay in %s for the next PR\n' \
            "$(_harness_loop_pr_local_rates_dir)" >&2
        _harness_loop_pr_reset_worktree HEAD "$_HARNESS_LOOP_PR_RATES_REPO_DIR" || return 1
    fi
    _harness_loop_pr_push_and_create "harness: 週次レビュー $_HARNESS_LOOP_PR_DATE" \
        ", then record its URL with $(harness_loop_pr_record_command "$_HARNESS_LOOP_PR_RUN")" || return 1
    printf 'harness-weekly: opened draft PR %s (%s commit(s))\n' "$_HARNESS_LOOP_PR_PR_URL" "$commits"
    _harness_loop_pr_remove_review_files
    _harness_loop_pr_record_pr_url "$_HARNESS_LOOP_PR_PR_URL" || post_status=$?
    [[ "$post_status" -ne 0 ]] || _harness_loop_pr_record_ledger "$base" "$_HARNESS_LOOP_PR_PR_URL" || post_status=$?
    _harness_loop_pr_cleanup_published
    if [[ "$post_status" -ne 0 ]]; then
        printf 'harness-weekly: opened %s, but the scripts or records the job uses after it could not be trusted; check the PR and the Rule Ledger by hand\n' \
            "$_HARNESS_LOOP_PR_PR_URL" >&2
        return 1
    fi
}

# 採用の無い週に、週の記録だけの draft PR(Metrics-only PR)を作る。worktree と依存は用意済みの前提。
# 手順: 再発率の記録の commit(できなければ PR を作らずに失敗) → 持ち越した Rule Ledger の記録の commit(照合に
# 落ちたら PR を作らずに失敗し、ほかの失敗は戻して続ける) → 本文(本文の lib の harness_pr_body_metrics_only に
# commit した件数を渡す) → 関門 → push → 関門 → PR の作成 → 後片付け。本文を記録の commit の後に書く理由は、本文の lib の
# その入口のコメント。本文の lib が非 0 を返したら PR を作らずに失敗する(PR を作らない理由は本文の lib が出す)。
# 関門・push・PR の作成の失敗は _harness_loop_pr_publish_review と同じく、案内を出して失敗し、worktree・ローカルブランチ・本文を残す
_harness_loop_pr_publish_metrics_only() { # <base>
    local base=$1 rate_records_revision status=0
    _harness_loop_pr_commit_rate_records "$base" || {
        printf 'harness-weekly: failed to commit the weekly failure rate records in %s; no PR created\n' "$_HARNESS_LOOP_PR_WORKTREE" >&2
        return 1
    }
    rate_records_revision=$(git -C "$_HARNESS_LOOP_PR_WORKTREE" rev-parse HEAD) || return 1
    _harness_loop_pr_commit_ledger_records "$base" || status=$?
    if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        printf 'harness-weekly: the Rule Ledger records could not be trusted; no PR created\n' >&2
        return 1
    fi
    [[ "$status" -eq 0 ]] || _harness_loop_pr_drop_ledger_commit "$rate_records_revision" || return 1
    harness_pr_body_metrics_only "$_HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED" "$_HARNESS_LOOP_PR_LEDGER_RECORDS_COMMITTED" || return 1
    _harness_loop_pr_push_and_create "harness: 週次の指標 $_HARNESS_LOOP_PR_DATE" || return 1
    printf 'harness-weekly: opened metrics-only draft PR %s (%s weekly record(s))\n' "$_HARNESS_LOOP_PR_PR_URL" "$_HARNESS_LOOP_PR_RATE_RECORDS_COMMITTED"
    _harness_loop_pr_remove_review_files
    _harness_loop_pr_cleanup_published
    return 0
}

# 公開しない週の片付け。本文・選別の結果ファイル・worktree を消す。ローカルのブランチは消さない(公開しない週の
# ブランチは origin/main から切ったままで、次の run の worktree の準備が作り直す)。worktree を消せなければ 1 を返す
_harness_loop_pr_discard() {
    _harness_loop_pr_remove_review_files || return 1
    _harness_loop_pr_remove_worktree
}

# 採用の無い週の振り分け。選別を省いた週(harness_loop_pr_publish_metrics_only_if_due)と、選別が何も commit しなかった週
# (_harness_loop_pr_publish_review_outcome)が共有する。要否の 2 段目で要れば <要るときの行>(空なら出さない)を出し、
# <要ると決まった後のコマンド> を行ってから Metrics-only PR を作る。要らなければ <要らないときの行>(空なら出さない)を出して、
# 公開しないで片付けて成功する。片付けの失敗は run を失敗させない(worktree は次の run の準備が作り直す)
_harness_loop_pr_metrics_only_or_discard() { # <base> <要らないときの行> <要るときの行> [<要ると決まった後のコマンド> [<引数>…]]
    local base=$1 not_due_line=$2 due_line=$3
    shift 3
    if ! _harness_loop_pr_metrics_only_due "$base"; then
        [[ -z "$not_due_line" ]] || printf '%s\n' "$not_due_line"
        _harness_loop_pr_discard || true
        return 0
    fi
    [[ -z "$due_line" ]] || printf '%s\n' "$due_line"
    if [[ $# -gt 0 ]]; then
        "$@" || return 1
    fi
    _harness_loop_pr_publish_metrics_only "$base"
}

# 選別を省いた週(queue が空)の入口。Metrics-only PR が要れば作る。手順: 要否の 1 段目(worktree を作る前の絞り込み) →
# 当日のブランチの origin への照会 → pnpm の確認 → worktree の準備 → 前の run の本文と結果ファイルを消す(消せなくても、
# 本文は Metrics-only PR を作るときに書き直す) → 要否の 2 段目(_harness_loop_pr_metrics_only_or_discard) → 要れば
# 依存のインストール → Metrics-only PR。依存は要ると決まった後にだけ入れる。当日のブランチが origin にあれば、その日の
# PR は作成済みか手で作るのを待っているので作らない(照会の失敗も WARN を出して作らない)。
# 返り値は 0(作ったか、要らなかった)と 1(前提の確認・準備・公開の失敗)
harness_loop_pr_publish_metrics_only_if_due() {
    local remote_status=0 base skipped='no metrics-only PR'
    _harness_loop_pr_metrics_only_maybe_due || return 0
    _harness_loop_pr_branch_on_origin || remote_status=$?
    if [[ "$remote_status" -ne 2 ]]; then
        [[ "$remote_status" -eq 0 ]] ||
            printf 'harness-weekly: WARN failed to query origin for %s (git ls-remote exit %s); no metrics-only PR this week\n' \
                "$_HARNESS_LOOP_PR_BRANCH" "$remote_status" >&2
        return 0
    fi
    _harness_loop_pr_require_pnpm "$skipped" || return 1
    _harness_loop_pr_prepare_worktree \
        "harness-weekly: failed to prepare the worktree $_HARNESS_LOOP_PR_WORKTREE for a metrics-only PR" || return 1
    base=$(git -C "$_HARNESS_LOOP_PR_WORKTREE" rev-parse HEAD) || return 1
    _harness_loop_pr_remove_review_files || true
    _harness_loop_pr_metrics_only_or_discard "$base" '' '' _harness_loop_pr_install_dependencies "$skipped"
}

# 選別の前に、本文・選別の結果ファイル・Eval Case の依頼と結果を消す。同じ日の前の run が残したものを、この run の
# ものとして読まないため。worktree の準備の判定を通った後に呼ぶ(手で公開すべき commit が残っている間は、
# その PR に使う本文を残す)
_harness_loop_pr_clear_review_files() {
    _harness_loop_pr_remove_review_files "$_HARNESS_LOOP_PR_EVAL_REQUESTS" "$_HARNESS_LOOP_PR_EVAL_RESULTS"
}

# 採用したルールの Eval Case を評価し、効果の節を _HARNESS_LOOP_PR_EVAL_SECTION に入れる(本文に足すのは本文の lib)。採用した
# のに結果にも免除にも無いものは、節が名前で出す(依頼が無ければ全件がそうなる)。評価の工程の失敗は WARN にとどめて
# PR の公開は止めず、節を空のまま本文の lib に渡す(lib が効果を測っていないことを書く)。照合に落ちたら
# HARNESS_INTEGRITY_FAILED を返す。封印はこの lib と Integrity Snapshot の lib のシェル変数に持つので、$( ) の外で呼ぶ
_HARNESS_LOOP_PR_EVAL_SECTION=""
_harness_loop_pr_evaluate_rules() {
    local adopted="$HOME/.claude/harness/.eval-adopted-$_HARNESS_LOOP_PR_DATE" eval_cases section status=0
    _HARNESS_LOOP_PR_EVAL_SECTION=""
    eval_cases=$(_harness_loop_pr_eval_cases)
    harness_pr_body_adopted_titles >"$adopted" || status=$?
    if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        rm -f "$adopted"
        return "$status"
    elif [[ "$status" -ne 0 ]]; then
        printf 'harness-weekly: WARN could not read the adopted verdicts from %s for the eval section\n' "$(_harness_loop_pr_archive)" >&2
        : >"$adopted"
    fi
    if [[ ! -f "$_HARNESS_LOOP_PR_EVAL_REQUESTS" ]]; then
        printf 'harness-weekly: review wrote no eval requests %s; the PR body lists every adopted rule as unevaluated\n' "$_HARNESS_LOOP_PR_EVAL_REQUESTS"
        printf '{"cases": []}\n' >"$_HARNESS_LOOP_PR_EVAL_REQUESTS"
    fi
    # 結果のファイルは選別の claude も置けるので、評価の前に消し、評価が成功したときだけ封印して Rule Ledger に
    # 渡す(_harness_loop_pr_record_ledger は封印したものだけを渡し、データの照合が封印の後の書き換えを見つける)
    rm -f "$_HARNESS_LOOP_PR_EVAL_RESULTS" || return 1
    status=0
    HARNESS_EVAL_BUDGET_USD="$_HARNESS_LOOP_PR_EVAL_BUDGET_USD" harness_integrity_run "$eval_cases" run \
        --requests "$_HARNESS_LOOP_PR_EVAL_REQUESTS" --date "$_HARNESS_LOOP_PR_DATE" --out "$_HARNESS_LOOP_PR_EVAL_RESULTS" || status=$?
    [[ "$status" -ne 0 ]] ||
        section=$(harness_integrity_run "$eval_cases" section --results "$_HARNESS_LOOP_PR_EVAL_RESULTS" --adopted "$adopted") || status=$?
    if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        rm -f "$adopted"
        return "$status"
    elif [[ "$status" -eq 0 ]]; then
        _HARNESS_LOOP_PR_EVAL_SECTION=$section
        harness_integrity_seal "$_HARNESS_LOOP_PR_EVAL_RESULTS" || {
            rm -f "$adopted"
            return "$HARNESS_INTEGRITY_FAILED"
        }
    else
        printf 'harness-weekly: WARN evaluating the eval cases with %s failed; the PR body says so\n' "$eval_cases" >&2
    fi
    rm -f "$adopted"
}

# 選別の claude が成功し、データの照合も通った run の振り分け。選別が残したものの分類(Review Outcome の lib の
# harness_review_outcome_classify)で振り分ける:
#   - no-change → 成功。PR は作らない(deploy-only だけの週を含む)。ただし origin/main に無い週の再発率の記録が
#     たまっていれば、Metrics-only PR を作る(選別を省いた週と同じ判定。_harness_loop_pr_metrics_only_or_discard)
#   - publish → Eval Case を評価し、本文の lib の harness_pr_body_review で本文に節を足し、_harness_loop_pr_publish_review で
#     PR を作る。評価を本文より先に行っても、入口(harness_integrity_run)は呼ぶたびに実行物の全部を照合するので、
#     推移の節のスクリプトが書き換えられた run は評価の前に止まる
#   - failed と、分類の照合の失敗 → 失敗(理由は Review Outcome の lib が出す。照合の失敗は Integrity Snapshot の lib が
#     書き換えを出し、ここで PR を作らないことを出す)
# 公開の手順が失敗したとき(push か PR の作成の失敗など。扱いは _harness_loop_pr_publish_review のコメント)も失敗にする。
# commit 0 件で成功する週は本文を PR にしないので捨てる(採用も陳腐化の修正も無い週の本文は件数と残った陳腐化だけで、
# 次の選別がまた数える)。失敗の経路では worktree・本文・結果ファイルを残す(調べられるように。worktree は次の
# 実行が作り直す)。採用した項目は既に判定の記録に移っているので、push か PR の作成が失敗した run の commit は
# リポジトリのローカルブランチから手で push / PR を作る(案内は公開の手順が出す)
_harness_loop_pr_publish_review_outcome() { # <base>
    local base=$1 outcome outcome_status=0
    # データの照合は工程の入口が選別の claude の直後に済ませており、落ちた run はここに来ない(_harness_loop_pr_report_failed_review)。
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
        _harness_loop_pr_metrics_only_or_discard "$base" 'harness-weekly: review committed no changes; no PR created' \
            'harness-weekly: review committed no changes; opening a metrics-only PR'
        return
        ;;
    *) return 1 ;;
    esac
    _harness_loop_pr_evaluate_rules || {
        printf 'harness-weekly: no PR created; the evaluation could not be trusted\n' >&2
        return 1
    }
    harness_pr_body_review "$base" "$_HARNESS_LOOP_PR_EVAL_SECTION" || return 1
    _harness_loop_pr_publish_review "$base"
}

# 選別の claude が失敗した(予算切れを含む)run と、claude の成否に関わらず照合に落ちた run の後始末の案内。claude は commit や
# 判定の記録への移動を済ませてから失敗しうるので、残った commit の場所と手で PR を作る手順をログに出す(データの照合に
# 落ちた run では、手順の代わりにそのまま公開しないよう案内する)。worktree・本文・結果ファイルは残す(次の実行が worktree を
# 作り直すが、worktree の準備(_harness_loop_pr_make_worktree)は origin/main に無い commit を持つ当日のブランチを作り直さない)。Deploy-only Fix の
# 記録と、commit が無い run の案内は Review Outcome の lib が分類のときに行う。結果ファイルは選別の前に消してあるので
# (_harness_loop_pr_clear_review_files)、lib が読むのはこの run の claude が書いたものだけ。
# commit が残っていれば、手で作る PR の本文にも節を足す(本文の lib の harness_pr_body_failed_review)
_harness_loop_pr_report_failed_review() { # <base> <データを信頼できるか(1/0)>
    local base=$1 data_trusted=$2 claude=failed outcome commits trusted=1
    [[ "$data_trusted" -eq 1 ]] || claude=untrusted
    outcome=$(harness_review_outcome_classify "$base" "$claude") || return 0
    [[ "$outcome" == failed-with-commits ]] || return 0
    commits=$(git -C "$_HARNESS_LOOP_PR_WORKTREE" rev-list --count "$base..HEAD" 2>/dev/null || printf '?')
    # 本文の節は本文の lib が足す。データか再発率のスクリプトを信頼できなければ、手で公開する手順の代わりに、
    # 書き換えを確かめてから commit を読み直すよう案内する
    harness_pr_body_failed_review "$data_trusted" || trusted=0
    if [[ "$trusted" -eq 0 ]]; then
        printf 'harness-weekly: review failed after %s commit(s) on local branch %s (worktree %s), and the scripts or records the job uses were changed (or could not be checked) after the claude runs started; do not publish the branch as it is. Restore them, find what changed them, and review the commits before publishing them by hand\n' \
            "$commits" "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_WORKTREE" >&2
        return 0
    fi
    printf 'harness-weekly: review failed after %s commit(s) on local branch %s (worktree %s, PR body %s); verdicts adopted in this run may already be in %s. To publish by hand: %s, then %s, then %s\n' \
        "$commits" "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_WORKTREE" "$_HARNESS_LOOP_PR_PR_BODY" "$(_harness_loop_pr_archive)" \
        "$(harness_loop_pr_push_command "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_REPO")" \
        "$(harness_loop_pr_create_command "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_PR_BODY")" \
        "$(harness_loop_pr_record_command "$_HARNESS_LOOP_PR_RUN")" >&2
}

# 選別の claude の後の振り分け。<終了コード> は選別の claude を通した Integrity Snapshot の工程の入口
# (harness_integrity_run_untrusted)の終了コード。<base> は選別の前の worktree の HEAD。
#   - 0: 選別が残したものを振り分けて公開する(_harness_loop_pr_publish_review_outcome)
#   - HARNESS_INTEGRITY_FAILED: 照合に落ちた。claude が成功していても失敗した選別として扱い(入口の終了コードからは claude の
#     成否が分からない)、PR は作らず、手で公開する手順も案内しない
#   - ほかの非 0: 選別の claude が失敗した。残った commit を手で公開する手順を案内する
# 失敗した選別の案内は _harness_loop_pr_report_failed_review。返り値は 0 と 1 だけ(予約コードを外に出さない)
_harness_loop_pr_conclude_review() { # <base> <終了コード>
    local base=$1 stage_status=$2
    if [[ "$stage_status" -eq 0 ]]; then
        _harness_loop_pr_publish_review_outcome "$base" || return 1
        return 0
    fi
    _harness_loop_pr_report_failed_review "$base" "$((stage_status == HARNESS_INTEGRITY_FAILED ? 0 : 1))"
    return 1
}

# 選別の claude を走らせる <コマンド> を、worktree の中で、採用の印を環境変数 HARNESS_REVIEW_RUN に入れたサブシェルで
# 実行する(ADR 0017。印は選別の claude にだけ渡し、抽出・分類・評価には渡さない。prompt には書かない)
_harness_loop_pr_run_in_worktree() { # <コマンド> [<引数>…]
    (cd "$_HARNESS_LOOP_PR_WORKTREE" && export HARNESS_REVIEW_RUN="$_HARNESS_LOOP_PR_RUN" && "$@")
}

# 選別の経路の入口。<コマンド>(選別の claude を走らせる関数と引数)を受け取り、手順は:
#   1. 当日のブランチの origin への照会。ブランチがあれば選別を起動しない。その日の Loop PR は作成済みか、push 後に PR の
#      作成が失敗している(その run のログが手で開くよう促しているか、公開の直前の関門で止まってブランチを消すよう促して
#      いる)。作り直したブランチは non-fast-forward で push できず、選別の費用が無駄になる。PR があれば成功、PR が無ければ
#      健全に見せないよう失敗する。照会の失敗も失敗
#   2. pnpm の確認 → <開始の行>(週次ジョブの run の識別子を含む行)をログに出す → worktree の準備 → 前回の本文・結果ファイル・
#      Eval Case の依頼と結果を消す → 依存のインストール。依存を claude に入れさせないのは、失敗したときに予算を使って
#      直そうとさせないため(commit フックと just lint-fast が node_modules を要るので、claude の前に入れる)
#   3. <コマンド> を Integrity Snapshot の工程の入口(harness_integrity_run_untrusted)を通して実行する
#      (_harness_loop_pr_run_in_worktree)。<コマンド> の終了コードを claude の成否とみなす。工程の入口が、claude の成否に
#      関わらず直後にデータを照合する。失敗で終わる経路も repo に写す工程を通らないので、照合しないと書き換えがログに
#      出ないまま次の run のスナップショットが正として持ち越す
#   4. 振り分けと公開、または失敗した選別の案内(_harness_loop_pr_conclude_review)
# 返り値は 0(公開した、変更が無かった、当日の PR が既にあった、Metrics-only PR が要らなかった)と 1(失敗)
harness_loop_pr_run_review() { # <開始の行> <コマンド> [<引数>…]
    local start_line=${1:-} remote_status=0 existing_pr base stage_status=0 skipped='skipped review'
    if [[ $# -lt 2 || -z "$start_line" ]]; then
        printf 'harness-loop-pr: harness_loop_pr_run_review needs <start line> and the command that runs the review\n' >&2
        return 1
    fi
    shift
    _harness_loop_pr_branch_on_origin || remote_status=$?
    if [[ "$remote_status" -eq 0 ]]; then
        existing_pr=$(cd "$_HARNESS_LOOP_PR_REPO" && gh pr list --head "$_HARNESS_LOOP_PR_BRANCH" --state all --json url --jq '.[0].url // empty') || {
            printf 'harness-weekly: %s exists on origin but listing its PR failed; skipped review\n' "$_HARNESS_LOOP_PR_BRANCH" >&2
            return 1
        }
        if [[ -z "$existing_pr" ]]; then
            printf 'harness-weekly: %s exists on origin but has no PR; skipped review. Check the log of the run that pushed it: if it stopped before gh pr create because the scripts could not be trusted, delete the branch (git push origin --delete %s); otherwise open the PR by hand (%s)\n' \
                "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_BRANCH" "$(harness_loop_pr_create_command "$_HARNESS_LOOP_PR_BRANCH" "$_HARNESS_LOOP_PR_PR_BODY")" >&2
            return 1
        fi
        printf 'harness-weekly: %s already exists on origin (PR %s); skipped review\n' "$_HARNESS_LOOP_PR_BRANCH" "$existing_pr"
        return 0
    elif [[ "$remote_status" -ne 2 ]]; then
        printf 'harness-weekly: failed to query origin for %s (git ls-remote exit %s)\n' "$_HARNESS_LOOP_PR_BRANCH" "$remote_status" >&2
        return 1
    fi
    _harness_loop_pr_require_pnpm "$skipped" || return 1
    printf '%s\n' "$start_line"
    _harness_loop_pr_prepare_worktree "harness-weekly: failed to prepare the review worktree $_HARNESS_LOOP_PR_WORKTREE" || return 1
    _harness_loop_pr_clear_review_files || return 1
    base=$(git -C "$_HARNESS_LOOP_PR_WORKTREE" rev-parse HEAD) || return 1
    _harness_loop_pr_install_dependencies "$skipped" || return 1
    harness_integrity_run_untrusted _harness_loop_pr_run_in_worktree "$@" || stage_status=$?
    _harness_loop_pr_conclude_review "$base" "$stage_status"
}
