# Eval Case と 2 アーム評価(harness-eval-cases.sh)の入出力の検査。
#
# 偽の $HOME にスクリプトと eval 専用 plugin の雛形を本来の配置先(~/.claude/scripts/)へ置き、出典の
# transcript は合成の fixture を ~/.claude/projects/ の下に置く。claude は PATH 上のスタブで、引数を
# $ARGV_LOG に 1 行で写し、--json の先に test/fixtures/harness-eval-cases/ の結果を書く。どの結果を
# 書くかは STUB_EVAL_<何回目の起動か>(例: STUB_EVAL_02=ceiling)か、無ければ STUB_EVAL(既定 effective)。
# STUB_EVAL_EXIT で終了コードを変える。
bats_require_minimum_version 1.5.0

SID_A=11111111-1111-4111-8111-111111111111
SID_B=22222222-2222-4222-8222-222222222222
DATE=2026-10-10

setup() {
    load 'helpers/setup'
    load 'helpers/exec-cache'
    unset HARNESS_EVAL_RUNS HARNESS_EVAL_BUDGET_USD HARNESS_EVAL_MAX_CASES HARNESS_EVAL_MAX_HISTORY_BYTES HARNESS_EVAL_PLUGIN_TEMPLATE \
        HARNESS_EVAL_WORK_DIR \
        STUB_EVAL STUB_EVAL_EXIT
    export HOME="$BATS_TEST_TMPDIR/home"
    HDIR="$HOME/.claude/harness"
    PROJECTS="$HOME/.claude/projects/-work-repo"
    mkdir -p "$HDIR" "$PROJECTS" "$HOME/.claude/scripts/harness-eval-plugin/.claude-plugin" \
        "$HOME/.claude/scripts/harness-eval-plugin/hooks"
    SCRIPT="$HOME/.claude/scripts/harness-eval-cases.sh"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_harness-eval-cases.sh" "$SCRIPT"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-eval-plugin/dot_claude-plugin/plugin.json" \
        "$HOME/.claude/scripts/harness-eval-plugin/.claude-plugin/plugin.json"
    cp "$BATS_TEST_DIRNAME/../dot_claude/scripts/harness-eval-plugin/hooks/hooks.json" \
        "$HOME/.claude/scripts/harness-eval-plugin/hooks/hooks.json"
    cp "$BATS_TEST_DIRNAME/fixtures/harness-detect-failures/negation.jsonl" "$PROJECTS/$SID_A.jsonl"
    cp "$BATS_TEST_DIRNAME/fixtures/harness-detect-failures/tool-error.jsonl" "$PROJECTS/$SID_B.jsonl"
    export FIXTURES="$BATS_TEST_DIRNAME/fixtures/harness-eval-cases"
    export HARNESS_EVAL_WORK_DIR="$BATS_TEST_TMPDIR/work"
    export ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"
    REQUESTS="$BATS_TEST_TMPDIR/requests.json"
    OUT="$BATS_TEST_TMPDIR/results.json"
    STUBS="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$STUBS"
    install_exec "$STUBS/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ARGV_LOG"
json=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == --json ]] && json=$2
    shift
done
[[ ! -e source.jsonl ]] || printf 'source.jsonl in the staging copy\n' >>"$ARGV_LOG"
calls=$(grep -c '^plugin eval' "$ARGV_LOG")
var=$(printf 'STUB_EVAL_%02d' "$calls")
fixture=${!var:-${STUB_EVAL:-effective}}
cp "$FIXTURES/$fixture.json" "$json"
exit "${STUB_EVAL_EXIT:-0}"
EOF
    export PATH="$STUBS:$PATH"
}

# 依頼を書く。引数は cases の要素(JSON)
requests() {
    jq -n '{cases: $ARGS.positional | map(fromjson)}' --args "$@" >"$REQUESTS"
}

