#!/usr/bin/env bash
# 失敗の検出器が見つけた失敗を、Failure Pattern の一覧(harness-failure-patterns.json)に照らして
# LLM で分類する(Evaluator の一部。ADR 0011)。週次ジョブが 1 回の run で 1 回だけ起動する。
#
# 対象は ~/.claude/harness/detections.jsonl のうち epoch が --since より後で、失敗のある(counts が
# 空でない)行のセッション。セッションごとに transcript(~/.claude/projects/*/<session_id>.jsonl)を
# 検出器にかけ直し、~/.claude/harness/classifications.jsonl にまだ無い失敗(セッション・行・信号の組)
# だけを、前後の抜粋を添えて claude -p に 1 回で渡す。答えは失敗ごとに一覧の id か "unclassified"
# (一覧に当てはまらない)。一覧への追加は人が別の PR で行う。
# 答えの形を確かめてから、失敗 1 件につき 1 行
#   {"session_id","line","signal","pattern","run","epoch"}
# を classifications.jsonl に足す。形が違えば(id の欠落・重複、一覧に無い pattern、JSON でない)
# 1 行も書かずに失敗する。一部だけを書くと、その週の再発率が分類できた分だけに偏るため。
# 抜粋は claude に渡すだけで記録に残さない(transcript には仕事の文脈が入りうる)。
#
# claude にはツールを持たせず(--tools "")、session を保存させない。session id は呼び出し側が
# 渡し、週次ジョブはそれを pending から外す対象として起動前に記録する。
# 件数の上限(HARNESS_CLASSIFY_MAX_ITEMS、既定 200)を超えた分は渡さず、over_cap に数える。
# 予算は HARNESS_CLASSIFY_BUDGET_USD(既定 2)。
#
# 終了コード: 0 = 分類した(渡すものが無かった場合を含む)、1 = 分類に失敗した、2 = 引数の誤り
set -euo pipefail

SINCE="" CLASSIFY_SESSION_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    --since | --session-id)
        [[ $# -ge 2 ]] || {
            SINCE=""
            break
        }
        if [[ "$1" == --since ]]; then SINCE=$2; else CLASSIFY_SESSION_ID=$2; fi
        shift 2
        ;;
    *)
        SINCE=""
        break
        ;;
    esac
done
if [[ ! "$SINCE" =~ ^[0-9]+$ || -z "$CLASSIFY_SESSION_ID" ]]; then
    printf 'usage: harness-classify-failures.sh --since <epoch> --session-id <id>\n' >&2
    exit 2
fi

HARNESS_DIR="$HOME/.claude/harness"
LEDGER="$HARNESS_DIR/detections.jsonl"
RECORDS="$HARNESS_DIR/classifications.jsonl"
DETECTOR="$HOME/.claude/scripts/harness-detect-failures.sh"
PATTERNS="$HOME/.claude/scripts/harness-failure-patterns.json"
BUDGET_USD="${HARNESS_CLASSIFY_BUDGET_USD:-2}"
MAX_ITEMS="${HARNESS_CLASSIFY_MAX_ITEMS:-200}"

