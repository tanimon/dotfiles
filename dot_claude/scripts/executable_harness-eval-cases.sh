#!/usr/bin/env bash
# ルールの候補ごとの Eval Case を作り、ルールの有無の 2 アームで評価する(Evaluator の一部。ADR 0011)。
# 週次ジョブ(harness-weekly.sh)が選別の後に呼び、結果の節を draft PR の本文に足す。手動の
# /harness-review も同じ手順で呼ぶ(harness-review スキルの「Eval Case requests」節)。
#
#   run     --requests <依頼> --date <YYYY-MM-DD> --out <結果>
#   section --results <結果> [--adopted <採用したルールの queue のタイトル。1 行 1 件>]
#
# 依頼は選別(改善する側の claude)が書く JSON の object {"cases": [...]}。受け付ける形の正本は REQUEST_DEFS、
# 書き方は harness-review スキルの「Eval Case requests」節。依頼が決められるのはルール本文・プロンプト・grader・
# 出典のセッション・免除の理由だけで、run 数・ターン数・時間・予算・ablation・発行の有無はこのスクリプトが決める。
# 残存: grader・プロンプト・with の側に注入するルール本文は改善する側が書くので、自明な grader で Δ を作ることも、
# PR で commit したのとは別の(答えを指定する)文字列を注入して Δ を作ることも、このスクリプトでは防げない
# (ADR 0011 は Eval Case を Evaluator に置く。注入したルールが commit したルールと一致するかは確かめていない)。
# 防ぐのは人の PR レビューで、依頼は実体の request.json に残り、節は注入したルールの sha256 を載せる。
#
# Eval Case の実体は ~/.claude/harness/evals/<id>/(chezmoi 管理外・git 管理外)に 1 ケース 1 plugin で
# 作る。ルールは plugin の SessionStart フックの additionalContext で with の側にだけ注入される
# (plugin の雛形は harness-eval-plugin/)。1 つの plugin で複数のルールを注入できないことと、
# `--allow-tools Bash` を付けた起動は事前確認に通らないと同じ起動のケースがすべて失敗する(実測)ことから、
# ケースごとに起動を分ける。出典の transcript は丸ごと source.jsonl にコピーする(30 日で消えるため)。
# history_lines があれば、その行までを context.history_file として再開させる(大きさは
# HARNESS_EVAL_MAX_HISTORY_BYTES で抑える。2 アーム × run 数だけ読み込まれる)。
#
# 判定(結果の status):
#   - evaluated: 両アームに評価できた run があり、ルールの無い側で失敗が再現した(平均が 1 未満)。Δ を出す
#   - invalid: ルールの無い側の run がすべて満点。失敗が再現しないので効果の証拠にならない(天井効果)
#   - not_evaluated: どちらかのアームに評価できた run が無い。レート制限・利用上限・認証・開始しなかった run
#     (turns 0)は評価の結果から除き、0 点を回帰として扱わない。ターン数の上限や時間切れは
#     ルールの効果の一部なので除かない
# claude plugin eval の aggregates は除くべき run も 0 点で数えるので使わず、run ごとの score から平均を取り直す。
# 1 回の run で評価するケースは HARNESS_EVAL_MAX_CASES(既定 20、上限も 20)件までで、超えた分は over_cap に残す
# (実体は作る)。
#
# 結果の節は公開リポジトリの PR に載るので、エラー文やパスは貼らず、理由は固定の分類で書く(生の結果は
# ~/.claude/harness/evals/<id>/result.json と run.log に残る)。
#
# 終了コード: 0 = 成功(評価できなかったケースを含む)、1 = 依頼や結果を読めない、2 = 引数の誤り
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
EVALS_DIR="$HARNESS_DIR/evals"
# 雛形の置き場の上書きは、未デプロイのブランチで実機の確認をするためのもの(週次ジョブは設定しない)
PLUGIN_TEMPLATE="${HARNESS_EVAL_PLUGIN_TEMPLATE:-$HOME/.claude/scripts/harness-eval-plugin}"
PROJECTS_DIR="$HOME/.claude/projects"
RUNS="${HARNESS_EVAL_RUNS:-2}"
BUDGET_USD="${HARNESS_EVAL_BUDGET_USD:-5}"
MAX_CASES="${HARNESS_EVAL_MAX_CASES:-20}"
MAX_HISTORY_BYTES="${HARNESS_EVAL_MAX_HISTORY_BYTES:-200000}"
# 評価を走らせる作業用の写しの置き場(run_case)。既定は Claude Code の一時ディレクトリで、nono の claude-code の
# pack が読み書きを許している
WORK_ROOT="${HARNESS_EVAL_WORK_DIR:-/private/tmp/claude-$(id -u)/harness-eval}"
MAX_TURNS=10
TIMEOUT_SECONDS=300
CASE_LIMIT=20
# 評価の結果から除く run の error。plugin eval のドキュメントは、利用上限・レート制限に当たった run が
# error にその旨を残して 0 点になり、partial にもならないとしている
EXCLUDED_ERROR_RE='rate.?limit|usage.?limit|429|overloaded|not logged in|authenticat|credential|cannot run here'

