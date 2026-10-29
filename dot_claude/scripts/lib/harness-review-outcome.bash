#!/usr/bin/env bash
# 週次ジョブ(harness-weekly.sh)の Review Outcome(GLOSSARY.md)の module。source 専用。set は呼び出し側に従う
# (set -euo pipefail 下で動く)。
#
# 持つもの:
# - 選別の結果ファイルの契約: 選別の claude への指示文(harness_review_outcome_result_instructions)、形の検査と要素の整形。
#   形は {"dropped": [...], "deploy_only": [...]} で、要素は 1 行の文字列。Dropped Change と Deploy-only Fix の判定は
#   PR の本文の有無ではなくこのファイルで行う(採用 0 件の週の本文にも指標などが載りうるため)。
# - Deploy-only Fix の記録(~/.claude/harness/deploy-only.md への日付の見出し付きの追記)。結果ファイルを読めた時点で、
#   どの失敗の判定よりも先に残す。
# - 選別が残したもの(worktree・結果ファイル・queue・判定の記録・本文)の分類(harness_review_outcome_classify)。
# - 結果ファイル由来の本文の 2 節(harness_review_outcome_sections)。本文への追記は呼び出し側が行う。
# 持たないもの: Metrics-only PR の要否と公開、ほかの本文の節、手で公開する手順の案内(どれも Loop PR の module)。
#
# 分類の値(標準出力に 1 行)と Loop PR の module の振り分け:
#   publish              本文の節を足して公開する
#   no-change            Metrics-only PR の要否を Loop PR の module に尋ねる(要らなければ片付けて成功)
#   failed               失敗(理由は stderr に出る。git と jq 自身の失敗は、そのコマンドのエラー文だけになる)
#   failed-with-commits  選別の claude が失敗した(か照合に落ちた)が commit が残っている。Loop PR の module が案内を出す
# Verdict の CLI の照合に落ちたら値を出さずに HARNESS_INTEGRITY_FAILED(3)で終わる。使い方の誤りは 2。
# 理由の行は週次ジョブのログの行なので harness-weekly: で始め、この lib 自身の使い方の誤りだけを harness-review-outcome: で出す。
#
# 週次ジョブは claude の起動前に、Integrity Snapshot の lib の後で Loop PR の module(lib/harness-loop-pr.bash)を読み込み、その module が
# この lib を読み込む(harness_integrity_run を使う)。分類を呼ぶのも、初期化を呼んで記録の置き場を渡すのも Loop PR の module だけ。
# メモリに載った後は claude がファイルを書き換えてもその run に効かないので、Integrity Snapshot の一覧には載せない。週次ジョブが読み込むので Guarded Path(scripts/guarded-paths.txt)に載せてある。
# queue・判定の記録・Deploy-only Fix の記録・Verdict の CLI のパスは、呼び出しのたびに $HOME から作る(Verdict の CLI は
# harness_integrity_executables の行と一致しなければ実行されない)。
#
# Interface: harness_review_outcome_init / harness_review_outcome_result_instructions / harness_review_outcome_classify /
# harness_review_outcome_sections。関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、失敗は明示的に返す。

# run ごとの値。harness_review_outcome_init が入れる
_HARNESS_REVIEW_OUTCOME_WORKTREE=""
_HARNESS_REVIEW_OUTCOME_RESULT=""
_HARNESS_REVIEW_OUTCOME_PR_BODY=""
_HARNESS_REVIEW_OUTCOME_RUN=""
_HARNESS_REVIEW_OUTCOME_DATE=""
_HARNESS_REVIEW_OUTCOME_RATES_REPO_DIR=""
_HARNESS_REVIEW_OUTCOME_LEDGER_REPO_DIR=""

_harness_review_outcome_queue() {
    printf '%s\n' "$HOME/.claude/harness/queue.md"
}

_harness_review_outcome_archive() {
    printf '%s\n' "$HOME/.claude/harness/queue-archive.md"
}

_harness_review_outcome_deploy_only() {
    printf '%s\n' "$HOME/.claude/harness/deploy-only.md"
}

_harness_review_outcome_verdict_cli() {
    printf '%s\n' "$HOME/.claude/scripts/harness-verdict.sh"
}

_harness_review_outcome_usage() {
    printf 'harness-review-outcome: %s\n' "$1" >&2
    return 2
}

