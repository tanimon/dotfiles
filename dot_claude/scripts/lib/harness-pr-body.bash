#!/usr/bin/env bash
# 週次ジョブ(harness-weekly.sh)が作る Loop PR の本文の module。source 専用。set は呼び出し側に従う
# (set -euo pipefail 下で動く)。
#
# 持つもの:
# - 本文の 3 種類それぞれの組み立て: 採用のある Loop PR(harness_pr_body_review)、Metrics-only PR
#   (harness_pr_body_metrics_only。Loop PR の module が記録の commit の後に呼ぶ)、選別の claude が commit の後に失敗した run の
#   手で公開するための本文(harness_pr_body_failed_review)。節の順序と節ごとの失敗の扱いの正本はそれぞれの入口のコメント。
# - ジョブが足す節: Review Outcome の節の取り込み、失敗の検出件数、Failure Pattern の再発率の推移、評価が失敗したときの
#   ルールの効果、純増、Rule Ledger。
# - この run の採用の見出しの読み取り(harness_pr_body_adopted_titles)。Rule Ledger の節と、Loop PR の module の評価の節の材料。
# - 選別の prompt の、本文に書かせるものと書かせないものの指示(harness_pr_body_review_instructions)。ジョブが足す節を
#   claude に書かせないための一覧なので、節を足すときはここも直す。
# 持たないもの: 本文の先頭(選別の claude が書く)、Eval Case の評価の実行と結果の封印(Loop PR の module。成功した評価の節の
# 文字列を受け取るだけ)、Dropped Change と Deploy-only Fix の節の中身(Review Outcome の lib)、本文を消すこと(Loop PR の module)、
# 失敗の検出と推移の節の中身(再発率のスクリプト。この lib は run の日付を渡して節の文字列を受け取る。検出件数の記録の
# 読み方と期間も持たない)。
#
# 返り値は 0(成功)・1(失敗)・2(この lib の使い方の誤り)・HARNESS_INTEGRITY_FAILED(Integrity Snapshot の照合に
# 落ちた)。ただし harness_pr_body_adopted_titles は Verdict の CLI の終了コードをそのまま返す(CLI の引数の誤りも 2)。
# 指標の節(失敗の検出と推移)は、照合のほかで失敗したら WARN を出して節を省き、成功を返す。PR を作る本文の入口
# (harness_pr_body_review と harness_pr_body_metrics_only)が非 0 を返すときは、PR を作らない理由の行をこの lib が出す。
# 出す行は週次ジョブのログの行なので harness-weekly: で始め、この lib 自身の使い方の誤りだけを harness-pr-body: で出す。
#
# 週次ジョブが claude の起動前に読み込む Loop PR の module(lib/harness-loop-pr.bash)が、Review Outcome の lib の後でこの lib を
# 読み込む(harness_integrity_run・harness_review_outcome_sections を使う)。入口を呼ぶのは Loop PR の module だけで、初期化も
# その初期化が呼び、Rule Ledger の記録の置き場もそこから受け取る。メモリに載った後は
# claude がファイルを書き換えてもその run に効かないので、Integrity Snapshot の一覧には載せない。週次ジョブが読み込むので
# Guarded Path(scripts/guarded-paths.txt)に載せてある。判定の記録・再発率のスクリプト・Verdict の CLI のパスは、呼び出しの
# たびに $HOME から作る(2 つのスクリプトは harness_integrity_executables の行と一致しなければ実行されない)。
#
# Interface: harness_pr_body_init / harness_pr_body_review_instructions / harness_pr_body_adopted_titles /
# harness_pr_body_review / harness_pr_body_metrics_only / harness_pr_body_failed_review。関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、
# 失敗は明示的に返す。

# run ごとの値。harness_pr_body_init が入れる
_HARNESS_PR_BODY_FILE=""
_HARNESS_PR_BODY_WORKTREE=""
_HARNESS_PR_BODY_REVIEW_RESULT=""
_HARNESS_PR_BODY_DATE=""
_HARNESS_PR_BODY_RUN=""
_HARNESS_PR_BODY_LEDGER_REPO_DIR=""

