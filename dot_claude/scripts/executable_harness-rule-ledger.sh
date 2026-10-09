#!/usr/bin/env bash
# Rule Ledger(自己改善ループが採用したルールごとの記録)を作り、リポジトリに書き出す(Evaluator の一部。ADR 0011)。
#
#   record  --pr-url <url> --date <YYYY-MM-DD> --via weekly|manual [--results <評価の結果>]
#   migrate
#   export  --base <revision> --worktree <リポジトリの作業ツリー> [--pr <この書き出しを載せる PR の番号>]
#   check   <ディレクトリ>
#
# 記録は 1 採用 1 ファイルで、ローカルの ~/.claude/harness/rule-ledger/<id>.json に作る。リポジトリの置き場は
# docs/harness/rule-ledger/。commit するのは週次ジョブ(harness-weekly.sh)だけで、base に無いローカルの記録を
# export で写してから commit する。手動の /harness-review もローカルに記録を作るだけで、commit は週次ジョブの
# PR に任せる(harness-review スキルの「Bookkeeping」節)。記録は採用だけで、却下・handoff は記録しない。
# 記録は PR を作った時点で作るが、写すのはその PR がマージされた記録と、--pr に渡したこの書き出しの PR の記録
# だけにする(PR の状態は gh で引く)。マージされずに閉じた PR の記録は採用ではないので写さず、開いたままの別の
# PR の記録は、その PR がマージされた後の書き出しが写す(開いた PR どうしに同じ記録を入れない)。状態を引けない
# 記録は写さずにローカルに残す。閉じた PR の記録もローカルからは消さない(PR を開き直すことがあるため)。
#
# 記録の形(形の正本は RECORD_DEFS の record_valid):
#   {"id": "pr<PR 番号>-<title の sha256 の先頭 8 桁>", "adopted": "<採用日>", "title": "<queue の見出し>",
#    "failure_patterns": [<出典のセッションの失敗を分類した Failure Pattern の id>],
#    "eval": <eval の status ごとの形>, "pr": <PR 番号>, "via": "weekly" | "manual" | "migrated"}
# eval の status ごとの形。評価の結果(harness-eval-cases.sh run の出力)から title で引く:
#   evaluated     {case_id, with, without, delta}  ルールの有無の平均得点と Δ
#   invalid       {case_id, with, without}         ルールの無い側で失敗が再現しなかった
#   not_evaluated {case_id, reason}                評価できなかった(reason は評価のスクリプトの固定の分類)
#   exempt        {reason}                         Eval Case を書けない理由(選別が書いた自由記述)
#   over_cap      {case_id}                        件数の上限で評価しなかった(実体は作る。古い結果では null)
#   missing       {reason: no_request | not_measured}  依頼が無い / 評価の結果が無い(評価の工程の失敗を含む)
# case_id は Eval Case の実体 ~/.claude/harness/evals/<case_id>/ の名前。id を PR 番号と title で決めるのは、
# 同じ採用を記録と移行が別々に書いても 1 つのファイルになるようにするため(Eval Case の id は評価した日付で決まる)。
# failure_patterns は判定の記録の Source のセッションを classifications.jsonl で引く。分類の記録が無ければ空。
#
# 同時実行: 記録は一時ファイルに書いてから ln で置く(既にあれば失敗する)ので、週次ジョブ・手動の review・
# 移行が同時に走っても、互いの記録を消さず、壊れた記録も残さない。既にある記録は上書きしない。
#
# 仕事の文脈: 記録の自由記述は title と免除の理由だけ。export は写した記録を、リポジトリの identity leak guard
# (scripts/scan-sensitive-info.sh)と仕事のリポジトリ名(~/ghq/github.com/<仕事の org>/ のディレクトリ名。
# RULE_LEDGER_WORK_REPOS で上書きできる)で検査し、当たれば両方を固定の文言で伏せる。伏せても当たる記録は
# 写さない。identity leak guard は worktree の作業ツリーではなく --base の revision のもの(スキャナ・パターン・
# allowlist)を使う。worktree には選別の claude の commit が入りうるため。gitignore 済みのローカルのパターンは
# SENSITIVE_PATTERNS_LOCAL で渡す(週次ジョブはリポジトリ本体の scripts/sensitive-patterns.local.txt を渡す)。
# 仕事の org(SENSITIVE_WORK_ORG か chezmoi の .ghOrg)かリポジトリの一覧を引けなければ、検査が空振り
# しないよう何も写さずに失敗する。名前を含まない仕事の文脈(仕事のリポジトリにしか無いスクリプトの名前など)は
# 捕まえられない。ローカルの記録は伏せない。初めて写した形(伏せた後)を rule-ledger/exported/<id>.json に残し、
# 次からはその形を写す。伏せるかの判定はその時点の仕事のリポジトリの一覧で決まるので、一覧から名前が消えても
# 伏せた記録を伏せない形で別の PR に入れないようにするため。残した形がその時点の検査に当たれば(一覧に名前が
# 増えたとき)、公開を避けるためさらに伏せるので、マージ済みの PR から持ち越した記録が開いたループの PR 2 本に
# 入っている間に一覧が増えると、同じ id の記録が別の中身になる(残存。後からマージする PR がコンフリクトする)。
#
# 週次ジョブは claude の起動前に取ったローカルの記録のハッシュと比べるので、週次ジョブの run の最中に手動の
# /harness-review が記録を作ると、その run は PR を作らずに失敗する(記録は失わない。次の run が載せる)。
#
# 終了コード: 0 = 成功(記録が 0 件の場合を含む)、1 = 失敗(check では形の違う記録がある)、2 = 引数の誤り
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
ARCHIVE="$HARNESS_DIR/queue-archive.md"
VERDICT_CLI="$HOME/.claude/scripts/harness-verdict.sh"
CLASSIFICATIONS="$HARNESS_DIR/classifications.jsonl"
LOCAL_LEDGER_DIR="$HARNESS_DIR/rule-ledger"
EXPORTED_DIR="$LOCAL_LEDGER_DIR/exported"
LEDGER_REPO_DIR="docs/harness/rule-ledger"
# Eval Case の評価(harness-eval-cases.sh)を入れた日。migrate はこれより前に作った PR の採用だけを移す。
# 以後の採用は record が評価の結果と一緒に記録する
EVAL_CASES_SINCE=2026-10-05
MIGRATED_REASON='Eval Case の仕組みを入れる前に採用した(移行した記録)'
REDACTED='(仕事の文脈を含むため伏せた)'