# harness_review_outcome_init --worktree <dir> --review-result <file> --pr-body <file> --run <採用の印> --date <YYYY-MM-DD>
#   --rates-repo-dir <週の再発率の記録のリポジトリ内の置き場> --ledger-repo-dir <Rule Ledger の記録のリポジトリ内の置き場>
# 置き場は、選別の commit が触れてはいけない(週次ジョブだけが commit する)パス
harness_review_outcome_init() {
    local worktree="" result="" pr_body="" run="" date="" rates_dir="" ledger_dir=""
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || {
            _harness_review_outcome_usage "init: $1 needs a value"
            return
        }
        case "$1" in
        --worktree) worktree=$2 ;;
        --review-result) result=$2 ;;
        --pr-body) pr_body=$2 ;;
        --run) run=$2 ;;
        --date) date=$2 ;;
        --rates-repo-dir) rates_dir=$2 ;;
        --ledger-repo-dir) ledger_dir=$2 ;;
        *)
            _harness_review_outcome_usage "init: unknown argument $1"
            return
            ;;
        esac
        shift 2
    done
    if [[ -z "$worktree" || -z "$result" || -z "$pr_body" || -z "$run" || -z "$date" || -z "$rates_dir" || -z "$ledger_dir" ]]; then
        _harness_review_outcome_usage 'init needs --worktree, --review-result, --pr-body, --run, --date, --rates-repo-dir and --ledger-repo-dir'
        return
    fi
    _HARNESS_REVIEW_OUTCOME_WORKTREE=$worktree
    _HARNESS_REVIEW_OUTCOME_RESULT=$result
    _HARNESS_REVIEW_OUTCOME_PR_BODY=$pr_body
    _HARNESS_REVIEW_OUTCOME_RUN=$run
    _HARNESS_REVIEW_OUTCOME_DATE=$date
    _HARNESS_REVIEW_OUTCOME_RATES_REPO_DIR=$rates_dir
    _HARNESS_REVIEW_OUTCOME_LEDGER_REPO_DIR=$ledger_dir
}

_harness_review_outcome_ready() {
    [[ -n "$_HARNESS_REVIEW_OUTCOME_RESULT" ]] || _harness_review_outcome_usage 'call harness_review_outcome_init first'
}

# 選別の prompt に埋める、結果ファイルを書かせる指示の 1 行
harness_review_outcome_result_instructions() {
    _harness_review_outcome_ready || return
    printf '%s\n' "- Always write the result file ${_HARNESS_REVIEW_OUTCOME_RESULT} before you finish, even if nothing happened: a JSON object {\"dropped\": [...], \"deploy_only\": [...]} whose elements are one-line strings (in Japanese). In \"dropped\", put each dropped change with its queue title and the failing hook or lint check; in \"deploy_only\", each deploy-only fix with what to apply and why. Use empty arrays when there are none. This job decides whether the run failed from this file, not from the PR body."
}

# 結果ファイルが決めた形(object で、dropped と deploy_only が文字列の配列)かを確かめる。
# キーの欠落を空配列として読まない(jq の .dropped | length は null に 0 を返す)
_harness_review_outcome_result_valid() {
    jq -e 'type == "object"
    and (.dropped | type == "array") and (.deploy_only | type == "array")
    and all(.dropped[], .deploy_only[]; type == "string")' "$_HARNESS_REVIEW_OUTCOME_RESULT" >/dev/null 2>&1
}

# 結果ファイルの配列 1 つの要素を、1 行の文字列に整えて出す。改行は空白に潰し(リストを
# 崩さないため)、前後の空白と、claude が付けた箇条書きの印(「- 」「* 」)を外す。空になった
# 要素は捨てる(中身の無い項目を deploy-only.md に足したり、Dropped Change と数えたりしない)
# shellcheck disable=SC2016 # $key は jq の変数
_HARNESS_REVIEW_OUTCOME_ITEMS_FILTER='.[$key][] | gsub("[\r\n]+"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "")
| sub("^[-*](\\s+|$)"; "") | select(length > 0)'

# 整えた要素を Markdown のリストにする
_harness_review_outcome_items() { # <key>
    jq -r --arg key "$1" "$_HARNESS_REVIEW_OUTCOME_ITEMS_FILTER"' | "- " + .' "$_HARNESS_REVIEW_OUTCOME_RESULT"
}

_harness_review_outcome_count() { # <key>
    jq -r --arg key "$1" "[$_HARNESS_REVIEW_OUTCOME_ITEMS_FILTER] | length" "$_HARNESS_REVIEW_OUTCOME_RESULT"
}