_harness_pr_body_archive() {
    printf '%s\n' "$HOME/.claude/harness/queue-archive.md"
}

_harness_pr_body_failure_rates() {
    printf '%s\n' "$HOME/.claude/scripts/harness-failure-rates.sh"
}

_harness_pr_body_verdict_cli() {
    printf '%s\n' "$HOME/.claude/scripts/harness-verdict.sh"
}

_harness_pr_body_usage() {
    printf 'harness-pr-body: %s\n' "$1" >&2
    return 2
}

# harness_pr_body_init --pr-body <file> --worktree <dir> --review-result <file> --date <YYYY-MM-DD>
#   --run <採用の印> --ledger-repo-dir <Rule Ledger の記録のリポジトリ内の置き場>
# <YYYY-MM-DD> は run の日付。失敗の検出と推移の節の両方に渡し、2 つの節にその日の Weekly Rate Record を読ませる
harness_pr_body_init() {
    local pr_body="" worktree="" result="" date="" run="" ledger_dir=""
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 ]] || {
            _harness_pr_body_usage "init: $1 needs a value"
            return
        }
        case "$1" in
        --pr-body) pr_body=$2 ;;
        --worktree) worktree=$2 ;;
        --review-result) result=$2 ;;
        --date) date=$2 ;;
        --run) run=$2 ;;
        --ledger-repo-dir) ledger_dir=$2 ;;
        *)
            _harness_pr_body_usage "init: unknown argument $1"
            return
            ;;
        esac
        shift 2
    done
    if [[ -z "$pr_body" || -z "$worktree" || -z "$result" || -z "$date" || -z "$run" || -z "$ledger_dir" ]]; then
        _harness_pr_body_usage 'init needs --pr-body, --worktree, --review-result, --date, --run and --ledger-repo-dir'
        return
    fi
    if [[ -z "${HARNESS_INTEGRITY_FAILED:-}" ]] ||
        ! declare -F harness_integrity_run harness_review_outcome_sections >/dev/null; then
        _harness_pr_body_usage 'init needs lib/harness-integrity.bash and lib/harness-review-outcome.bash; source them first'
        return
    fi
    _HARNESS_PR_BODY_FILE=$pr_body
    _HARNESS_PR_BODY_WORKTREE=$worktree
    _HARNESS_PR_BODY_REVIEW_RESULT=$result
    _HARNESS_PR_BODY_DATE=$date
    _HARNESS_PR_BODY_RUN=$run
    _HARNESS_PR_BODY_LEDGER_REPO_DIR=$ledger_dir
}

_harness_pr_body_ready() {
    [[ -n "$_HARNESS_PR_BODY_FILE" ]] || _harness_pr_body_usage 'call harness_pr_body_init first'
}

# 選別の prompt に埋める、本文を書かせる指示の 1 行(末尾の改行なし。週次ジョブが同じ行に続けて書く)。
# ジョブが足す節(純増・検出件数・再発率・ルールの効果・落とした変更・deploy-only の修正)は claude に書かせない
harness_pr_body_review_instructions() {
    _harness_pr_body_ready || return
    printf '%s' "- Write the PR body (in Japanese) to ${_HARNESS_PR_BODY_FILE}: for each adopted change, its queue title, the files it changes, and why it was adopted; for each staleness fix, the files and why; then the rejected and handoff counts and the remaining staleness findings. Do not write line counts, failure detection counts, failure pattern rates, rule effects, dropped changes or deploy-only fixes in the PR body; this job appends them from the diff, its detection and rate records, the evaluation and the result file."
}