usage() {
    printf 'usage: harness-rule-ledger.sh record --pr-url <url> --date <YYYY-MM-DD> --via weekly|manual [--results <file>]\n       harness-rule-ledger.sh migrate\n       harness-rule-ledger.sh export --base <revision> --worktree <dir> [--pr <number>]\n       harness-rule-ledger.sh check <dir>\n' >&2
    exit 2
}

fail() {
    printf 'harness-rule-ledger: %s\n' "$1" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq not found'

# shellcheck disable=SC2016 # jq の式
RECORD_DEFS='
def line: type == "string" and length > 0 and (test("[\u0000-\u001f]") | not);
def day: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
def score: type == "number" and . >= 0 and . <= 1;
def case_id: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9a-f]{8}$");
def eval_valid:
    type == "object" and
    if .status == "evaluated" then
        keys == ["case_id", "delta", "status", "with", "without"] and (.case_id | case_id)
        and (.with | score) and (.without | score) and (.delta | type == "number" and . >= -1 and . <= 1)
    elif .status == "invalid" then
        keys == ["case_id", "status", "with", "without"] and (.case_id | case_id) and (.with | score) and (.without | score)
    elif .status == "not_evaluated" then
        keys == ["case_id", "reason", "status"] and (.case_id == null or (.case_id | case_id))
        and (.reason | type == "string" and test("^[a-z_]+$"))
    elif .status == "exempt" then keys == ["reason", "status"] and (.reason | line)
    elif .status == "over_cap" then keys == ["case_id", "status"] and (.case_id == null or (.case_id | case_id))
    elif .status == "missing" then keys == ["reason", "status"] and (.reason | IN("no_request", "not_measured"))
    else false end;