# queue の項目の数。読めない queue は空の出力になる(grep の失敗も || true で通す。呼び出し側が数でないことを確かめる)
_harness_review_outcome_queue_entries() {
    local queue
    queue=$(_harness_review_outcome_queue)
    if [[ -f "$queue" ]]; then
        grep -c '^## ' "$queue" || true
    else
        printf '0\n'
    fi
}

# Deploy-only Fix を日付の見出し付きで追記する。既に同じ行があるものと、同じ結果ファイルの中で重なったものは
# 足さない(失敗した run の後に同じ日・次の週に再実行すると、同じ修正がまた報告されるため)。記録した旨の行は
# stderr に出す(分類の値は $( ) で受け取られるので、stdout に混ぜない)
_harness_review_outcome_record_deploy_only() {
    local items item new_items="" count=0 deploy_only
    deploy_only=$(_harness_review_outcome_deploy_only)
    items=$(_harness_review_outcome_items deploy_only) || return 1
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        if [[ -f "$deploy_only" ]] && grep -qxF -- "$item" "$deploy_only"; then
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
    if [[ -f "$deploy_only" ]] && [[ "$(grep '^## ' "$deploy_only" | tail -n 1)" == "## $_HARNESS_REVIEW_OUTCOME_DATE" ]]; then
        printf '%s\n' "$new_items" >>"$deploy_only" || return 1
    else
        printf '## %s\n\n%s\n' "$_HARNESS_REVIEW_OUTCOME_DATE" "$new_items" >>"$deploy_only" || return 1
    fi
    printf 'harness-weekly: recorded %s deploy-only fix(es) in %s; apply them by hand, then delete it\n' \
        "$count" "$deploy_only" >&2
}

# 結果ファイルの申告(dropped)を、ジョブが自分で観測できる事実と突き合わせる。claude が採用を
# 落としたのに "dropped": [] と書いた週を、成功として扱わないため。
#   - harness-review は処理した項目をすべて判定の記録に移すので、queue に残ってよいのは落とした
#     変更だけ。残数が dropped の件数より多ければ、申告しなかった項目がある
#   - 判定の記録にこの run の採用(Verdict の CLI の adopted)があるのに commit が 0 件なら、採用を commit していない。
#     陳腐化の修正には印が付かないので、採用と区別できる。Loop PR の module が印を置き換える前に呼ぶ
# 項目はタイトルではなく件数で比べる(commit の件名に queue のタイトルがそのまま入る保証は無い)。
# そのため、採用の一部だけを commit せず陳腐化の修正の commit で件数が埋まる週は見分けられない。
# dropped の要素は queue の項目ではなく変更の単位なので、queue に項目を持たない陳腐化の修正を
# dropped に入れると件数がかさ上げされ、申告しなかった項目が同じ数だけ残っていても見分けられない。
# 逆に複数の項目を 1 つの変更にまとめて落とすと、正しく申告した週でも失敗する。
# 選別の最中に対話セッションの /harness-reflect が queue に足した項目も残数に数えるので、その週は
# 誤って失敗する(成功を偽るより安全なので受け入れる)。
# 返り値: 0 = 合う、1 = 食い違うか読めない、HARNESS_INTEGRITY_FAILED = Verdict の CLI の照合に落ちた
_harness_review_outcome_check_claims() { # <commit の件数> <dropped の件数>
    local commits=$1 dropped_count=$2 remaining titles marks status=0 queue archive
    queue=$(_harness_review_outcome_queue)
    archive=$(_harness_review_outcome_archive)
    remaining=$(_harness_review_outcome_queue_entries)
    if [[ ! "$remaining" =~ ^[0-9]+$ ]]; then
        printf 'harness-weekly: failed to count the entries in %s; no PR created\n' "$queue" >&2
        return 1
    fi
    if [[ "$remaining" -gt "$dropped_count" ]]; then
        printf 'harness-weekly: review left %s entr(ies) in %s but reported %s dropped change(s) in %s (an entry was neither moved to %s nor reported as dropped); no PR created\n' \
            "$remaining" "$queue" "$dropped_count" "$_HARNESS_REVIEW_OUTCOME_RESULT" "$archive" >&2
        return 1
    fi
    [[ "$commits" -eq 0 ]] || return 0
    titles=$(harness_integrity_run "$(_harness_review_outcome_verdict_cli)" adopted --run "$_HARNESS_REVIEW_OUTCOME_RUN") || status=$?
    if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        return "$HARNESS_INTEGRITY_FAILED"
    elif [[ "$status" -ne 0 ]]; then
        printf 'harness-weekly: failed to read the adopted verdicts from %s; no PR created\n' "$archive" >&2
        return 1
    fi
    if [[ -n "$titles" ]]; then
        marks=$(printf '%s\n' "$titles" | wc -l | tr -d ' ')
        printf 'harness-weekly: %s has %s verdict(s) adopted in run "%s" but the review committed nothing (an adopted change was not committed and not reported as dropped); no PR created\n' \
            "$archive" "$marks" "$_HARNESS_REVIEW_OUTCOME_RUN" >&2
        return 1
    fi
}