# 純増の節。claude の申告ではなく diff から数える。
# 採用した変更ごとの純増は、選別に「採用 1 件(陳腐化の修正 1 件)= 1 commit、件名に queue の
# タイトル」と commit させたうえで commit ごとに数える。続けてファイルごとの表と合計を出す。
# commit ごとの集計に plumbing(rev-list / diff-tree)を使うのは、launchd 経由では
# ~/.gitconfig が効き、porcelain の出力に署名の検証結果などが混ざりうるため。
# numstat はバイナリファイルの行数を `-` で出すので、表には「バイナリ」と書いて合計から外す。
# パスと件名の `|` は表の区切りにならないよう `\|` にする(gsub の置換文字列の `\` の扱いは
# awk の実装で違うので、index と substr で置き換える)
_HARNESS_PR_BODY_NUMSTAT_AWK_ESCAPE='
function escape_pipes(text,    out, i) {
    out = ""
    while ((i = index(text, "|")) > 0) {
        out = out substr(text, 1, i - 1) "\\|"
        text = substr(text, i + 1)
    }
    return out text
}'
_harness_pr_body_net_change() { # <base>
    local base=$1 worktree=$_HARNESS_PR_BODY_WORKTREE commits commit subject numstat
    commits=$(git -C "$worktree" rev-list --reverse "$base..HEAD") || return 1
    printf '\n## 純増\n\n### 変更ごと(commit ごと)\n\n| 変更 | 追加 | 削除 |\n|---|---:|---:|\n'
    for commit in $commits; do
        subject=$(git -C "$worktree" -c log.showSignature=false log -1 --format=%s "$commit") || return 1
        numstat=$(git -C "$worktree" diff-tree --no-commit-id -r --numstat "$commit") || return 1
        # 件名は -v ではなく環境変数で渡す(-v は値の backslash をエスケープとして解釈する)
        printf '%s\n' "$numstat" | COMMIT_SUBJECT="$subject" awk -F'\t' "$_HARNESS_PR_BODY_NUMSTAT_AWK_ESCAPE"'
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
    git -C "$worktree" diff --no-ext-diff --numstat "$base" HEAD | awk -F'\t' "$_HARNESS_PR_BODY_NUMSTAT_AWK_ESCAPE"'
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

# 再発率のスクリプトが出す指標の節を、組み立てに成功したときだけ本文に足す。<節> は再発率のスクリプトのサブコマンドで、
# 節ごとの、ログの行で節を指す語とスクリプトの引数はここにだけ書く。
# - detections: 失敗の検出の節。抽出を省いた週(pending が空)も節を出す。採用 0 件で PR を作らない週の件数は検出件数の
#   記録にだけ残る
# - trend: Failure Pattern の再発率の推移の節(直近 4 週)
# 2 つの節には同じ run の日付を渡すので、どちらもその日の Weekly Rate Record の期間を数える。スクリプトは Integrity Snapshot の
# 入口を通して呼ぶ。スクリプトの失敗(その日の Weekly Rate Record が無い、など)は WARN を出して節を省き、指標の節の失敗で
# PR の公開を止めない。入口の照合に落ちたら節を省いたうえで予約コードを返す。--for-pr は PR を作る本文(採用のある Loop PR と
# Metrics-only PR)が付け、照合に落ちたときに PR を作らない理由の行も出させる
_harness_pr_body_append_metric() { # <detections|trend> [--for-pr]
    local metric=${1:-} for_pr=${2:-} name section status=0
    local -a args
    case "$metric" in
    detections)
        name='failure detection counts'
        args=(detections "$_HARNESS_PR_BODY_DATE")
        ;;
    trend)
        name='failure rate trend'
        args=(trend "$_HARNESS_PR_BODY_DATE" --weeks 4)
        ;;
    *)
        _harness_pr_body_usage "unknown metric section: $metric"
        return
        ;;
    esac
    section=$(harness_integrity_run "$(_harness_pr_body_failure_rates)" "${args[@]}") || status=$?
    if [[ "$status" -eq 0 ]]; then
        printf '%s\n' "$section" >>"$_HARNESS_PR_BODY_FILE"
    elif [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        printf 'harness-weekly: the %s could not be trusted; left it out of %s\n' "$name" "$_HARNESS_PR_BODY_FILE" >&2
        [[ "$for_pr" != --for-pr ]] || printf 'harness-weekly: no PR created; the %s could not be trusted\n' "$name" >&2
        return "$status"
    else
        printf 'harness-weekly: WARN failed to build the %s; left it out of %s\n' "$name" "$_HARNESS_PR_BODY_FILE" >&2
    fi
}