def record_valid:
    type == "object"
    and keys == ["adopted", "eval", "failure_patterns", "id", "pr", "title", "via"]
    and (.pr | type == "number" and . > 0 and floor == .)
    and (.pr as $pr | .id | type == "string" and test("^pr[0-9]+-[0-9a-f]{8}$") and startswith("pr\($pr)-"))
    and (.adopted | day) and (.title | line)
    and (.failure_patterns | type == "array" and all(.[]; type == "string" and test("^[a-z0-9-]+$"))
         and (unique | length) == length)
    and (.via | IN("weekly", "manual", "migrated"))
    and (.eval | eval_valid);
'

# 判定の記録の項目を 1 行 1 件の JSON で出す。書式の解釈は Verdict の CLI が持つ(形は harness-verdict.sh の
# ヘッダ)。CLI が無いか失敗したら失敗する(採用が無いとは読まない)
archive_entries() {
    local entries
    [[ -f "$VERDICT_CLI" ]] || {
        printf 'harness-rule-ledger: %s not found\n' "$VERDICT_CLI" >&2
        return 1
    }
    entries=$(bash "$VERDICT_CLI" entries) || return 1
    [[ -z "$entries" ]] || printf '%s\n' "$entries"
}

# 出典のセッションの失敗を分類した Failure Pattern の id(重複なし)を JSON の配列で出す
failure_patterns() { # <sources の JSON 配列>
    if [[ ! -f "$CLASSIFICATIONS" ]]; then
        printf '[]\n'
        return 0
    fi
    jq -R -s -c --argjson sources "$1" '[split("\n")[] | (try fromjson catch null)
        | select(type == "object" and (.session_id | type) == "string" and (.pattern | type) == "string")
        | select(.session_id as $s | $sources | index($s)) | .pattern] | unique' "$CLASSIFICATIONS"
}

title_digest() {
    local digest
    digest=$(printf '%s' "$1" | shasum -a 256) || return 1
    printf '%s\n' "${digest:0:8}"
}

# 記録を 1 件置く。一時ファイルに書いて ln で置くので、既にあれば置かずに 3 を返す
WRITTEN=0
EXISTING=0
write_record() { # <記録の JSON>
    local record=$1 id tmp
    jq -e "$RECORD_DEFS"'record_valid' <<<"$record" >/dev/null || {
        printf 'harness-rule-ledger: built a record that does not match the format: %s\n' "$record" >&2
        return 1
    }
    id=$(jq -r '.id' <<<"$record")
    mkdir -p "$LOCAL_LEDGER_DIR" || return 1
    tmp=$(mktemp "$LOCAL_LEDGER_DIR/.record.XXXXXX") || return 1
    if ! jq '.' <<<"$record" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ln "$tmp" "$LOCAL_LEDGER_DIR/$id.json" 2>/dev/null; then
        rm -f "$tmp"
        WRITTEN=$((WRITTEN + 1))
        printf 'harness-rule-ledger: recorded %s\n' "$id"
    else
        rm -f "$tmp"
        [[ -f "$LOCAL_LEDGER_DIR/$id.json" ]] || return 1
        EXISTING=$((EXISTING + 1))
        printf 'harness-rule-ledger: %s already recorded; left it unchanged\n' "$id"
    fi
}

build_record() { # <entry の JSON> <PR 番号> <採用日> <via> <eval の JSON>
    local entry=$1 title sources digest patterns
    title=$(jq -r '.title' <<<"$entry") || return 1
    sources=$(jq -c '.sources' <<<"$entry") || return 1
    digest=$(title_digest "$title") || return 1
    patterns=$(failure_patterns "$sources") || return 1
    jq -c -n --argjson entry "$entry" --argjson pr "$2" --arg adopted "$3" --arg via "$4" --argjson eval "$5" \
        --arg digest "$digest" --argjson patterns "$patterns" \
        '{id: "pr\($pr)-\($digest)", adopted: $adopted, title: $entry.title, failure_patterns: $patterns,
          eval: $eval, pr: $pr, via: $via}'
}