fail() {
    printf 'harness-classify-failures: %s\n' "$1" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq not found'
[[ -f "$DETECTOR" ]] || fail "detector $DETECTOR not found"
[[ "$MAX_ITEMS" =~ ^[0-9]+$ ]] || fail "HARNESS_CLASSIFY_MAX_ITEMS is not a number: $MAX_ITEMS"
jq -e '.patterns | type == "array" and length > 0
    and all(.[]; (.id | type == "string" and test("^[a-z0-9-]+$")) and (.description | type == "string"))
    and (map(.id) | unique | length) == length
    and all(.[]; .id != "unclassified")' "$PATTERNS" >/dev/null 2>&1 ||
    fail "the Failure Pattern list $PATTERNS is missing or malformed"
ALLOWED=$(jq -c '[.patterns[].id, "unclassified"]' "$PATTERNS")

WORK=$(mktemp -d "$HARNESS_DIR/.classify.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ITEMS="$WORK/items.jsonl"
: >"$ITEMS"

sessions=""
if [[ -f "$LEDGER" ]]; then
    sessions=$(jq -R -r --argjson since "$SINCE" '
        (try fromjson catch null)
        | select(type == "object" and ((.epoch // 0) | type) == "number" and (.epoch // 0) > $since
            and (.counts | type) == "object" and .counts != {})
        | .session_id | strings' "$LEDGER" | awk '!seen[$0]++')
fi
classified_keys="[]"
if [[ -f "$RECORDS" ]]; then
    classified_keys=$(jq -R -s -c '[split("\n")[] | (try fromjson catch null) | select(type == "object")
        | "\(.session_id)\u0000\(.line)\u0000\(.signal)"] | unique' "$RECORDS")
fi

# 検出した行ごとの抜粋。tool_result の行は呼び出したツールの名前と入力を添え、人の発言の行は本文、
# 同じ呼び出しの繰り返し(repeat)の行はその呼び出しを出す。長い本文は切り詰める
# shellcheck disable=SC2016 # jq のプログラム
EXCERPT='
def text_of:
    if type == "string" then .
    elif type == "array" then map(select(type == "object" and .type == "text") | .text // "") | join("\n")
    else "" end;
def clip($n): if length > $n then .[0:$n] + "…" else . end;
def call($tool): "tool_use \($tool.name // "?") \(($tool.input // {}) | tojson | clip(300))";
[inputs | try fromjson catch null] as $rows
| (reduce ($rows[] | select(type == "object" and .type == "assistant" and (.message.content | type) == "array")
        | .message.content[] | select(type == "object" and .type == "tool_use")) as $use
    ({}; .[$use.id // ""] = $use)) as $tools
| $detections[] as $d
| ($rows[$d.line - 1] // {}) as $e
| $d + {excerpt: (
    if ($e.message.content | type) != "array" then "user: " + ($e.message.content | text_of | clip(500))
    elif $e.type == "assistant" then
        [$e.message.content[] | select(type == "object" and .type == "tool_use") | call(.)] | join("\n")
    elif any($e.message.content[]; type == "object" and .type == "tool_result") then
        [$e.message.content[] | select(type == "object" and .type == "tool_result")
            | call($tools[.tool_use_id // ""] // {}) + "\nresult: " + (.content | text_of | clip(500))] | join("\n")
    else "user: " + ($e.message.content | text_of | clip(500)) end)}
'

session_count=0 missing=0 over_cap=0 item_count=0
while IFS= read -r session_id; do
    [[ -n "$session_id" ]] || continue
    session_count=$((session_count + 1))
    transcript=""
    # glob に使うので、id の形を先に確かめる(* や / を含む id でほかのファイルを読まない)
    if [[ "$session_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
        for candidate in "$HOME"/.claude/projects/*/"$session_id".jsonl; do
            [[ -f "$candidate" && -r "$candidate" ]] && transcript=$candidate && break
        done
    fi
    if [[ -z "$transcript" ]]; then
        printf 'harness-classify-failures: WARN no transcript for session %s; skipped\n' "$session_id" >&2
        missing=$((missing + 1))
        continue
    fi
    detections=$(bash "$DETECTOR" "$transcript") || fail "detector failed on session $session_id"
    detections=$(jq -s -c --arg sid "$session_id" --argjson keys "$classified_keys" '
        map(select(("\($sid)\u0000\(.line)\u0000\(.signal)") as $k | any($keys[]; . == $k) | not)
            | {session_id: $sid, line, signal})' <<<"$detections")
    [[ "$detections" != "[]" ]] || continue
    jq -R -n -c --argjson detections "$detections" "$EXCERPT" "$transcript" >>"$ITEMS" ||
        fail "could not build excerpts for session $session_id"
done <<<"$sessions"

total=$(wc -l <"$ITEMS" | tr -d ' ')
if [[ "$total" -gt "$MAX_ITEMS" ]]; then
    over_cap=$((total - MAX_ITEMS))
    printf 'harness-classify-failures: WARN %s failure(s) over the cap of %s were not classified\n' "$over_cap" "$MAX_ITEMS" >&2
fi
head -n "$MAX_ITEMS" "$ITEMS" | jq -c -s 'to_entries | map(.value + {id: (.key + 1)})[]' >"$WORK/batch.jsonl"
item_count=$(wc -l <"$WORK/batch.jsonl" | tr -d ' ')

summary() {
    printf 'harness-classify-failures: sessions=%s items=%s classified=%s over_cap=%s missing_transcripts=%s\n' \
        "$session_count" "$item_count" "$1" "$over_cap" "$missing"
}
if [[ "$item_count" -eq 0 ]]; then
    summary 0
    exit 0
fi

{
    printf '%s\n' 'You classify failures that a deterministic detector found in Claude Code session transcripts into a fixed list of Failure Patterns (recurring types of agent failure).' \
        '' 'Failure Patterns (id: description):'
    jq -r '.patterns[] | "- \(.id): \(.description)"' "$PATTERNS"
    printf '%s\n' '' \
        'Use "unclassified" when no pattern fits. Never invent an id.' \
        'Each item below is one detected failure: its id, the detector signal, and an excerpt of the transcript at that point.' \
        'Answer with only a JSON array that covers every item exactly once, each element {"id": <item id>, "pattern": "<pattern id or unclassified>"}. No prose.' \
        '' 'Items (one JSON object per line):'
    jq -c '{id, signal, excerpt}' "$WORK/batch.jsonl"
} >"$WORK/prompt.txt"

status=0
result=$(claude -p \
    --tools "" \
    --no-session-persistence \
    --session-id "$CLASSIFY_SESSION_ID" \
    --max-budget-usd "$BUDGET_USD" \
    --output-format json <"$WORK/prompt.txt") || status=$?
if [[ "$status" -ne 0 ]] || ! jq -e '.is_error == false and (.result | type) == "string"' >/dev/null 2>&1 <<<"$result"; then
    fail "claude failed (exit $status) or reported an error; nothing recorded"
fi
# 答えを囲むコードフェンスだけは外す(それ以外の前置きや後書きは形の違反として扱う)
answer=$(jq -r '.result' <<<"$result" | sed -e '1{/^```/d;}' -e '${/^```/d;}')
ids=$(jq -s -c 'map(.id)' "$WORK/batch.jsonl")
jq -e --argjson ids "$ids" --argjson allowed "$ALLOWED" '
    type == "array"
    and all(.[]; type == "object" and (.id | type) == "number"
        and (.pattern | type) == "string" and (.pattern as $p | any($allowed[]; . == $p)))
    and (map(.id) | sort) == ($ids | sort)' >/dev/null 2>&1 <<<"$answer" ||
    fail "claude returned an invalid classification (every item exactly once, ids from the list or \"unclassified\"); nothing recorded"

jq -c -n --argjson answer "$answer" --slurpfile batch "$WORK/batch.jsonl" \
    --arg run "$CLASSIFY_SESSION_ID" --argjson epoch "$(date +%s)" '
    ($answer | map({key: (.id | tostring), value: .pattern}) | from_entries) as $pattern
    | $batch[] | {session_id, line, signal, pattern: $pattern[.id | tostring], run: $run, epoch: $epoch}' \
    >"$WORK/records.jsonl" || fail 'could not build the records; nothing recorded'
cat "$WORK/records.jsonl" >>"$RECORDS"
summary "$item_count"