# この run の選別が採用した項目の見出しを 1 行ずつ出す(Verdict の CLI の adopted)。Rule Ledger の節と、Loop PR の module が
# Eval Case の評価の節を作るときに使う。Loop PR の module が印を PR の URL に置き換える前に読む。終了コードは Verdict の CLI の
# もの(照合に落ちたら予約コード)
harness_pr_body_adopted_titles() {
    _harness_pr_body_ready || return
    harness_integrity_run "$(_harness_pr_body_verdict_cli)" adopted --run "$_HARNESS_PR_BODY_RUN"
}

# Rule Ledger の節。記録は PR 番号が要るので、PR を作った後の commit で足す(Loop PR の module の公開の手順)。
# 足せなかったことは本文では知らせられないので、ログの WARN と、PR の commit に記録が無いことで分かる。
# 採用を読めなければ節を省く(評価の節と同じく、PR の公開は止めない)。Verdict の CLI の照合に落ちたら予約コードを返す
_harness_pr_body_append_rule_ledger() {
    local titles status=0
    titles=$(harness_pr_body_adopted_titles) || status=$?
    if [[ "$status" -eq "$HARNESS_INTEGRITY_FAILED" ]]; then
        printf 'harness-weekly: no PR created; the Verdict CLI could not be trusted\n' >&2
        return "$status"
    elif [[ "$status" -ne 0 ]]; then
        printf 'harness-weekly: WARN could not read the adopted verdicts from %s; left the Rule Ledger section out of %s\n' \
            "$(_harness_pr_body_archive)" "$_HARNESS_PR_BODY_FILE" >&2
    elif [[ -n "$titles" ]]; then
        printf '\n## Rule Ledger\n\n採用したルールの記録(%s)は、この PR を作った後に週次ジョブが「harness: Rule Ledger の記録を足す」の commit で足す。その commit が無ければ、記録はローカルに残っていて、この PR がマージされた後の PR に載る(マージせずに閉じたら載らない)。\n' \
            "$_HARNESS_PR_BODY_LEDGER_REPO_DIR" >>"$_HARNESS_PR_BODY_FILE"
    fi
}

