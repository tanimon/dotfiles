#!/usr/bin/env bash
# Rule Ledger(自己改善ループが採用したルールごとの記録)を作り、リポジトリに書き出す(Evaluator の一部。ADR 0011)。
#
#   record  --pr-url <url> --date <YYYY-MM-DD> --via weekly|manual [--results <評価の結果>]
#   migrate
#   export  --base <revision> --worktree <リポジトリの作業ツリー>
#   check   <ディレクトリ>
#
# 記録は 1 採用 1 ファイルで、ローカルの ~/.claude/harness/rule-ledger/<id>.json に作る。リポジトリの置き場は
# docs/harness/rule-ledger/。commit するのは週次ジョブ(harness-weekly.sh)だけで、base に無いローカルの記録を
# export で写してから commit する。手動の /harness-review もローカルに記録を作るだけで、commit は次の週次ジョブの
# PR に任せる(harness-review スキルの「Bookkeeping」節)。記録は採用だけで、却下・handoff は記録しない。
#
# 記録の形(形の正本は RECORD_DEFS の record_valid):
#   {"id": "pr<PR 番号>-<title の sha256 の先頭 8 桁>", "adopted": "<採用日>", "title": "<queue の見出し>",
#    "failure_patterns": [<出典のセッションの失敗を分類した Failure Pattern の id>],
#    "eval": <下記>, "pr": <PR 番号>, "via": "weekly" | "manual" | "migrated"}
# eval は評価の結果(harness-eval-cases.sh run の出力)から title で引く:
#   evaluated     {case_id, with, without, delta}  ルールの有無の平均得点と Δ
#   invalid       {case_id, with, without}         ルールの無い側で失敗が再現しなかった
#   not_evaluated {case_id, reason}                評価できなかった(reason は評価のスクリプトの固定の分類)
#   exempt        {reason}                         Eval Case を書けない理由(選別が書いた自由記述)
#   over_cap      {}                               件数の上限で評価しなかった
#   missing       {reason: no_request | not_measured}  依頼が無い / 評価の結果が無い(評価の工程の失敗を含む)
# case_id は Eval Case の実体 ~/.claude/harness/evals/<case_id>/ の名前。id を PR 番号と title で決めるのは、
# 同じ採用を記録と移行が別々に書いても 1 つのファイルになるようにするため(Eval Case の id は評価した日付で決まる)。
# failure_patterns は判定の記録の Source のセッションを classifications.jsonl で引く。分類の記録が無ければ空。
#
# 同時実行: 記録は一時ファイルに書いてから ln で置く(既にあれば失敗する)ので、週次ジョブ・手動の review・
# 移行が同時に走っても、互いの記録を消さず、壊れた記録も残さない。既にある記録は上書きしない。
#
# 仕事の文脈: 記録の自由記述は title と免除の理由だけ。export はリポジトリの identity leak guard
# (scripts/scan-sensitive-info.sh)で写した記録を検査し、当たれば両方を固定の文言で伏せる。伏せても当たる記録は
# 写さない。ローカルの記録は伏せない。
#
# 終了コード: 0 = 成功(記録が 0 件の場合を含む)、1 = 失敗(check では形の違う記録がある)、2 = 引数の誤り
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
ARCHIVE="$HARNESS_DIR/queue-archive.md"
CLASSIFICATIONS="$HARNESS_DIR/classifications.jsonl"
LEDGER_DIR="$HARNESS_DIR/rule-ledger"
REPO_LEDGER_DIR="docs/harness/rule-ledger"
MIGRATED_REASON='Eval Case の仕組みを入れる前に採用した(移行した記録)'
REDACTED='(仕事の文脈を含むため伏せた)'