# 選別の claude が成功し、データも信頼できる run の分類。判定は結果ファイルと commit の数で行い、本文の有無は
# Dropped Change の判定に使わない(本文には採用 0 件の週にも指標などが載りうるため)。
#   - commit 0 件・dropped が空 → no-change(deploy-only だけの週を含む)
#   - commit 0 件・dropped が空でない → failed(すべてが Dropped Change)
#   - dropped の申告が queue と判定の記録の観測と食い違う → failed
#   - commit 1 件以上 → publish。dropped は queue に残っており、次の選別にかけ直される
# 次はどれも failed: commit されていない変更が残った / 結果ファイルが無いか決めた形でない / commit があるのに本文が無い /
# 選別の commit が週の再発率の記録か Rule Ledger の置き場に触れた(どちらも週次ジョブだけが書く)。
# 置き場の検査は費用のかかる評価より前に済ませるため、Loop PR の module の公開の手順ではなくここで行う。
# Deploy-only Fix は、結果ファイルを読めた時点で、未 commit の変更を含むどの失敗の判定よりも先に残す
_harness_review_outcome_classify_ok() { # <base>
    local base=$1 worktree=$_HARNESS_REVIEW_OUTCOME_WORKTREE commits dropped_count dropped_items touched dir status=0
    if ! _harness_review_outcome_result_valid; then
        printf 'harness-weekly: review did not write a valid result file %s (a JSON object with string arrays "dropped" and "deploy_only"); no PR created\n' \
            "$_HARNESS_REVIEW_OUTCOME_RESULT" >&2
        printf 'failed\n'
        return 0
    fi
    _harness_review_outcome_record_deploy_only || {
        printf 'harness-weekly: failed to record deploy-only fixes from %s in %s\n' "$_HARNESS_REVIEW_OUTCOME_RESULT" "$(_harness_review_outcome_deploy_only)" >&2
        printf 'failed\n'
        return 0
    }
    if [[ -n "$(git -C "$worktree" status --porcelain)" ]]; then
        printf 'harness-weekly: review left uncommitted changes in %s; no PR created\n' "$worktree" >&2
        printf 'failed\n'
        return 0
    fi
    commits=$(git -C "$worktree" rev-list --count "$base..HEAD") || {
        printf 'failed\n'
        return 0
    }
    dropped_count=$(_harness_review_outcome_count dropped) || {
        printf 'failed\n'
        return 0
    }
    if [[ "$commits" -eq 0 && "$dropped_count" -gt 0 ]]; then
        dropped_items=$(_harness_review_outcome_items dropped) || dropped_items=""
        printf 'harness-weekly: review dropped %s change(s) and committed nothing (a commit hook or lint failed; the entries stay in the queue); no PR created. Dropped (see %s):\n%s\n' \
            "$dropped_count" "$_HARNESS_REVIEW_OUTCOME_RESULT" "$dropped_items" >&2
        printf 'failed\n'
        return 0
    fi
    _harness_review_outcome_check_claims "$commits" "$dropped_count" || status=$?
    if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        return "$HARNESS_INTEGRITY_FAILED"
    elif [[ "$status" -ne 0 ]]; then
        printf 'failed\n'
        return 0
    fi
    if [[ "$commits" -eq 0 ]]; then
        printf 'no-change\n'
        return 0
    fi
    if [[ ! -s "$_HARNESS_REVIEW_OUTCOME_PR_BODY" ]]; then
        printf 'harness-weekly: review made %s commit(s) but wrote no PR body; no PR created\n' "$commits" >&2
        printf 'failed\n'
        return 0
    fi
    for dir in "$_HARNESS_REVIEW_OUTCOME_RATES_REPO_DIR" "$_HARNESS_REVIEW_OUTCOME_LEDGER_REPO_DIR"; do
        touched=$(git -C "$worktree" diff --name-only "$base" HEAD -- "$dir") || {
            printf 'failed\n'
            return 0
        }
        if [[ -n "$touched" ]]; then
            if [[ "$dir" == "$_HARNESS_REVIEW_OUTCOME_RATES_REPO_DIR" ]]; then
                printf 'harness-weekly: review commits touched %s (only this job writes the weekly failure rate records); no PR created\n' "$dir" >&2
            else
                printf 'harness-weekly: review commits touched %s (only this job writes the Rule Ledger); no PR created\n' "$dir" >&2
            fi
            printf 'failed\n'
            return 0
        fi
    done
    printf 'publish\n'
}