rule_case() { # <title> [session] [追加のキー(JSON)]
    jq -n -c --arg title "$1" --arg sid "${2:-$SID_A}" --argjson extra "${3:-null}" '{title: $title,
        rule: "区切り線は head -c N /dev/zero | tr \"\\\\0\" <文字> で作る", source_session: $sid,
        prompt: "区切り線を出すコマンドを 1 行で", graders: [{name: "uses-dev-zero", type: "regex", pattern: "/dev/zero"}]} + ($extra // {})'
}

# ケースの id(日付と title のハッシュ)
id_of() {
    printf '%s-%s\n' "$DATE" "$(printf '%s' "$1" | shasum -a 256 | cut -c1-8)"
}

run_eval() {
    run --separate-stderr bash "$SCRIPT" run --requests "$REQUESTS" --date "$DATE" --out "$OUT"
}

@test "ルールの候補ごとに Eval Case の plugin が作られ、transcript の実体がコピーされる" {
    requests "$(rule_case '[2026-10-09] A を守る')" "$(rule_case '[2026-10-09] B を守る' "$SID_B")"
    run_eval
    assert_success
    id1=$(id_of '[2026-10-09] A を守る')
    id2=$(id_of '[2026-10-09] B を守る')
    for id in "$id1" "$id2"; do
        dir="$HDIR/evals/$id"
        assert [ -f "$dir/.claude-plugin/plugin.json" ]
        assert [ -f "$dir/hooks/hooks.json" ]
        assert [ -f "$dir/evals/$id/case.yaml" ]
    done
    cmp "$HDIR/evals/$id1/source.jsonl" "$PROJECTS/$SID_A.jsonl"
    cmp "$HDIR/evals/$id2/source.jsonl" "$PROJECTS/$SID_B.jsonl"
    # ルール本文は with の側に注入する SessionStart の additionalContext になる
    run jq -r '.hookSpecificOutput | "\(.hookEventName) \(.additionalContext)"' "$HDIR/evals/$id1/hooks/rule.json"
    assert_output 'SessionStart 区切り線は head -c N /dev/zero | tr "\\0" <文字> で作る'
    run jq -c '{name, prompt: .execution.prompt, graders}' "$HDIR/evals/$id1/evals/$id1/case.yaml"
    assert_output "{\"name\":\"$id1\",\"prompt\":\"区切り線を出すコマンドを 1 行で\",\"graders\":[{\"name\":\"uses-dev-zero\",\"type\":\"regex\",\"weight\":1,\"pattern\":\"/dev/zero\",\"target\":\"last_message\",\"match\":\"contains\",\"flags\":\"\"}]}"
}

@test "評価の起動は固定の引数で行い、発行せず、閾値で失敗させない" {
    requests "$(rule_case '[2026-10-09] A を守る')"
    run_eval
    assert_success
    id=$(id_of '[2026-10-09] A を守る')
    run cat "$ARGV_LOG"
    assert_output "plugin eval . --ablation with-without --no-publish --trust-plugin --threshold 0 --runs 2 --max-cost-usd 5 --json $HARNESS_EVAL_WORK_DIR/$id/result.json"
    # 評価は作業用の写しで走り、結果は実体の側に戻って写しは消える
    assert [ -f "$HDIR/evals/$id/result.json" ]
    assert [ ! -e "$HARNESS_EVAL_WORK_DIR/$id" ]
}

@test "依頼が run 数・ターン数・発行を決めようとしても、スクリプトの値が使われる" {
    requests "$(rule_case '[2026-10-09] A を守る' "$SID_A" '{"runs": 50, "max_turns": 200, "publish": true}')"
    run_eval
    assert_success
    id=$(id_of '[2026-10-09] A を守る')
    run jq -c '.execution | {max_turns, timeout_seconds}' "$HDIR/evals/$id/evals/$id/case.yaml"
    assert_output '{"max_turns":10,"timeout_seconds":300}'
    refute grep -q -- '--runs 50' "$ARGV_LOG"
    refute grep -q -- '--publish' "$ARGV_LOG"
}