usage() {
    printf 'usage: harness-rule-ledger.sh record --pr-url <url> --date <YYYY-MM-DD> --via weekly|manual [--results <file>]\n       harness-rule-ledger.sh migrate\n       harness-rule-ledger.sh export --base <revision> --worktree <dir>\n       harness-rule-ledger.sh check <dir>\n' >&2
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
    elif .status == "over_cap" then keys == ["status"]
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

# 判定の記録の項目を 1 行 1 件の JSON {"title", "verdict", "sources"} で出す。項目は `## ` の見出しから
# 次の見出しまでで、Verdict と Source は最初の行を使う。Source の行から session id を拾う
archive_entries() {
    [[ -f "$ARCHIVE" ]] || return 0
    awk '
        function flush() {
            if (title != "") print title "\t" verdict "\t" sources
            title = ""; verdict = ""; sources = ""
        }
        /^## / { flush(); title = substr($0, 4); gsub(/\t/, " ", title); next }
        /^# / { flush(); next }
        title != "" && verdict == "" && /^- \*\*Verdict:\*\* / { verdict = substr($0, 16); gsub(/\t/, " ", verdict); next }
        title != "" && sources == "" && /^- \*\*Source:\*\* / { sources = $0; gsub(/\t/, " ", sources); next }
        END { flush() }' "$ARCHIVE" |
        jq -R -c 'split("\t") | {title: .[0], verdict: (.[1] // ""),
            sources: [(.[2] // "") | scan("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")]}'
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
    mkdir -p "$LEDGER_DIR" || return 1
    tmp=$(mktemp "$LEDGER_DIR/.record.XXXXXX") || return 1
    if ! jq '.' <<<"$record" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    if ln "$tmp" "$LEDGER_DIR/$id.json" 2>/dev/null; then
        rm -f "$tmp"
        WRITTEN=$((WRITTEN + 1))
        printf 'harness-rule-ledger: recorded %s\n' "$id"
    else
        rm -f "$tmp"
        [[ -f "$LEDGER_DIR/$id.json" ]] || return 1
        EXISTING=$((EXISTING + 1))
        printf 'harness-rule-ledger: %s already recorded; left it unchanged\n' "$id"
    fi
}

build_record() { # <entry の JSON> <PR 番号> <採用日> <via> <eval の JSON>
    local entry=$1 digest patterns
    digest=$(title_digest "$(jq -r '.title' <<<"$entry")") || return 1
    patterns=$(failure_patterns "$(jq -c '.sources' <<<"$entry")") || return 1
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
          elif (.over_cap | index($t)) != null then {status: "over_cap"}
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
    entries=$(archive_entries | jq -c --arg mark "adopted (PR $PR_URL)" 'select(.verdict | contains($mark))') ||
        fail "cannot read $ARCHIVE"
    if [[ -z "$entries" ]]; then
        printf 'harness-rule-ledger: no adopted verdict for %s in %s; nothing recorded\n' "$PR_URL" "$ARCHIVE"
        return 0
    fi
    while IFS= read -r entry; do
        title=$(jq -r '.title' <<<"$entry")
        eval_json=$(eval_of "$title" "$results") || fail "cannot read the eval results $results"
        record=$(build_record "$entry" "$pr" "$DATE" "$VIA" "$eval_json") || fail "cannot build the record of $title"
        write_record "$record" || fail "cannot write the record of $title in $LEDGER_DIR"
    done <<<"$entries"
    printf 'harness-rule-ledger: %s recorded, %s already recorded\n' "$WRITTEN" "$EXISTING"
}

# 判定の記録の採用を 1 回だけ新しい形式に移す。採用日は PR を作った日(gh で引き、PR ごとに 1 回だけ)。
# 何度実行しても、既にある記録は上書きしない。移せないものは「skipped<TAB>理由<TAB>title」で出す
migrate_mode() {
    local entries entry verdict title url pr created adopted dates="" record skipped=0 eval_json
    entries=$(archive_entries | jq -c 'select(.verdict | startswith("adopted"))') || fail "cannot read $ARCHIVE"
    eval_json=$(jq -n -c --arg r "$MIGRATED_REASON" '{status: "exempt", reason: $r}')
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        verdict=$(jq -r '.verdict' <<<"$entry")
        title=$(jq -r '.title' <<<"$entry")
        if [[ "$verdict" =~ ^adopted\ \(PR\ (https://github\.com/[^/\ ]+/[^/\ ]+/pull/([0-9]+))\) ]]; then
            url=${BASH_REMATCH[1]}
            pr=$((10#${BASH_REMATCH[2]}))
        elif [[ "$verdict" == 'adopted (harness/review-'* ]]; then
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
        record=$(build_record "$entry" "$pr" "$adopted" migrated "$eval_json") || fail "cannot build the record of $title"
        write_record "$record" >/dev/null || fail "cannot write the record of $title in $LEDGER_DIR"
    done <<<"$entries"
    printf 'harness-rule-ledger: migrated %s, already recorded %s, skipped %s (listed above)\n' "$WRITTEN" "$EXISTING" "$skipped"
}

# 1 ファイルの記録が決めた形で、名前が id と一致するか
file_valid() { # <ファイル>
    local name=${1##*/}
    jq -e --arg name "$name" "$RECORD_DEFS"'record_valid and (.id + ".json") == $name' "$1" >/dev/null 2>&1
}

# base に無いローカルの記録を worktree の置き場に写す。写した記録を identity leak guard で検査し、当たれば
# 自由記述を伏せる。検査そのものを走らせられなければ何も写さずに失敗する(検査なしで写すと、仕事の文脈が
# commit フックまで届き、フックが通らない週が続く)
export_mode() {
    local scanner probe file name dest exported=0 redacted
    [[ -n "$BASE" && -n "$WORKTREE" ]] || usage
    scanner="$WORKTREE/scripts/scan-sensitive-info.sh"
    probe=$(mktemp "${TMPDIR:-/tmp}/rule-ledger-probe.XXXXXX") || return 1
    printf '{}\n' >"$probe"
    if [[ ! -f "$scanner" ]] || ! bash "$scanner" "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        fail "cannot run the identity leak guard $scanner; nothing exported"
    fi
    rm -f "$probe"
    [[ -d "$LEDGER_DIR" ]] || {
        printf 'harness-rule-ledger: exported 0 record(s)\n'
        return 0
    }
    for file in "$LEDGER_DIR"/*.json; do
        [[ -f "$file" ]] || continue
        name=${file##*/}
        if ! file_valid "$file"; then
            printf 'harness-rule-ledger: WARN %s does not match the record format; not exported\n' "$file" >&2
            continue
        fi
        git -C "$WORKTREE" cat-file -e "$BASE:$REPO_LEDGER_DIR/$name" 2>/dev/null && continue
        dest="$WORKTREE/$REPO_LEDGER_DIR/$name"
        mkdir -p "$WORKTREE/$REPO_LEDGER_DIR" || return 1
        cp "$file" "$dest" || return 1
        if ! bash "$scanner" "$dest" >/dev/null 2>&1; then
            redacted=$(jq --arg r "$REDACTED" '.title = $r | if .eval.status == "exempt" then .eval.reason = $r else . end' "$dest") ||
                return 1
            printf '%s\n' "$redacted" >"$dest"
            if ! bash "$scanner" "$dest" >/dev/null 2>&1; then
                rm -f "$dest"
                printf 'harness-rule-ledger: WARN %s still matches the identity leak guard after redaction; not exported\n' "${name%.json}" >&2
                continue
            fi
            printf 'harness-rule-ledger: redacted the free text of %s (it matched the identity leak guard)\n' "${name%.json}"
        fi
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
PR_URL="" DATE="" VIA="" RESULTS="" BASE="" WORKTREE=""
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