# 評価の結果から title の判定を引いて eval の JSON を出す。結果が無ければ not_measured
eval_of() { # <title> <結果のファイル or 空>
    if [[ -z "$2" ]]; then
        printf '{"status":"missing","reason":"not_measured"}\n'
        return 0
    fi
    jq -c --arg t "$1" '
        def single_line: gsub("[\u0000-\u001f]+"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "");
        ([.cases[] | select(.title == $t)][0]) as $c
        | ([.exempt[] | select(.title == $t)][0]) as $e
        | if $c != null then
            if $c.status == "evaluated" then {status: "evaluated", case_id: $c.id, with: $c.with, without: $c.without, delta: $c.delta}
            elif $c.status == "invalid" then {status: "invalid", case_id: $c.id, with: $c.with, without: $c.without}
            else {status: "not_evaluated", case_id: ($c.id // null), reason: ($c.reason // "unknown")} end
          elif $e != null then {status: "exempt", reason: ($e.reason | tostring | single_line)}
          elif (.over_cap | index($t)) != null
          then {status: "over_cap", case_id: ([(.over_cap_cases // [])[] | select(.title == $t) | .id | strings][0])}
          else {status: "missing", reason: "no_request"} end' "$2"
}

record_mode() {
    local entries entry results="" title eval_json record pr
    [[ -n "$PR_URL" && -n "$DATE" && -n "$VIA" ]] || usage
    [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    [[ "$VIA" == weekly || "$VIA" == manual ]] || usage
    pr=${PR_URL##*/}
    [[ "$pr" =~ ^[0-9]+$ ]] || usage
    pr=$((10#$pr))
    if [[ -n "$RESULTS" ]]; then
        if jq -e 'type == "object" and (.cases | type == "array") and (.exempt | type == "array")
            and (.over_cap | type == "array") and all(.cases[], .exempt[]; type == "object" and (.title | type) == "string")' \
            "$RESULTS" >/dev/null 2>&1; then
            results=$RESULTS
        else
            printf 'harness-rule-ledger: WARN the eval results %s are missing or malformed; recording the adoptions as not measured\n' \
                "$RESULTS" >&2
        fi
    fi
    entries=$(archive_entries | jq -c --arg url "$PR_URL" 'select(.kind == "adopted" and .pr_url == $url)') ||
        fail "cannot read $ARCHIVE"
    if [[ -z "$entries" ]]; then
        printf 'harness-rule-ledger: no adopted verdict for %s in %s; nothing recorded\n' "$PR_URL" "$ARCHIVE"
        return 0
    fi
    while IFS= read -r entry; do
        title=$(jq -r '.title' <<<"$entry")
        eval_json=$(eval_of "$title" "$results") || fail "cannot read the eval results $results"
        record=$(build_record "$entry" "$pr" "$DATE" "$VIA" "$eval_json") || fail "cannot build the record of $title"
        write_record "$record" || fail "cannot write the record of $title in $LOCAL_LEDGER_DIR"
    done <<<"$entries"
    printf 'harness-rule-ledger: %s recorded, %s already recorded\n' "$WRITTEN" "$EXISTING"
}

# 判定の記録の採用を 1 回だけ新しい形式に移す。採用日は PR を作った日(gh で引き、PR ごとに 1 回だけ)。
# 移すのは EVAL_CASES_SINCE より前に作った PR の採用だけで、免除の理由を「仕組みを入れる前」とする。
# 何度実行しても、既にある記録は上書きしない。移せないものは「skipped<TAB>理由<TAB>title」で出す
migrate_mode() {
    local entries entry pr_url run title url pr created adopted dates="" record skipped=0 eval_json
    entries=$(archive_entries | jq -c 'select(.kind == "adopted")') || fail "cannot read $ARCHIVE"
    eval_json=$(jq -n -c --arg r "$MIGRATED_REASON" '{status: "exempt", reason: $r}')
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        pr_url=$(jq -r '.pr_url // ""' <<<"$entry")
        run=$(jq -r '.run // ""' <<<"$entry")
        title=$(jq -r '.title' <<<"$entry")
        if [[ "$pr_url" =~ ^https://github\.com/[^/\ ]+/[^/\ ]+/pull/([0-9]+)$ ]]; then
            url=$pr_url
            pr=$((10#${BASH_REMATCH[1]}))
        elif [[ "$run" == harness/review-* ]]; then
            printf 'skipped\tPR にならなかった週次の run の採用(手で publish するか queue に戻すまで移さない)\t%s\n' "$title"
            skipped=$((skipped + 1))
            continue
        else
            printf 'skipped\t採用の記録の書式を読めない\t%s\n' "$title"
            skipped=$((skipped + 1))
            continue
        fi
        adopted=$(awk -F'\t' -v url="$url" '$1 == url { print $2; exit }' <<<"$dates")
        if [[ -z "$adopted" ]]; then
            if created=$(gh pr view "$url" --json createdAt --jq .createdAt 2>/dev/null) &&
                adopted=$(jq -r -n --arg t "$created" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601 | localtime | strftime("%Y-%m-%d")' 2>/dev/null) &&
                [[ "$adopted" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                :
            else
                adopted=failed
            fi
            dates+="${url}"$'\t'"${adopted}"$'\n'
        fi
        if [[ "$adopted" == failed ]]; then
            printf 'skipped\tPR の作成日を取れない\t%s\n' "$title"
            skipped=$((skipped + 1))
            continue
        fi
        if [[ ! "$adopted" < "$EVAL_CASES_SINCE" ]]; then
            printf 'skipped\tEval Case を入れた後の採用(record で記録する)\t%s\n' "$title"
            skipped=$((skipped + 1))
            continue
        fi
        record=$(build_record "$entry" "$pr" "$adopted" migrated "$eval_json") || fail "cannot build the record of $title"
        write_record "$record" >/dev/null || fail "cannot write the record of $title in $LOCAL_LEDGER_DIR"
    done <<<"$entries"
    printf 'harness-rule-ledger: migrated %s, already recorded %s, skipped %s (listed above)\n' "$WRITTEN" "$EXISTING" "$skipped"
}

# 1 ファイルの記録が決めた形で、名前が id と一致するか
file_valid() { # <ファイル>
    local name=${1##*/}
    jq -e --arg name "$name" "$RECORD_DEFS"'record_valid and (.id + ".json") == $name' "$1" >/dev/null 2>&1
}

# 仕事の org を出す。scan-sensitive-info.sh の resolve_work_org と同じく、SENSITIVE_WORK_ORG が設定されていれば
# (空でも)それを使う
work_org() {
    if [[ -n ${SENSITIVE_WORK_ORG+set} ]]; then
        printf '%s\n' "$SENSITIVE_WORK_ORG"
        return 0
    fi
    command -v chezmoi >/dev/null 2>&1 || return 0
    chezmoi data 2>/dev/null | jq -r '.ghOrg // empty' 2>/dev/null || true
}

# 仕事のリポジトリ名を 1 行 1 件で出す。読めなければ失敗する
work_repos() { # <org>
    local dir
    if [[ -n ${RULE_LEDGER_WORK_REPOS+set} ]]; then
        tr ' ' '\n' <<<"$RULE_LEDGER_WORK_REPOS" | sed '/^$/d'
        return 0
    fi
    dir="$HOME/ghq/github.com/$1"
    [[ -d "$dir" && -r "$dir" ]] || return 1
    for dir in "$dir"/*/; do
        [[ -d "$dir" ]] || continue
        dir=${dir%/}
        printf '%s\n' "${dir##*/}"
    done
}

# 記録の自由記述が仕事の文脈に当たるか(identity leak guard か仕事のリポジトリ名)
leaks_work_context() { # <記録のファイル>
    local status=0
    SENSITIVE_WORK_ORG="$ORG" bash "$GUARD_DIR/scan-sensitive-info.sh" "$1" >/dev/null 2>&1 || return 0
    jq -r '.title, (.eval.reason // empty)' "$1" | grep -qiF -f "$NAMES" || status=$?
    [[ "$status" -ne 0 ]] || return 0
    [[ "$status" -eq 1 ]] || return 0
    return 1
}

# base の revision の identity leak guard(スキャナ・パターン・allowlist)を GUARD_DIR に取り出す。worktree の
# 作業ツリーのものは選別の claude の commit で弱められうるので使わない。ローカルのパターン(gitignore 済み)は
# SENSITIVE_PATTERNS_LOCAL で渡す
extract_guard() {
    local file
    for file in scan-sensitive-info.sh sensitive-patterns.txt; do
        git -C "$WORKTREE" show "${BASE}:scripts/${file}" >"$GUARD_DIR/$file" 2>/dev/null || return 1
    done
    # allowlist は無くてもスキャナが動く(例外が無いだけで、検査は緩まない)
    git -C "$WORKTREE" show "${BASE}:scripts/sensitive-allowlist.txt" >"$GUARD_DIR/sensitive-allowlist.txt" 2>/dev/null ||
        rm -f "$GUARD_DIR/sensitive-allowlist.txt"
}

# 記録の PR がこの書き出しで写してよい状態か。--pr に渡した PR か、マージされた PR だけを写す。gh の答えは
# PR ごとに 1 回だけ引く。0 = 写す、1 = 写さない(STATE_REASON に理由)
STATES=""
pr_exportable() { # <PR 番号>
    local pr=$1 state
    if [[ -n "$EXPORT_PR" && "$pr" == "$EXPORT_PR" ]]; then
        return 0
    fi
    state=$(awk -F'\t' -v pr="$pr" '$1 == pr { print $2; exit }' <<<"$STATES")
    if [[ -z "$state" ]]; then
        state=$(cd "$WORKTREE" && gh pr view "$pr" --json state --jq .state 2>/dev/null) || state=""
        [[ "$state" =~ ^[A-Z]+$ ]] || state=UNKNOWN
        STATES+="${pr}"$'\t'"${state}"$'\n'
    fi
    case "$state" in
    MERGED) return 0 ;;
    OPEN) STATE_REASON="its PR #${pr} is still open; a later export copies it after the merge" ;;
    CLOSED) STATE_REASON="its PR #${pr} was closed without a merge, so the rule was not adopted" ;;
    *) STATE_REASON="cannot read the state of its PR #${pr} with gh" ;;
    esac
    return 1
}

# 初めて写した形を EXPORTED_DIR に残す。既にあれば残さない(ln は既存を上書きしない)
keep_exported() { # <写したファイル> <名前>
    local tmp
    mkdir -p "$EXPORTED_DIR" 2>/dev/null || return 1
    tmp=$(mktemp "$EXPORTED_DIR/.exported.XXXXXX") || return 1
    if ! cp "$1" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    ln "$tmp" "$EXPORTED_DIR/$2" 2>/dev/null || true
    rm -f "$tmp"
    [[ -f "$EXPORTED_DIR/$2" ]]
}

# base に無いローカルの記録を worktree の置き場に写す。写すのはマージされた PR(と --pr の PR)の記録だけ
# (pr_exportable)。写した記録を仕事の文脈で検査し(leaks_work_context)、当たれば自由記述を伏せる。検査そのものを
# 走らせられなければ何も写さずに失敗する(検査なしで写すと、仕事の文脈が公開リポジトリに出るか、commit フックで
# 止まる週が続く)
export_mode() {
    local file name dest source exported=0 redacted repos pr
    [[ -n "$BASE" && -n "$WORKTREE" ]] || usage
    [[ -z "$EXPORT_PR" || "$EXPORT_PR" =~ ^[1-9][0-9]*$ ]] || usage
    ORG=$(work_org)
    [[ -n "$ORG" ]] || fail 'cannot resolve the work org (SENSITIVE_WORK_ORG or chezmoi .ghOrg); nothing exported'
    repos=$(work_repos "$ORG") || fail "cannot list the work repositories in ~/ghq/github.com/$ORG (or set RULE_LEDGER_WORK_REPOS); nothing exported"
    NAMES=$(mktemp "${TMPDIR:-/tmp}/rule-ledger-names.XXXXXX") || return 1
    PROBE=$(mktemp "${TMPDIR:-/tmp}/rule-ledger-probe.XXXXXX") || return 1
    GUARD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rule-ledger-guard.XXXXXX") || return 1
    trap 'rm -rf "$NAMES" "$PROBE" "$GUARD_DIR"' EXIT
    printf '%s\n' "$ORG" "$repos" | sed '/^$/d' >"$NAMES"
    printf '{}\n' >"$PROBE"
    if ! extract_guard || ! SENSITIVE_WORK_ORG="$ORG" bash "$GUARD_DIR/scan-sensitive-info.sh" "$PROBE" >/dev/null 2>&1; then
        fail "cannot run the identity leak guard scripts/scan-sensitive-info.sh of ${BASE}; nothing exported"
    fi
    [[ -d "$LOCAL_LEDGER_DIR" ]] || {
        printf 'harness-rule-ledger: exported 0 record(s)\n'
        return 0
    }
    for file in "$LOCAL_LEDGER_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        name=${file##*/}
        if ! file_valid "$file"; then
            printf 'harness-rule-ledger: WARN %s does not match the record format; not exported\n' "$file" >&2
            continue
        fi
        git -C "$WORKTREE" cat-file -e "${BASE}:${LEDGER_REPO_DIR}/${name}" 2>/dev/null && continue
        pr=$(jq -r '.pr' "$file")
        if ! pr_exportable "$pr"; then
            printf 'harness-rule-ledger: not exported %s: %s\n' "${name%.json}" "$STATE_REASON"
            continue
        fi
        source=$file
        if [[ -f "$EXPORTED_DIR/$name" ]]; then
            if file_valid "$EXPORTED_DIR/$name"; then
                source="$EXPORTED_DIR/$name"
            else
                printf 'harness-rule-ledger: WARN %s does not match the record format; exported %s again from the local record\n' \
                    "$EXPORTED_DIR/$name" "${name%.json}" >&2
            fi
        fi
        dest="$WORKTREE/$LEDGER_REPO_DIR/$name"
        mkdir -p "$WORKTREE/$LEDGER_REPO_DIR" || return 1
        cp "$source" "$dest" || return 1
        if leaks_work_context "$dest"; then
            redacted=$(jq --arg r "$REDACTED" '.title = $r | if .eval.status == "exempt" then .eval.reason = $r else . end' "$dest") ||
                return 1
            printf '%s\n' "$redacted" >"$dest"
            if leaks_work_context "$dest"; then
                rm -f "$dest"
                printf 'harness-rule-ledger: WARN %s still matches the work context after redaction; not exported\n' "${name%.json}" >&2
                continue
            fi
            printf 'harness-rule-ledger: redacted the free text of %s (it matched the work context)\n' "${name%.json}"
        fi
        keep_exported "$dest" "$name" ||
            printf 'harness-rule-ledger: WARN could not keep the exported form of %s in %s\n' "${name%.json}" "$EXPORTED_DIR" >&2
        exported=$((exported + 1))
    done
    printf 'harness-rule-ledger: exported %s record(s)\n' "$exported"
}

check_mode() {
    local dir=$1 file bad=0
    [[ -d "$dir" ]] || fail "no such directory: $dir"
    for file in "$dir"/* "$dir"/.[!.]*; do
        [[ -e "$file" ]] || continue
        if [[ "$file" != *.json || ! -f "$file" ]]; then
            printf 'harness-rule-ledger: %s is not a record (only <id>.json files belong here)\n' "$file" >&2
            bad=1
        elif ! file_valid "$file"; then
            printf 'harness-rule-ledger: %s does not match the record format or its name is not <id>.json\n' "$file" >&2
            bad=1
        fi
    done
    [[ "$bad" -eq 0 ]] || exit 1
    printf 'harness-rule-ledger: every record in %s matches the format\n' "$dir"
}

MODE=${1:-}
[[ -n "$MODE" ]] || usage
shift
PR_URL="" DATE="" VIA="" RESULTS="" BASE="" WORKTREE="" EXPORT_PR=""
if [[ "$MODE" == check ]]; then
    [[ $# -eq 1 ]] || usage
    check_mode "$1"
    exit 0
fi
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || usage
    case "$1" in
    --pr-url) PR_URL=$2 ;;
    --date) DATE=$2 ;;
    --via) VIA=$2 ;;
    --results) RESULTS=$2 ;;
    --base) BASE=$2 ;;
    --worktree) WORKTREE=$2 ;;
    --pr) EXPORT_PR=$2 ;;
    *) usage ;;
    esac
    shift 2
done

case "$MODE" in
record) record_mode ;;
migrate) migrate_mode ;;
export) export_mode ;;
*) usage ;;
esac
