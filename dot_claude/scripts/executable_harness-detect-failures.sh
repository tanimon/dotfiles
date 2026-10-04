#!/usr/bin/env bash
# 失敗の検出器(Evaluator の一部。ADR 0011)。Claude Code の transcript(.jsonl)を 1 つ受け取り、
# 失敗の発生を 1 件 1 行の JSON({"line":<transcript の行番号>,"signal":<信号>})で行の順に出す。
# LLM は使わず、同じ入力には常に同じ出力を返す。選別(harness-select-pending.sh)と
# harness-reflect スキルがこれで抽出の入力を選ぶ。
#
# 信号(1 つの tool_result には上から最初に当たった 1 つだけを付ける):
#   user_rejection  人がツールの実行を拒否した
#   user_interrupt  人が中断した。並列のツールの中断と、拒否・中断の直後の中断の文は同じ出来事なので、
#                   人の発言かそれ以外の tool_result を挟むまで数えない
#   hook_deny       hook が拒否した(内容の先頭が "<Event>:<Tool> hook error:")
#   ci_failure      gh pr checks / gh run view|watch|list の結果に失敗がある。gh pr checks は失敗で
#                   exit 1 になり is_error も立つので、tool_error より先に判定する
#   tool_error      それ以外の is_error。auto mode の分類器や権限の拒否も人の訂正ではないのでここに入る
#   user_negation   人の発言が否定で始まる
#   repeat          同じツール呼び出し(名前と入力が一致)が 3 回続いた。間の text は続きを切らない
#
# 判定は構造化されたフィールドだけで行い、行の生の文字列は見ない(ツールの入力や出力に
# 目印の文字列が書かれているだけの行を数えないため)。JSON として読めない行は飛ばす。
# 人の発言は、isMeta・isCompactSummary・isSidechain・toolUseResult が無く、origin が無いか
# human のもので、"<" や "Base directory for this skill:" で始まらないもの(スキル本文や
# コマンドの展開は type:"user" で記録されるため)。
#
# 終了コード: 0 = 判定した(検出 0 件を含む)、2 = 引数が無い・transcript を読めない・jq が無い
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: harness-detect-failures.sh <transcript.jsonl>\n' >&2
    exit 2
fi
command -v jq >/dev/null 2>&1 || {
    printf 'harness-detect-failures: jq not found\n' >&2
    exit 2
}
if [[ ! -f "$1" || ! -r "$1" ]]; then
    printf 'harness-detect-failures: cannot read %s\n' "$1" >&2
    exit 2
fi

# shellcheck disable=SC2016 # jq のプログラム
DETECT='
def text_of:
    if type == "string" then .
    elif type == "array" then map(select(type == "object" and .type == "text") | .text // "") | join("\n")
    else "" end;
def is_interrupt: startswith("[Request interrupted by user");
def is_human_text:
    .type == "user" and .isMeta != true and .isCompactSummary != true and .isSidechain != true
    and .toolUseResult == null and (.origin == null or .origin.kind == "human")
    and ((.message.content | type) == "string"
        or ((.message.content | type) == "array" and all(.message.content[]; type == "object" and .type == "text")));
def negation:
    test("\\A(違う|違います|ちがう|いや[、。,.!！ 　]|いえ[、。,. 　]|そうじゃな|そうではな|そうでなく|やめ|待って|まって|ストップ|だめ|ダメ|駄目|戻して|元に戻して|間違って|no\\b|nope\\b|stop\\b|wait\\b|wrong\\b|don.t\\b|do not\\b|not that\\b|that.s not\\b|revert\\b|undo\\b)"; "i");
def ci_failure($tool):
    ($tool.name // "") == "Bash"
    and (($tool.input.command // "") | tostring | test("\\bgh\\s+(pr\\s+checks|run\\s+(view|watch|list))\\b"))
    and (test("(\\A|[\\t\\n])(fail|failure)(\\t|\\n|\\z)")
        or test("\"(conclusion|bucket|state)\"\\s*:\\s*\"(failure|fail|FAILURE)\"")
        or test("(\\A|\\n)X "));
# 中断は、直前の人の出来事が拒否か中断ならその続きとして数えない
def interrupt($line):
    if .last == "user_rejection" or .last == "user_interrupt" then .
    else .out += [{line: $line, signal: "user_interrupt"}] end
    | .last = "user_interrupt";

[inputs]
| to_entries
| map({line: (.key + 1), entry: (.value | try fromjson catch null)})
| map(select(.entry | type == "object"))
| reduce .[] as $item ({tools: {}, key: null, run: 0, last: null, out: []};
    $item.line as $line | $item.entry as $e
    | if $e.type == "assistant" and ($e.message.content | type) == "array" then
        reduce ($e.message.content[] | select(type == "object" and .type == "tool_use")) as $use (.;
            .tools[$use.id // ""] = {name: $use.name, input: $use.input}
            | (($use.name // "") + "\u0000" + ($use.input | tojson)) as $key
            | (if .key == $key then .run += 1 else .key = $key | .run = 1 end)
            | if .run == 3 then .out += [{line: $line, signal: "repeat"}] else . end)
    elif $e.type == "user" and ($e.message.content | type) == "array"
        and any($e.message.content[]; type == "object" and .type == "tool_result") then
        reduce ($e.message.content[] | select(type == "object" and .type == "tool_result")) as $result (.;
            ($result.content | text_of) as $text
            | if ($text | test("\\AThe user doesn.t want to proceed with this tool use")) then
                .out += [{line: $line, signal: "user_rejection"}] | .last = "user_rejection"
            elif ($text | is_interrupt) then interrupt($line)
            else
                .last = null
                | if $result.is_error == true and ($text | test("\\A[A-Za-z]+(:\\S+)? hook (blocking )?error:")) then
                    .out += [{line: $line, signal: "hook_deny"}]
                elif (.tools[$result.tool_use_id // ""] // {}) as $tool | ($text | ci_failure($tool)) then
                    .out += [{line: $line, signal: "ci_failure"}]
                elif $result.is_error == true then
                    .out += [{line: $line, signal: "tool_error"}]
                else . end
            end)
    elif ($e | is_human_text) then
        ($e.message.content | text_of | sub("\\A\\s+"; "")) as $text
        | if ($text | is_interrupt) then interrupt($line)
        elif ($text | startswith("<")) or ($text | startswith("Base directory for this skill:")) then .
        else
            .last = null
            | if ($text | negation) then .out += [{line: $line, signal: "user_negation"}] else . end
        end
    else . end)
| .out[]
'

jq -R -n -c "$DETECT" "$1"