@test "ルールの無い側で失敗が再現したケースは Δ を出し、再現しないケースは無効になる" {
    requests "$(rule_case '[2026-10-09] 効く')" "$(rule_case '[2026-10-09] 天井')"
    STUB_EVAL_02=ceiling run_eval
    assert_success
    run jq -c '.cases[] | {title, status, with, without, delta}' "$OUT"
    assert_line --index 0 '{"title":"[2026-10-09] 効く","status":"evaluated","with":1,"without":0,"delta":1}'
    assert_line --index 1 '{"title":"[2026-10-09] 天井","status":"invalid","with":1,"without":1,"delta":null}'
}

@test "レート制限・利用上限で 0 点になった run は得点から除き、残りが無ければ評価できなかったとする" {
    requests "$(rule_case '[2026-10-09] 上限')"
    STUB_EVAL=rate-limited run_eval
    assert_success
    run jq -c '.cases[0] | {status, reason, delta, runs}' "$OUT"
    assert_output '{"status":"not_evaluated","reason":"rate_limited","delta":null,"runs":{"with":2,"without":0,"excluded":2}}'
}

@test "一部の run だけが上限に当たったときは、残りの run で平均を取り直す(eval の aggregates は使わない)" {
    requests "$(rule_case '[2026-10-09] 一部')"
    STUB_EVAL=partly-rate-limited run_eval
    assert_success
    run jq -c '.cases[0] | {status, with, without, delta, runs}' "$OUT"
    assert_output '{"status":"evaluated","with":1,"without":0,"delta":1,"runs":{"with":1,"without":1,"excluded":2}}'
}

@test "ターン数の上限で終わった run は除かずに採点する" {
    requests "$(rule_case '[2026-10-09] 長い')"
    STUB_EVAL=max-turns run_eval
    assert_success
    run jq -c '.cases[0] | {status, without, delta, excluded: .runs.excluded}' "$OUT"
    assert_output '{"status":"evaluated","without":0.25,"delta":0.75,"excluded":0}'
}

@test "Bash を許可したケースは別の起動で --allow-tools Bash を付け、事前確認で止まれば評価できなかったとする" {
    requests "$(rule_case '[2026-10-09] ツール無し')" \
        "$(rule_case '[2026-10-09] Bash' "$SID_A" '{"allowed_tools": ["Bash"]}')"
    STUB_EVAL_02=bash-preflight run_eval
    assert_success
    run grep -c -- '--allow-tools Bash' "$ARGV_LOG"
    assert_output 1
    run sed -n 2p "$ARGV_LOG"
    assert_output --partial '--allow-tools Bash'
    run jq -c '.cases | map({status, reason})' "$OUT"
    assert_output '[{"status":"evaluated","reason":null},{"status":"not_evaluated","reason":"bash_preflight"}]'
}

@test "1 回の run で評価するケースは 20 件までで、上限を上げても 20 件を超えない" {
    local args=() i
    for i in $(seq 1 22); do args+=("$(rule_case "[2026-10-09] ルール $i")"); done
    requests "${args[@]}"
    HARNESS_EVAL_MAX_CASES=50 run_eval
    assert_success
    run jq -c '{cases: (.cases | length), over_cap}' "$OUT"
    assert_output '{"cases":20,"over_cap":["[2026-10-09] ルール 21","[2026-10-09] ルール 22"]}'
    run wc -l <"$ARGV_LOG"
    assert_output --regexp '^ *20$'
}

@test "免除は理由付きで残し、評価を起動しない" {
    requests '{"title":"[2026-10-09] 書けない","exempt":"失敗が人の判断の誤りで、プロンプトで再現できない"}'
    run_eval
    assert_success
    run jq -c '{cases, exempt}' "$OUT"
    assert_output '{"cases":[],"exempt":[{"title":"[2026-10-09] 書けない","reason":"失敗が人の判断の誤りで、プロンプトで再現できない"}]}'
    assert [ ! -e "$ARGV_LOG" ]
}