# 選別の claude が失敗した(予算切れを含む)run と、claude の成否に関わらず照合に落ちた run の分類。claude は結果ファイルを
# 書いてから失敗しうるので、結果ファイルが決めた形なら Deploy-only Fix はここでも残す(記録の失敗は分類を止めない)。
# commit が無ければ理由を出して failed、あるか数えられなければ failed-with-commits(手で公開する手順か、公開しない案内は
# Loop PR の module が出す)。照合に落ちた run は claude が成功していてもここに来るので、claude の失敗と読める文面を出さない
_harness_review_outcome_classify_failed() { # <base> <failed|untrusted>
    local base=$1 claude=$2 worktree=$_HARNESS_REVIEW_OUTCOME_WORKTREE commits archive
    archive=$(_harness_review_outcome_archive)
    if [[ -f "$_HARNESS_REVIEW_OUTCOME_RESULT" ]] && _harness_review_outcome_result_valid; then
        _harness_review_outcome_record_deploy_only ||
            printf 'harness-weekly: failed to record deploy-only fixes from %s in %s\n' "$_HARNESS_REVIEW_OUTCOME_RESULT" "$(_harness_review_outcome_deploy_only)" >&2
    fi
    commits=$(git -C "$worktree" rev-list --count "$base..HEAD" 2>/dev/null || printf '?')
    if [[ "$commits" != "0" ]]; then
        printf 'failed-with-commits\n'
        return 0
    fi
    if [[ "$claude" == untrusted ]]; then
        printf 'harness-weekly: review made no commits, and the records the job uses were changed (or could not be checked) after the claude runs started; restore them and find what changed them. Worktree %s kept; verdicts already moved to %s stay there\n' \
            "$worktree" "$archive" >&2
    else
        printf 'harness-weekly: review failed before committing; worktree %s kept; verdicts already moved to %s stay there\n' \
            "$worktree" "$archive" >&2
    fi
    printf 'failed\n'
}

# harness_review_outcome_classify <base> <ok|failed|untrusted>
#   <base> は選別の前の worktree の HEAD。ok は選別の claude が成功しデータの照合も通った run、failed は claude が失敗した run、
#   untrusted は照合に落ちた run(claude の成否を問わない)
harness_review_outcome_classify() {
    _harness_review_outcome_ready || return
    [[ $# -eq 2 && -n "$1" ]] || {
        _harness_review_outcome_usage 'classify needs <base> and <ok|failed|untrusted>'
        return
    }
    case "$2" in
    ok) _harness_review_outcome_classify_ok "$1" ;;
    failed | untrusted) _harness_review_outcome_classify_failed "$1" "$2" ;;
    *) _harness_review_outcome_usage "classify: unknown claude status $2" ;;
    esac
}

# PR の本文に付ける Dropped Change と Deploy-only Fix の節。claude には本文に書かせず、結果ファイルから作る。
# 結果ファイルが無いか決めた形でなければ何も出さない
harness_review_outcome_sections() {
    local dropped deploy_only deploy_only_file
    _harness_review_outcome_ready || return
    [[ -f "$_HARNESS_REVIEW_OUTCOME_RESULT" ]] && _harness_review_outcome_result_valid || return 0
    deploy_only_file=$(_harness_review_outcome_deploy_only)
    dropped=$(_harness_review_outcome_items dropped) || return 1
    deploy_only=$(_harness_review_outcome_items deploy_only) || return 1
    if [[ -n "$dropped" ]]; then
        printf '\n## 落とした変更\n\ncommit フックか lint を通せずに commit しなかった変更。queue に残してあり、次の選別にかけ直す。\n\n%s\n' "$dropped"
    fi
    if [[ -n "$deploy_only" ]]; then
        # 本文は公開リポジトリの PR になるので、ローカルアカウント名を含む $HOME を ~ で書く
        printf '\n## deploy-only の修正\n\nこの PR の commit では直らず、人が適用して初めて効く修正。%s にも記録した(適用したら消す)。\n\n%s\n' \
            "~${deploy_only_file#"$HOME"}" "$deploy_only"
    fi
}