usage() {
    printf 'usage: harness-eval-cases.sh run --requests <file> --date <YYYY-MM-DD> --out <file>\n       harness-eval-cases.sh section --results <file> [--adopted <file>]\n' >&2
    exit 2
}

fail() {
    printf 'harness-eval-cases: %s\n' "$1" >&2
    exit 1
}

command -v jq >/dev/null 2>&1 || fail 'jq not found'

MODE=${1:-}
[[ -n "$MODE" ]] || usage
shift
REQUESTS="" DATE="" OUT="" RESULTS="" ADOPTED=""
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || usage
    case "$1" in
    --requests) REQUESTS=$2 ;;
    --date) DATE=$2 ;;
    --out) OUT=$2 ;;
    --results) RESULTS=$2 ;;
    --adopted) ADOPTED=$2 ;;
    *) usage ;;
    esac
    shift 2
done

# 依頼の 1 要素が決めた形かを確かめる jq の関数。免除は title と exempt だけ、ケースは grader を型ごとに見る
# shellcheck disable=SC2016 # jq の式
REQUEST_DEFS='
def nonempty_string: type == "string" and (gsub("\\s"; "") | length) > 0;
def grader_valid:
    type == "object" and (.name | type == "string" and test("^[a-z0-9][a-z0-9-]{0,40}$"))
    and (if .type == "regex" then
            (.pattern | nonempty_string)
            and ((.target // "last_message") | IN("last_message", "trace"))
            and ((.match // "contains") | IN("contains", "not_contains"))
            and ((.flags // "") | type == "string" and test("^[imsu]*$"))
        elif .type == "tool_used" then
            (.tool | type == "string" and test("^(Read|Glob|Grep|Bash)$"))
            and ((.min // 0) | type == "number" and . >= 0 and floor == .)
            and ((.max // 0) | type == "number" and . >= 0 and floor == .)
        elif .type == "llm" then (.criteria | nonempty_string)
        else false end);
def case_valid:
    (.rule | nonempty_string) and (.prompt | nonempty_string)
    and (.source_session | type == "string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
    and (.graders | type == "array" and length > 0 and all(.[]; grader_valid) and (map(.name) | unique | length) == length)
    and ((.allowed_tools // []) | type == "array" and all(.[]; IN("Read", "Glob", "Grep", "Bash")))
    and ((.history_lines // 0) | type == "number" and (tostring | test("^[0-9]+$")));
def exempt_valid: (.exempt | nonempty_string);
'

# ~/.claude/projects/*/<session>.jsonl を 1 つだけ探す。symlink と、realpath が projects の外に出るものは
# 使わない(~/.claude/harness は誰でも書けるので、依頼の session id から任意のファイルを読ませない)
find_transcript() { # <session id>
    local sid=$1 projects_real candidate real found=""
    projects_real=$(cd "$PROJECTS_DIR" 2>/dev/null && pwd -P) || return 1
    for candidate in "$PROJECTS_DIR"/*/"$sid".jsonl; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        real=$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")
        case "$real" in
        "$projects_real"/*) ;;
        *) continue ;;
        esac
        [[ -z "$found" ]] || return 1
        found=$real
    done
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

# 1 ケースの結果を run ごとの score から判定し、結果の 1 要素(JSON)を出す
judge_case() { # <title> <id> <result.json> <eval の終了コード>
    jq -c --arg title "$1" --arg id "$2" --argjson status "$4" --arg re "$EXCLUDED_ERROR_RE" '
        def excluded: (.turns // 0) == 0 or ((.error // "") | test($re; "i"));
        def reason_of($runs):
            ([$runs[] | select(excluded) | .error // ""][0] // "") as $e
            | if $e | test("credential|cannot run here"; "i") then "bash_preflight"
              elif $e | test("rate.?limit|usage.?limit|429|overloaded"; "i") then "rate_limited"
              elif $e | test("not logged in|authenticat"; "i") then "auth"
              elif ($runs | length) == 0 then "no_runs"
              else "not_started" end;
        def mean($runs): ($runs | map(.score) | add) / ($runs | length);
        (.cases[0] // {}) as $case
        | ($case.arms.with // []) as $with_all | ($case.arms.without // []) as $without_all
        | ($with_all | map(select(excluded | not))) as $with
        | ($without_all | map(select(excluded | not))) as $without
        | {title: $title, id: $id, cost_usd: (.costUsd // 0),
           runs: {with: ($with | length), without: ($without | length),
                  excluded: (($with_all | length) + ($without_all | length) - ($with | length) - ($without | length))}}
        + if ($with | length) == 0 or ($without | length) == 0 then
              {status: "not_evaluated",
               reason: (if ($with | length) == 0 then reason_of($with_all) else reason_of($without_all) end)}
          elif mean($without) >= 1 then
              {status: "invalid", with: mean($with), without: mean($without)}
          else
              {status: "evaluated", with: mean($with), without: mean($without), delta: (mean($with) - mean($without))}
          end
        + (if $status == 2 then {partial: true} else {} end)' "$3"
}

not_evaluated() { # <title> <id> <reason> [費用]
    jq -n -c --arg title "$1" --arg id "$2" --arg reason "$3" --argjson cost "${4:-0}" \
        '{title: $title, id: $id, status: "not_evaluated", reason: $reason, cost_usd: $cost}'
}

# 評価を起動したのに評価できなかったケースの費用。result.json の costUsd が読めればそれを、読めなければ渡した
# 予算を使い切ったものとして返す(費用を 0 にすると、次のケースに予算の全額が渡って総額の上限を超える)
failed_cost() { # <result.json> <渡した予算>
    jq -e 'if (.costUsd | type) == "number" then .costUsd else error end' "$1" 2>/dev/null || printf '%s\n' "$2"
}

# ケースの id。日付と title のハッシュで決め、同じ日の再実行で別のルールの実体を上書きしない(同じ title なら
# 同じルールなので作り直す)
case_id() { # <title>
    local digest
    digest=$(printf '%s' "$1" | shasum -a 256) || return 1
    printf '%s-%s\n' "$DATE" "${digest:0:8}"
}

# 1 ケースの plugin を ~/.claude/harness/evals/<id>/ に作り、出典の transcript の実体をコピーする。評価しない
# ケース(件数や予算の上限を超えたもの)も実体は残す(transcript は 30 日で消えるため)。
# 終了コード: 0 = 作った、3 = 出典の transcript が無い、4 = 再開する履歴が大きすぎる、1 = 作れなかった。
# 呼び出し側はコマンド置換の外で呼ぶ(コマンド置換の中では set -e が効かない)ので、各段で明示的に返す
prepare_case() { # <依頼の要素(JSON)> <id>
    local request=$1 id=$2 sid dir case_dir transcript lines history_bytes has_history=false
    sid=$(jq -r '.source_session' <<<"$request") || return 1
    dir="$EVALS_DIR/$id"
    case_dir="$dir/evals/$id"
    rm -rf "$dir" || return 1
    mkdir -p "$dir/.claude-plugin" "$dir/hooks" "$case_dir" || return 1
    cp "$PLUGIN_TEMPLATE/.claude-plugin/plugin.json" "$dir/.claude-plugin/plugin.json" || return 1
    cp "$PLUGIN_TEMPLATE/hooks/hooks.json" "$dir/hooks/hooks.json" || return 1
    jq -c '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: .rule}}' <<<"$request" \
        >"$dir/hooks/rule.json" || return 1
    jq '.' <<<"$request" >"$dir/request.json" || return 1
    transcript=$(find_transcript "$sid") || return 3
    cp "$transcript" "$dir/source.jsonl" || return 1
    lines=$(jq -r '.history_lines // 0' <<<"$request") || return 1
    if [[ "$lines" -gt 0 ]]; then
        has_history=true
        head -n "$lines" "$dir/source.jsonl" >"$case_dir/history.jsonl" || return 1
        history_bytes=$(wc -c <"$case_dir/history.jsonl" | tr -d ' ') || return 1
        [[ "$history_bytes" -le "$MAX_HISTORY_BYTES" ]] || return 4
    fi
    # case.yaml は JSON で書く(JSON は YAML として読める)。プロンプトや pattern の引用符を jq に任せるため
    jq --arg name "$id" --argjson turns "$MAX_TURNS" --argjson timeout "$TIMEOUT_SECONDS" \
        --argjson history "$has_history" '
        {schema_version: "1.1", name: $name,
         execution: {prompt: .prompt, max_turns: $turns, timeout_seconds: $timeout,
                     allowed_tools: (.allowed_tools // [])},
         graders: [.graders[] | {name, type, weight: 1}
             + (if .type == "regex" then {pattern, target: (.target // "last_message"),
                    match: (.match // "contains"), flags: (.flags // "")}
                elif .type == "tool_used" then {tool} + (if has("min") then {min} else {} end)
                    + (if has("max") then {max} else {} end)
                else {criteria} end)]}
        + (if $history then {context: {history_file: "history.jsonl"}} else {} end)' \
        <<<"$request" >"$case_dir/case.yaml" || return 1
}

# 作ったケースを評価し、結果の 1 要素を出す
run_case() { # <依頼の要素(JSON)> <id> <残りの予算>
    local request=$1 id=$2 budget=$3 title dir stage entry allow=() status=0
    title=$(jq -r '.title' <<<"$request") || return 1
    dir="$EVALS_DIR/$id"
    if jq -e '(.allowed_tools // []) | index("Bash")' <<<"$request" >/dev/null; then
        allow=(--allow-tools Bash)
    fi
    # 評価は作業用の写しで走らせる。nono の内側では、plugin eval がケースの祖先のディレクトリを調べるときに
    # /Users を読めず(EPERM)、~/.claude/harness/evals の下のケースを読み込まない(nono 0.79.0 で実測)。
    # 写しには plugin・ケース・履歴だけを置き、出典の transcript の全体(source.jsonl)は置かない。
    # 結果とログは実体の側に戻す。
    # --no-publish: 既定では報告が claude.ai に発行され、transcript 由来のプロンプトが載る。
    # --threshold 0: 既定の 1.0 では満点でないケースが exit 1 になり、実行の失敗と区別できない
    # HARNESS_DISABLE=1: 評価のセッションは利用者の SessionEnd フックで pending に積まれうる(履歴付きのケースは
    # 10 ターンの閾値を超える)。週次ジョブは自分で export するが、手動の /harness-review の経路は付けないので
    # ここで付ける
    stage="$WORK_ROOT/$id"
    if ! { rm -rf "$stage" && mkdir -p "$stage" && cp -R "$dir/.claude-plugin" "$dir/hooks" "$dir/evals" "$stage/"; }; then
        not_evaluated "$title" "$id" eval_failed
        return 0
    fi
    (cd "$stage" && HARNESS_DISABLE=1 claude plugin eval . --ablation with-without --no-publish --trust-plugin \
        --threshold 0 --runs "$RUNS" --max-cost-usd "$budget" --json "$stage/result.json" \
        ${allow[@]+"${allow[@]}"}) >"$dir/run.log" 2>&1 || status=$?
    rm -f "$dir/result.json"
    if [[ -f "$stage/result.json" ]]; then
        cp "$stage/result.json" "$dir/result.json" || status=1
    fi
    rm -rf "$stage"
    if [[ "$status" -ne 0 && "$status" -ne 2 ]] ||
        ! jq -e '.cases | type == "array" and length > 0' "$dir/result.json" >/dev/null 2>&1 ||
        ! entry=$(judge_case "$title" "$id" "$dir/result.json" "$status"); then
        not_evaluated "$title" "$id" eval_failed "$(failed_cost "$dir/result.json" "$budget")"
        return 0
    fi
    printf '%s\n' "$entry"
}

run_mode() {
    local count index=0 evaluated=0 request id title remaining spent=0 cost entry prepared cases exempt over_cap
    [[ -n "$REQUESTS" && -n "$OUT" && "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage
    [[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || fail "HARNESS_EVAL_RUNS is not a positive number: $RUNS"
    [[ "$MAX_CASES" =~ ^[0-9]+$ ]] || fail "HARNESS_EVAL_MAX_CASES is not a number: $MAX_CASES"
    [[ "$MAX_CASES" -le "$CASE_LIMIT" ]] || MAX_CASES=$CASE_LIMIT
    [[ "$BUDGET_USD" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "HARNESS_EVAL_BUDGET_USD is not a number: $BUDGET_USD"
    [[ -f "$PLUGIN_TEMPLATE/.claude-plugin/plugin.json" && -f "$PLUGIN_TEMPLATE/hooks/hooks.json" ]] ||
        fail "the eval plugin template $PLUGIN_TEMPLATE is missing; run chezmoi apply"
    jq -e "$REQUEST_DEFS"'type == "object" and (.cases | type == "array")
        and all(.cases[]; type == "object" and (.title | nonempty_string))' "$REQUESTS" >/dev/null 2>&1 ||
        fail "the request file $REQUESTS is missing or not {\"cases\": [...]} with a title on each"
    mkdir -p "$EVALS_DIR"
    RESULTS_TMP=$(mktemp "$HARNESS_DIR/.eval-results.XXXXXX")
    trap 'rm -f "$RESULTS_TMP"' EXIT
    count=$(jq '.cases | length' "$REQUESTS")
    while [[ "$index" -lt "$count" ]]; do
        request=$(jq -c --argjson i "$index" '.cases[$i]' "$REQUESTS")
        index=$((index + 1))
        title=$(jq -r '.title' <<<"$request")
        if jq -e 'has("exempt")' <<<"$request" >/dev/null; then
            if jq -e "$REQUEST_DEFS"'exempt_valid' <<<"$request" >/dev/null; then
                jq -c '{kind: "exempt", title, reason: .exempt}' <<<"$request" >>"$RESULTS_TMP"
            else
                not_evaluated "$title" "" bad_request | jq -c '{kind: "case"} + . | del(.id)' >>"$RESULTS_TMP"
            fi
            continue
        fi
        id=$(case_id "$title")
        if jq -e --arg t "$title" '[.cases[] | select(has("exempt") | not) | select(.title == $t)] | length > 1' \
            "$REQUESTS" >/dev/null; then
            # id は title で決まるので、同じ title のケースは互いの実体を消し合う。どちらも作らない
            entry=$(not_evaluated "$title" "" bad_request | jq -c 'del(.id)')
        elif ! jq -e "$REQUEST_DEFS"'case_valid' <<<"$request" >/dev/null; then
            # 形の不正な依頼は出典を信用できないので、実体も作らない
            entry=$(not_evaluated "$title" "$id" bad_request)
        else
            prepared=0
            prepare_case "$request" "$id" || prepared=$?
            remaining=$(jq -n --argjson b "$BUDGET_USD" --argjson s "$spent" '(($b - $s) * 10000 | round) / 10000')
            if [[ "$prepared" -eq 0 && "$evaluated" -ge "$MAX_CASES" ]]; then
                jq -c '{kind: "over_cap", title}' <<<"$request" >>"$RESULTS_TMP"
                continue
            elif [[ "$prepared" -eq 3 ]]; then
                entry=$(not_evaluated "$title" "$id" transcript_missing)
            elif [[ "$prepared" -eq 4 ]]; then
                entry=$(not_evaluated "$title" "$id" history_too_large)
            elif [[ "$prepared" -ne 0 ]]; then
                entry=$(not_evaluated "$title" "$id" setup_failed)
            elif jq -e -n --argjson r "$remaining" '$r <= 0' >/dev/null; then
                entry=$(not_evaluated "$title" "$id" budget_exhausted)
            else
                evaluated=$((evaluated + 1))
                # run_case 自体が失敗したときは、評価を起動した後かもしれないので予算を使い切ったものとする
                entry=$(run_case "$request" "$id" "$remaining") ||
                    entry=$(not_evaluated "$title" "$id" eval_failed "$remaining")
            fi
        fi
        # 注入したルールのハッシュ。依頼はローカルにしか残らないので、PR で commit したルールと同じものを注入したかを
        # PR の本文から確かめられるようにする
        if jq -e '.rule | type == "string"' <<<"$request" >/dev/null; then
            entry=$(jq -c --arg sha "$(jq -j '.rule' <<<"$request" | shasum -a 256 | cut -c1-12)" \
                '. + {rule_sha256: $sha}' <<<"$entry")
        fi
        cost=$(jq '.cost_usd // 0' <<<"$entry")
        spent=$(jq -n --argjson s "$spent" --argjson c "$cost" '$s + $c')
        jq -c '{kind: "case"} + .' <<<"$entry" >>"$RESULTS_TMP"
    done
    jq -s --arg date "$DATE" '{date: $date,
        cases: map(select(.kind == "case") | del(.kind)),
        exempt: map(select(.kind == "exempt") | del(.kind)),
        over_cap: map(select(.kind == "over_cap") | .title),
        cost_usd: (map(.cost_usd // 0) | add // 0)}' "$RESULTS_TMP" >"$OUT.tmp"
    mv "$OUT.tmp" "$OUT"
    cases=$(jq '.cases | length' "$OUT")
    exempt=$(jq '.exempt | length' "$OUT")
    over_cap=$(jq '.over_cap | length' "$OUT")
    printf 'harness-eval-cases: %s case(s), %s run, %s exempt, %s over the cap of %s; results in %s\n' \
        "$cases" "$evaluated" "$exempt" "$over_cap" "$MAX_CASES" "$OUT"
}

# PR の本文の「ルールの効果」の節。採用したルールのうち、結果にも免除にも無いものは「評価も免除の理由も無い」として
# 名前を出す(黙って抜けないように)。表のセルの `|` は区切りにならないよう `\|` にする
section_mode() {
    local adopted_json="[]"
    [[ -n "$RESULTS" ]] || usage
    jq -e 'type == "object" and (.cases | type == "array") and (.exempt | type == "array") and (.over_cap | type == "array")' \
        "$RESULTS" >/dev/null 2>&1 || fail "the results file $RESULTS is missing or malformed"
    if [[ -n "$ADOPTED" ]]; then
        adopted_json=$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$ADOPTED") || fail "cannot read $ADOPTED"
    fi
    # shellcheck disable=SC2016 # jq の式
    jq -r --argjson adopted "$adopted_json" '
        def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");
        def num: (. * 100 | round) / 100 | tostring;
        def signed: if . > 0 then "+" + num else num end;
        def reason_text: {
            bash_preflight: "評価できなかった(Bash を許可する評価が事前確認で止まった)",
            rate_limited: "評価できなかった(レート制限・利用上限)",
            auth: "評価できなかった(認証)",
            not_started: "評価できなかった(run が始まらなかった)",
            no_runs: "評価できなかった(run が無い)",
            transcript_missing: "評価できなかった(出典の transcript が無い)",
            history_too_large: "評価できなかった(再開する履歴が大きすぎる)",
            eval_failed: "評価できなかった(評価の実行に失敗した)",
            budget_exhausted: "評価できなかった(予算を使い切った)",
            bad_request: "評価できなかった(依頼の形が不正)",
            setup_failed: "評価できなかった(ケースを作れなかった)"}[.] // "評価できなかった";
        ([.cases[].title] + [.exempt[].title] + .over_cap) as $covered
        | ($adopted - $covered) as $missing
        | "\n## ルールの効果\n",
          "Eval Case ごとに、ルールを注入した側(with)と注入しない側(without)の平均得点(0〜1)と Δ。without の側で失敗が再現しないケースは無効とし、レート制限などで評価できなかった run は得点から除いている。\n",
          (if (.cases | length) > 0 then
              "| ルール | Eval Case | with | without | Δ | 判定 |",
              "|---|---|---:|---:|---:|---|",
              (.cases[] |
                  "| \(.title | cell) | `\(.id // "-")` | \(if .with != null then (.with | num) else "-" end) | \(if .without != null then (.without | num) else "-" end) | \(if .status == "evaluated" then (.delta | signed) else "-" end) | \(
                      if .status == "evaluated" then "有効" + (if .partial then "(予算の上限で一部の run が欠けた)" else "" end)
                      elif .status == "invalid" then "無効(ルールの無い側で失敗が再現しない)"
                      else (.reason | reason_text) end) |")
           else "評価した Eval Case は無い。" end),
          (if (.exempt | length) > 0 then "\n### 免除\n", (.exempt[] | "- \(.title | cell): \(.reason | cell)") else empty end),
          (if (.over_cap | length) > 0 then "\n### 件数の上限で今回は評価しなかったもの\n", (.over_cap[] | "- \(. | cell)") else empty end),
          (if ($missing | length) > 0 then "\n### 評価も免除の理由も無い採用\n", ($missing[] | "- \(. | cell)") else empty end),
          (if ([.cases[] | select(.rule_sha256 != null)] | length) > 0 then
              "\n### 注入したルールの sha256(先頭 12 桁)\n",
              "with の側に注入したルール本文の `printf %s \"<ルール>\" | shasum -a 256` の先頭。PR で commit したルールと一致するかの確認に使う。\n",
              (.cases[] | select(.rule_sha256 != null) | "- \(.title | cell): `\(.rule_sha256)`")
           else empty end),
          (if ([.cases[] | select(.id != null)] | length) > 0 then
              "\n各ケースの依頼(ルール・プロンプト・grader)は、このマシンの `~/.claude/harness/evals/<Eval Case>/request.json` にある。grader が自明でないか、注入したルールが PR で commit したルールと同じかはそこで確かめる。"
           else empty end),
          "\n評価の費用(定価での推定): $\(.cost_usd | num)"' "$RESULTS"
}

case "$MODE" in
run) run_mode ;;
section) section_mode ;;
*) usage ;;
esac