@test "出典の transcript が無い・symlink・projects の外を指すケースは評価しない" {
    ln -s "$BATS_TEST_TMPDIR/outside.jsonl" "$PROJECTS/$SID_B.jsonl.tmp"
    printf '{}\n' >"$BATS_TEST_TMPDIR/outside.jsonl"
    rm "$PROJECTS/$SID_B.jsonl"
    mv "$PROJECTS/$SID_B.jsonl.tmp" "$PROJECTS/$SID_B.jsonl"
    requests "$(rule_case '[2026-10-09] 無い' 33333333-3333-4333-8333-333333333333)" \
        "$(rule_case '[2026-10-09] symlink' "$SID_B")"
    run_eval
    assert_success
    run jq -c '.cases | map(.reason)' "$OUT"
    assert_output '["transcript_missing","transcript_missing"]'
    assert [ ! -e "$HDIR/evals/$(id_of '[2026-10-09] symlink')/source.jsonl" ]
    assert [ ! -e "$ARGV_LOG" ]
}

@test "session id の形でない出典と、受け付けない grader の依頼は評価しない" {
    requests "$(rule_case '[2026-10-09] glob' '*')" \
        "$(rule_case '[2026-10-09] baseline' "$SID_A" '{"graders": [{"name": "b", "type": "baseline"}]}')" \
        "$(rule_case '[2026-10-09] Skill' "$SID_A" '{"graders": [{"name": "s", "type": "tool_used", "tool": "Skill"}]}')"
    run_eval
    assert_success
    run jq -c '.cases | map(.reason)' "$OUT"
    assert_output '["bad_request","bad_request","bad_request"]'
    assert [ ! -e "$ARGV_LOG" ]
}

@test "history_lines の行までを再開する履歴にし、大きすぎれば評価しない" {
    requests "$(rule_case '[2026-10-09] 履歴' "$SID_A" '{"history_lines": 1}')" \
        "$(rule_case '[2026-10-09] 大きい' "$SID_A" '{"history_lines": 2}')"
    HARNESS_EVAL_MAX_HISTORY_BYTES=$(head -n 1 "$PROJECTS/$SID_A.jsonl" | wc -c | tr -d ' ') run_eval
    assert_success
    run head -n 1 "$PROJECTS/$SID_A.jsonl"
    expected=$output
    id=$(id_of '[2026-10-09] 履歴')
    run cat "$HDIR/evals/$id/evals/$id/history.jsonl"
    assert_output "$expected"
    run jq -r '.context.history_file' "$HDIR/evals/$id/evals/$id/case.yaml"
    assert_output history.jsonl
    run jq -c '.cases | map(.status)' "$OUT"
    assert_output '["evaluated","not_evaluated"]'
}

@test "予算は使った分を引いて次のケースに渡し、使い切ったら評価しない" {
    requests "$(rule_case '[2026-10-09] 1')" "$(rule_case '[2026-10-09] 2')" "$(rule_case '[2026-10-09] 3')"
    HARNESS_EVAL_BUDGET_USD=0.3 run_eval
    assert_success
    run grep -oE -- '--max-cost-usd [0-9.]+' "$ARGV_LOG"
    assert_line --index 0 -- '--max-cost-usd 0.3'
    assert_line --index 1 -- '--max-cost-usd 0.13'
    run jq -c '.cases | map(.reason // .status)' "$OUT"
    assert_output '["evaluated","evaluated","budget_exhausted"]'
}

@test "評価の起動が失敗したケースは評価できなかったとし、ほかのケースは続ける" {
    requests "$(rule_case '[2026-10-09] 1')"
    STUB_EVAL_EXIT=3 run_eval
    assert_success
    run jq -c '.cases | map(.reason)' "$OUT"
    assert_output '["eval_failed"]'
}

@test "依頼が読めなければ失敗する" {
    printf 'not json\n' >"$REQUESTS"
    run_eval
    assert_failure 1
    assert [ ! -e "$OUT" ]
}