# harness_pr_body_review <base> <評価の節>
#   選別の claude が書いた本文の後ろに、Review Outcome の節・検出件数・再発率の推移・評価の節・純増・Rule Ledger の節を
#   この順に足す。<base> は選別の前の worktree の HEAD。<評価の節> は Loop PR の module が評価の工程(harness-eval-cases.sh section)から
#   受け取った文字列(末尾の改行なし)で、改行を 1 つ付けて足す。空なら評価の工程が失敗したとして、効果を測っていないことを
#   書いた節を足す(黙って節を省くと、効果が測られていないことが PR から見えない)。
#   純増は選別の commit だけで数えるので、Loop PR の module が記録の commit を足す前に呼ぶ。
#   失敗の扱い: Review Outcome の節・純増を作れなければ 1。検出件数・推移・Rule Ledger の節は Verdict の CLI と再発率の
#   スクリプトの照合に落ちたら、PR を作らない理由を出して予約コード。検出件数・推移・採用の読み取りのほかの失敗は WARN で節を省く
harness_pr_body_review() {
    local base=${1:-} eval_section=${2:-}
    _harness_pr_body_ready || return
    [[ $# -eq 2 && -n "$base" ]] || {
        _harness_pr_body_usage 'review needs <base> and <eval section>'
        return
    }
    harness_review_outcome_sections >>"$_HARNESS_PR_BODY_FILE" || return 1
    _harness_pr_body_append_metric detections --for-pr || return
    _harness_pr_body_append_metric trend --for-pr || return
    if [[ -n "$eval_section" ]]; then
        printf '%s\n' "$eval_section" >>"$_HARNESS_PR_BODY_FILE"
    else
        printf '\n## ルールの効果\n\n評価の工程が失敗したため、この PR のルールの効果は測っていない(週次ジョブのログを参照)。\n' >>"$_HARNESS_PR_BODY_FILE"
    fi
    # 純増は選別の commit だけで数える(記録の commit を混ぜると、ルールの肥大の数字に記録の行が入る)
    _harness_pr_body_net_change "$base" >>"$_HARNESS_PR_BODY_FILE" || return 1
    _harness_pr_body_append_rule_ledger
}

# harness_pr_body_metrics_only <週の再発率の記録の件数> <持ち越した Rule Ledger の記録の件数>
#   Metrics-only PR の本文を書く(前の内容は捨てる)。件数の文・推移・検出件数の順。件数は記録の commit の後にしか
#   決まらないので、Loop PR の module の Metrics-only PR の公開の手順が commit の後に呼ぶ。推移の節の入口の照合も記録の commit より
#   後に保つ(先に呼ぶと、実行物が書き換えられた run のログと、ローカルに残る commit が変わる)。
#   失敗の扱い: 推移か検出件数が照合に落ちたら予約コード(Loop PR の module は PR を作らない)。件数の文を書けなければ 1。
#   どれも PR を作らない理由を出す
harness_pr_body_metrics_only() {
    local rate_records=${1:-} ledger_records=${2:-}
    _harness_pr_body_ready || return
    [[ $# -eq 2 && "$rate_records" =~ ^[0-9]+$ && "$ledger_records" =~ ^[0-9]+$ ]] || {
        _harness_pr_body_usage 'metrics_only needs the numbers of the committed rate records and Rule Ledger records'
        return
    }
    _harness_pr_body_metrics_only_counts "$rate_records" "$ledger_records" || {
        printf 'harness-weekly: failed to write the record counts to %s; no PR created\n' "$_HARNESS_PR_BODY_FILE" >&2
        return 1
    }
    _harness_pr_body_append_metric trend --for-pr || return
    _harness_pr_body_append_metric detections --for-pr
}

_harness_pr_body_metrics_only_counts() { # <週の再発率の記録の件数> <持ち越した Rule Ledger の記録の件数>
    printf '採用した変更は無い。origin/main に無い週の Failure Pattern の再発率の記録が %s 週分たまったので、記録だけを commit した。\n' \
        "$1" >"$_HARNESS_PR_BODY_FILE" || return 1
    [[ "$2" -eq 0 ]] ||
        printf '\nマージ済みの PR の Rule Ledger の記録のうち、まだ載っていなかった %s 件も足した(%s)。\n' \
            "$2" "$_HARNESS_PR_BODY_LEDGER_REPO_DIR" >>"$_HARNESS_PR_BODY_FILE"
}

# harness_pr_body_failed_review <データを信頼できるか(1/0)>
#   選別の claude が commit の後に失敗した run の、手で作る PR の本文に節を足す。claude には Dropped Change と
#   Deploy-only Fix を本文に書かせないので、足さないと落とした変更の一覧が結果ファイルにしか残らない。
#   データの照合(工程の入口が選別の claude の直後に済ませている)に落ちた run(引数 0)では検出件数と推移の節を省く。
#   返り値: 検出件数と推移の節まで信頼できたら 0。データか再発率のスクリプトを信頼できなければ予約コード(呼び出し元は手で
#   公開する手順の代わりに、そのまま公開しないよう案内する)。Review Outcome の節を足せなくても、その旨を出して続ける
harness_pr_body_failed_review() {
    local data_trusted=${1:-}
    _harness_pr_body_ready || return
    [[ $# -eq 1 && ("$data_trusted" == 0 || "$data_trusted" == 1) ]] || {
        _harness_pr_body_usage 'failed_review needs 1 (the data is trusted) or 0'
        return
    }
    harness_review_outcome_sections >>"$_HARNESS_PR_BODY_FILE" ||
        printf 'harness-weekly: failed to add the sections from %s to %s\n' "$_HARNESS_PR_BODY_REVIEW_RESULT" "$_HARNESS_PR_BODY_FILE" >&2
    [[ "$data_trusted" -eq 1 ]] || return "$HARNESS_INTEGRITY_FAILED"
    _harness_pr_body_append_metric detections || return "$HARNESS_INTEGRITY_FAILED"
    _harness_pr_body_append_metric trend || return "$HARNESS_INTEGRITY_FAILED"
}