@test "節は with / without / Δ と判定を載せ、免除・上限超過・評価も免除も無い採用を名前で出す" {
    requests "$(rule_case '[2026-10-09] 効く | 1')" "$(rule_case '[2026-10-09] 天井')" \
        "$(rule_case '[2026-10-09] 上限')" '{"title":"[2026-10-09] 書けない","exempt":"再現できない"}'
    STUB_EVAL_02=ceiling STUB_EVAL_03=rate-limited HARNESS_EVAL_MAX_CASES=2 run_eval
    assert_success
    printf '%s\n' '[2026-10-09] 効く | 1' '[2026-10-09] 書けない' '[2026-10-09] 抜け' >"$BATS_TEST_TMPDIR/adopted.txt"
    run --separate-stderr bash "$SCRIPT" section --results "$OUT" --adopted "$BATS_TEST_TMPDIR/adopted.txt"
    assert_success
    assert_line '## ルールの効果'
    assert_line "| [2026-10-09] 効く \| 1 | \`$(id_of '[2026-10-09] 効く | 1')\` | 1 | 0 | +1 | 有効 |"
    assert_line "| [2026-10-09] 天井 | \`$(id_of '[2026-10-09] 天井')\` | 1 | 1 | - | 無効(ルールの無い側で失敗が再現しない) |"
    assert_line '- [2026-10-09] 書けない: 再現できない'
    assert_line '- [2026-10-09] 上限'
    assert_line '### 評価も免除の理由も無い採用'
    assert_line '- [2026-10-09] 抜け'
}

@test "節は評価できなかったケースを固定の文言で書き、エラー文を載せない" {
    requests "$(rule_case '[2026-10-09] Bash' "$SID_A" '{"allowed_tools": ["Bash"]}')"
    STUB_EVAL=bash-preflight run_eval
    assert_success
    run --separate-stderr bash "$SCRIPT" section --results "$OUT"
    assert_success
    assert_line "| [2026-10-09] Bash | \`$(id_of '[2026-10-09] Bash')\` | - | - | - | 評価できなかった(Bash を許可する評価が事前確認で止まった) |"
    refute_output --partial 'ENOENT'
    refute_output --partial '評価も免除の理由も無い採用'
}

@test "件数の上限を超えたケースも、出典の transcript の実体はコピーする" {
    requests "$(rule_case '[2026-10-09] 1')" "$(rule_case '[2026-10-09] 2')"
    HARNESS_EVAL_MAX_CASES=1 run_eval
    assert_success
    cmp "$HDIR/evals/$(id_of '[2026-10-09] 2')/source.jsonl" "$PROJECTS/$SID_A.jsonl"
    run jq -c '.over_cap' "$OUT"
    assert_output '["[2026-10-09] 2"]'
}

@test "同じ日の再実行で、別のルールのケースの実体を上書きしない" {
    requests "$(rule_case '[2026-10-09] 1')"
    run_eval
    requests "$(rule_case '[2026-10-09] 2' "$SID_B")"
    run_eval
    assert_success
    cmp "$HDIR/evals/$(id_of '[2026-10-09] 1')/source.jsonl" "$PROJECTS/$SID_A.jsonl"
    cmp "$HDIR/evals/$(id_of '[2026-10-09] 2')/source.jsonl" "$PROJECTS/$SID_B.jsonl"
}

@test "整数でない history_lines の依頼は評価しない" {
    requests "$(rule_case '[2026-10-09] 小数' "$SID_A" '{"history_lines": 1.5}')" \
        "$(rule_case '[2026-10-09] 1.0' "$SID_A" '{"history_lines": 1.0}')"
    run_eval
    assert_success
    run jq -c '.cases | map(.reason)' "$OUT"
    assert_output '["bad_request","bad_request"]'
}

@test "ケースを作る途中で失敗したら、評価を起動せずに評価できなかったとする" {
    requests "$(rule_case '[2026-10-09] 1')"
    # 出典の transcript を読めない(コピーが失敗する)
    chmod 000 "$PROJECTS/$SID_A.jsonl"
    run_eval
    assert_success
    run jq -c '.cases | map(.reason)' "$OUT"
    assert_output '["setup_failed"]'
    assert [ ! -e "$ARGV_LOG" ]
}
