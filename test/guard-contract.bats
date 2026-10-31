#!/usr/bin/env bats
# PreToolUse の guard hook が起動時に守る約束の契約テスト。起動時の約束の正本はこのファイル。
#
# ADR 0009 の中核は「読めなければ ask(無出力にも、理由の無い exit 2 にもしない)」。この約束を守る
# 起動部(ログの確保、stdin・jq・.tool_input.command の取り出し、shell-reader の lib の検査)は
# guard ごとに写してあるので、写し同士のずれをここで捕まえる。guard 固有の判定は各 guard の bats にある。
#
# 起動時の失敗と、そのとき見る入力:
#   lib が無い / 空 / 構文エラー / guard が呼ぶ関数の 1 つが無い(古い lib)、jq が無い、stdin が JSON でない
#     → 動詞を含む入力(VERB_INPUT)は ask、含まない入力(SILENT_INPUT)は無出力
#   HOME に書き込めない / 未設定
#     → 判定を返す入力(DECISION_INPUT)の判定が変わらない、VERB_INPUT と SILENT_INPUT は無出力
#     (ログを開けないだけで guard は読めるので、VERB_INPUT を ask にするのは誤り。DECISION_INPUT の
#     期待値が ask の guard では、常に ask を返す退行を VERB_INPUT の無出力で見分ける)
# 古い lib で欠かす関数は guard ごとに違うので、lib_functions_called が guard の script から選ぶ。
#
# VERB_INPUT は lib が正常なら無出力になる入力にする。正常でも ask になる入力だと、失敗の扱いが
# 壊れていても ask が出てテストが通ってしまう。SAFE_INPUT が無出力であることを lib が正常な
# コピーで確かめる(Contrast Pair: 常に ask を返す guard はここで落ちる)。
#
# 起動時に失敗したら判定せずに通す(フェイルオープン)と設計で決めた guard は、上の約束ではなく
# fail_open_guard の一覧に載せる(issue-linkage-guard がそう決めた理由は、その guard のヘッダと
# docs/superpowers/specs/2026-10-04-ticket-skill-design.md。現行の設計は spec #577)。こちらは、起動時の失敗では判定を返す入力
# (DECISION_INPUT)も無出力になり、HOME の問題では判定が変わらないことを確かめる。
#
# 一覧(guard / fail_open_guard の呼び出し)は配線の正本ではない。描画した settings.json の PreToolUse に
# 配線された *-guard.sh が、どちらかの一覧にすべてあることを、最後の test が確かめる。

bats_require_minimum_version 1.5.0

GUARD_NAMES=()
GUARD_VERB_INPUTS=()
GUARD_SILENT_INPUTS=()
GUARD_SAFE_INPUTS=()
GUARD_DECISION_INPUTS=()
GUARD_EXPECTED_DECISIONS=()

# guard NAME VERB_INPUT SILENT_INPUT SAFE_INPUT DECISION_INPUT EXPECTED_DECISION: 一覧に 1 行足す。
# NAME は dot_claude/scripts/executable_<NAME>.sh。
guard() {
    GUARD_NAMES+=("$1")
    GUARD_VERB_INPUTS+=("$2")
    GUARD_SILENT_INPUTS+=("$3")
    GUARD_SAFE_INPUTS+=("$4")
    GUARD_DECISION_INPUTS+=("$5")
    GUARD_EXPECTED_DECISIONS+=("$6")
}

guard git-push-guard 'git push origin feature' 'git status' 'git push -u origin feature' 'git push origin main --force' deny
guard curl-localhost-guard 'curl http://localhost:3000/' 'git status' 'curl -sS http://127.0.0.1:8080/api' 'curl https://evil.example/' ask

FAIL_OPEN_NAMES=()
FAIL_OPEN_DECISION_INPUTS=()
FAIL_OPEN_EXPECTED_DECISIONS=()

# fail_open_guard NAME DECISION_INPUT EXPECTED_DECISION: フェイルオープンの一覧に 1 行足す。
# DECISION_INPUT は lib が正常なら EXPECTED_DECISION を返す入力にする(Contrast Pair: 常に無出力の guard を見分ける)。
fail_open_guard() {
    FAIL_OPEN_NAMES+=("$1")
    FAIL_OPEN_DECISION_INPUTS+=("$2")
    FAIL_OPEN_EXPECTED_DECISIONS+=("$3")
}

# -R で作成先を渡すので、テストの cwd の remote に依存せずに範囲内になる。
fail_open_guard issue-linkage-guard "gh pr create -R tanimon/sample --title t --body 'x'" deny

setup_file() {
    load 'helpers/render'
    export SETTINGS="$BATS_FILE_TMPDIR/settings.json"
    render_template personal "$RENDER_REPO/dot_claude/settings.json.tmpl" >"$SETTINGS"
}

setup() {
    load 'helpers/setup'
    SCRIPTS="$BATS_TEST_DIRNAME/../dot_claude/scripts"
    # guard はログを $HOME に開き、curl-localhost-guard は curlrc を探す。どちらもテストの空ディレクトリに向ける。
    export HOME="$BATS_TEST_TMPDIR/home"
    export CURL_HOME="$BATS_TEST_TMPDIR"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR"
    mkdir -p "$HOME"
    # issue-linkage-guard の範囲は許可リストと GH_REPO で変わるので、既定値に戻す。
    unset ISSUE_LINKAGE_GUARD_OWNERS GH_REPO
}

payload() {
    jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

decision() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

# expect GUARD MODE INPUT WANT: 直前の run の結果が WANT(ask / deny / 空 = 無出力)か。exit は常に 0。
expect() {
    [[ $status -eq 0 ]] || fail "$1 [$2] '$3': exit $status (stdout: $output)"
    if [[ -z "$4" ]]; then
        [[ -z "$output" ]] || fail "$1 [$2] '$3': 無出力のはずが: $output"
    else
        [[ "$(decision "$output")" == "$4" ]] || fail "$1 [$2] '$3': $4 のはずが: $output"
    fi
}

# lib_functions_called NAME: guard が呼ぶ lib の関数を 1 行に 1 つ出す。lib に `name() {` で定義され、
# guard の script に名前が出る関数を拾う。guard の declare -F の一覧から独立に選ぶので、呼んでいるのに
# declare -F に無い関数も拾える(guard のコメントに lib の関数名を書くと、呼んでいなくても拾う)。
lib_functions_called() {
    local function_name
    while IFS= read -r function_name; do
        if grep -qw -- "$function_name" "$SCRIPTS/executable_$1.sh"; then
            printf '%s\n' "$function_name"
        fi
    done < <(sed -nE 's/^([a-z][a-z0-9_]*)\(\).*/\1/p' "$SCRIPTS"/lib/*.bash)
}

# copy_guard NAME LIB_KIND [FUNCTION]: guard を lib ごと別の場所に写し、写した script の path を出す。
# LIB_KIND は missing / empty / syntax / stale / intact。missing は lib ディレクトリごと写さない。
# empty / syntax は shell-reader.bash だけを壊し、他の lib は正常なまま写す。
# stale は FUNCTION を定義する lib の末尾に `unset -f FUNCTION` を足す(読めて構文も正しいが、その関数だけが無い)。
copy_guard() {
    # 写し先は FUNCTION ごとに分ける(stale_copies は写しを全部作ってから使うので、同じ場所だと上書きし合う)。
    local dir="$BATS_TEST_TMPDIR/$1${3:+-$3}"
    mkdir -p "$dir"
    cp "$SCRIPTS/executable_$1.sh" "$dir/guard.sh"
    [[ $2 == missing ]] && {
        printf '%s\n' "$dir/guard.sh"
        return
    }
    mkdir -p "$dir/lib"
    cp "$SCRIPTS"/lib/*.bash "$dir/lib/"
    case $2 in
    empty) : >"$dir/lib/shell-reader.bash" ;;
    syntax) printf '%s\n' 'shell_reader_read() {' >"$dir/lib/shell-reader.bash" ;;
    stale)
        local library
        library=$(grep -l -- "^$3()" "$dir"/lib/*.bash) || library=
        if [[ -z "$library" || "$library" == *$'\n'* ]]; then
            printf '%s\n' "copy_guard: $3 を定義する lib がちょうど 1 つではない: ${library:-なし}" >&2
            return 1
        fi
        printf 'unset -f %s\n' "$3" >>"$library"
        ;;
    intact) ;;
    esac
    printf '%s\n' "$dir/guard.sh"
}

# stale_copies NAME: guard が呼ぶ lib の関数を 1 つずつ欠かした写しを作り、`関数名 写した script の path` を
# 1 行ずつ出す。拾える関数が無ければ失敗する(テストを空振りさせない)。
# command substitution の中では set -e が効かないので、失敗は return で返す。
stale_copies() {
    local functions function_name script
    functions=$(lib_functions_called "$1")
    if [[ -z "$functions" ]]; then
        printf '%s\n' "stale_copies: $1 が呼ぶ lib の関数が見つからない" >&2
        return 1
    fi
    while IFS= read -r function_name; do
        script=$(copy_guard "$1" stale "$function_name") || return 1
        printf '%s %s\n' "$function_name" "$script"
    done <<<"$functions"
}

# 読めない lib: 無いと source が exit 1、構文エラーだと exit 2(理由なしのブロック)、
# 空だと関数が無いまま exit 127(フェイルオープン)になる。どれも動詞があれば ask。
assert_lib_contract() {
    local index script
    for index in "${!GUARD_NAMES[@]}"; do
        script=$(copy_guard "${GUARD_NAMES[$index]}" "$1")
        run --separate-stderr bash "$script" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
        expect "${GUARD_NAMES[$index]}" "lib $1" "${GUARD_VERB_INPUTS[$index]}" ask
        run --separate-stderr bash "$script" <<<"$(payload "${GUARD_SILENT_INPUTS[$index]}")"
        expect "${GUARD_NAMES[$index]}" "lib $1" "${GUARD_SILENT_INPUTS[$index]}" ''
    done
}

@test "一覧の guard はすべて script が存在する" {
    [[ ${#GUARD_NAMES[@]} -gt 0 ]] || fail "一覧が空"
    local name
    for name in "${GUARD_NAMES[@]}"; do
        [[ -f "$SCRIPTS/executable_$name.sh" ]] || fail "$name の script が無い"
    done
}

@test "lib が無いとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_lib_contract missing
}

@test "lib が空のとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_lib_contract empty
}

@test "lib が構文エラーのとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_lib_contract syntax
}

# デプロイ先で guard だけが新しく lib が古い場合。lib は読めて構文も正しいので、declare -F だけが
# exit 127(フェイルオープン)を塞ぐ。guard が呼ぶ関数を 1 つずつ欠かし、そのときの振る舞いを関数ごとに確かめる。
# 確かめるのは振る舞いなので、未定義の 127 が呼び出し側でたまたま契約どおりの結果になる関数は、declare -F から
# 漏れても red にならない(curl-localhost-guard の `if ! shell_reader_each_segment …` は ask、issue-linkage-guard の
# `issue_linkage_scope_in_scope … || return 0` は無出力になる)。
@test "lib に guard が呼ぶ関数の 1 つが無いとき、動詞を含む入力は ask、含まない入力は無出力" {
    local index name copies function_name script
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        copies=$(stale_copies "$name")
        while read -r function_name script; do
            run --separate-stderr bash "$script" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
            expect "$name" "lib without $function_name" "${GUARD_VERB_INPUTS[$index]}" ask
            run --separate-stderr bash "$script" <<<"$(payload "${GUARD_SILENT_INPUTS[$index]}")"
            expect "$name" "lib without $function_name" "${GUARD_SILENT_INPUTS[$index]}" ''
        done <<<"$copies"
    done
}

# Contrast Pair: lib が無い・空・構文エラー・関数が無いときに ask を確かめるテストが、「常に ask を返す guard」でも
# 通るわけではないことの裏付け。
@test "lib が正常なコピーでは、動詞を含む安全な入力は無出力" {
    local index script
    for index in "${!GUARD_NAMES[@]}"; do
        script=$(copy_guard "${GUARD_NAMES[$index]}" intact)
        run --separate-stderr bash "$script" <<<"$(payload "${GUARD_SAFE_INPUTS[$index]}")"
        expect "${GUARD_NAMES[$index]}" "lib intact" "${GUARD_SAFE_INPUTS[$index]}" ''
        run --separate-stderr bash "$script" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
        expect "${GUARD_NAMES[$index]}" "lib intact" "${GUARD_VERB_INPUTS[$index]}" ''
    done
}

@test "jq が無いとき、動詞を含む入力は ask、含まない入力は無出力" {
    # PATH を空にすると cat まで消えて別の理由で通るので、cat だけを置いた PATH で動かす。
    # interpreter は絶対パスで呼ぶ。payload は jq が見える今のうちに作る。
    local stub="$BATS_TEST_TMPDIR/bin" index name input
    mkdir -p "$stub"
    ln -s "$(command -v cat)" "$stub/cat"
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        input=$(payload "${GUARD_VERB_INPUTS[$index]}")
        run --separate-stderr env PATH="$stub" "$BASH" "$SCRIPTS/executable_$name.sh" <<<"$input"
        expect "$name" "no jq" "${GUARD_VERB_INPUTS[$index]}" ask
        input=$(payload "${GUARD_SILENT_INPUTS[$index]}")
        run --separate-stderr env PATH="$stub" "$BASH" "$SCRIPTS/executable_$name.sh" <<<"$input"
        expect "$name" "no jq" "${GUARD_SILENT_INPUTS[$index]}" ''
    done
}

@test "stdin が JSON でないとき、動詞を含む入力は ask、含まない入力は無出力" {
    local index name
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <<<"not json: ${GUARD_VERB_INPUTS[$index]}"
        expect "$name" "not json" "${GUARD_VERB_INPUTS[$index]}" ask
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <<<"not json: ${GUARD_SILENT_INPUTS[$index]}"
        expect "$name" "not json" "${GUARD_SILENT_INPUTS[$index]}" ''
    done
}

# ログを開けないことが判定を消さない(`exec 2>>` が開けずにシェルごと無出力で終わる経路を塞いでいるか)。
@test "HOME に書き込めないとき、判定は変わらず、動詞を含む入力も含まない入力も無出力" {
    [[ $EUID -eq 0 ]] && skip "root はディレクトリの mode を無視する"
    export HOME="$BATS_TEST_TMPDIR/readonly-home"
    mkdir -p "$HOME"
    chmod 500 "$HOME"
    local index name
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${GUARD_DECISION_INPUTS[$index]}")"
        expect "$name" "readonly HOME" "${GUARD_DECISION_INPUTS[$index]}" "${GUARD_EXPECTED_DECISIONS[$index]}"
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
        expect "$name" "readonly HOME" "${GUARD_VERB_INPUTS[$index]}" ''
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${GUARD_SILENT_INPUTS[$index]}")"
        expect "$name" "readonly HOME" "${GUARD_SILENT_INPUTS[$index]}" ''
    done
}

@test "HOME が未設定のとき、判定は変わらず、動詞を含む入力も含まない入力も無出力" {
    local index name
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        run --separate-stderr env -u HOME bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${GUARD_DECISION_INPUTS[$index]}")"
        expect "$name" "no HOME" "${GUARD_DECISION_INPUTS[$index]}" "${GUARD_EXPECTED_DECISIONS[$index]}"
        run --separate-stderr env -u HOME bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
        expect "$name" "no HOME" "${GUARD_VERB_INPUTS[$index]}" ''
        run --separate-stderr env -u HOME bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${GUARD_SILENT_INPUTS[$index]}")"
        expect "$name" "no HOME" "${GUARD_SILENT_INPUTS[$index]}" ''
    done
}

# --- フェイルオープンの guard ---

@test "フェイルオープンの一覧の guard はすべて script が存在する" {
    [[ ${#FAIL_OPEN_NAMES[@]} -gt 0 ]] || fail "一覧が空"
    local name
    for name in "${FAIL_OPEN_NAMES[@]}"; do
        [[ -f "$SCRIPTS/executable_$name.sh" ]] || fail "$name の script が無い"
    done
}

# Contrast Pair: lib が無い・空・構文エラー・関数が無いとき、jq が無いとき、stdin が JSON でないときに無出力を
# 確かめるテストが、常に無出力の guard でも通るわけではないことの裏付け。
@test "フェイルオープンの guard は、lib が正常なコピーでは判定を返す" {
    local index script
    for index in "${!FAIL_OPEN_NAMES[@]}"; do
        script=$(copy_guard "${FAIL_OPEN_NAMES[$index]}" intact)
        run --separate-stderr bash "$script" <<<"$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")"
        expect "${FAIL_OPEN_NAMES[$index]}" "lib intact" "${FAIL_OPEN_DECISION_INPUTS[$index]}" "${FAIL_OPEN_EXPECTED_DECISIONS[$index]}"
    done
}

@test "フェイルオープンの guard は、lib が無い・空・構文エラーのとき無出力" {
    local index script kind
    for kind in missing empty syntax; do
        for index in "${!FAIL_OPEN_NAMES[@]}"; do
            script=$(copy_guard "${FAIL_OPEN_NAMES[$index]}" "$kind")
            run --separate-stderr bash "$script" <<<"$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")"
            expect "${FAIL_OPEN_NAMES[$index]}" "lib $kind" "${FAIL_OPEN_DECISION_INPUTS[$index]}" ''
        done
    done
}

@test "フェイルオープンの guard は、lib に guard が呼ぶ関数の 1 つが無いとき無出力" {
    local index name copies function_name script
    for index in "${!FAIL_OPEN_NAMES[@]}"; do
        name=${FAIL_OPEN_NAMES[$index]}
        copies=$(stale_copies "$name")
        while read -r function_name script; do
            run --separate-stderr bash "$script" <<<"$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")"
            expect "$name" "lib without $function_name" "${FAIL_OPEN_DECISION_INPUTS[$index]}" ''
        done <<<"$copies"
    done
}

@test "フェイルオープンの guard は、jq が無いとき・stdin が JSON でないとき無出力" {
    local stub="$BATS_TEST_TMPDIR/bin" index name input
    mkdir -p "$stub"
    ln -s "$(command -v cat)" "$stub/cat"
    for index in "${!FAIL_OPEN_NAMES[@]}"; do
        name=${FAIL_OPEN_NAMES[$index]}
        input=$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")
        run --separate-stderr env PATH="$stub" "$BASH" "$SCRIPTS/executable_$name.sh" <<<"$input"
        expect "$name" "no jq" "${FAIL_OPEN_DECISION_INPUTS[$index]}" ''
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <<<"not json: ${FAIL_OPEN_DECISION_INPUTS[$index]}"
        expect "$name" "not json" "${FAIL_OPEN_DECISION_INPUTS[$index]}" ''
    done
}

@test "フェイルオープンの guard は、HOME に書き込めない・未設定でも判定が変わらない" {
    [[ $EUID -eq 0 ]] && skip "root はディレクトリの mode を無視する"
    local index name readonly_home="$BATS_TEST_TMPDIR/readonly-home"
    mkdir -p "$readonly_home"
    chmod 500 "$readonly_home"
    for index in "${!FAIL_OPEN_NAMES[@]}"; do
        name=${FAIL_OPEN_NAMES[$index]}
        run --separate-stderr env HOME="$readonly_home" bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")"
        expect "$name" "readonly HOME" "${FAIL_OPEN_DECISION_INPUTS[$index]}" "${FAIL_OPEN_EXPECTED_DECISIONS[$index]}"
        run --separate-stderr env -u HOME bash "$SCRIPTS/executable_$name.sh" <<<"$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")"
        expect "$name" "no HOME" "${FAIL_OPEN_DECISION_INPUTS[$index]}" "${FAIL_OPEN_EXPECTED_DECISIONS[$index]}"
    done
}

# ファイル名で拾わないのは、PostToolUse の secretlint-guard.sh(失敗を通す側に倒す別の契約)が混ざるため。
# command の置き場所は問わず、basename が *-guard.sh なら拾う(scripts 以外に置いた guard も一覧の検査に乗る)。
@test "PreToolUse に配線された *-guard.sh はすべていずれかの一覧にある" {
    run jq -r '[.hooks.PreToolUse[].hooks[] | (.command // "")
        | scan("([A-Za-z0-9._-]+-guard)\\.sh") | .[0]] | unique[]' "$SETTINGS"
    assert_success
    # 抽出が空なら検査が空振りする。今ある 2 本は必ず含まれる
    assert_line git-push-guard
    assert_line curl-localhost-guard
    local wired listed found
    while IFS= read -r wired; do
        found=0
        for listed in "${GUARD_NAMES[@]}" "${FAIL_OPEN_NAMES[@]}"; do
            [[ "$listed" == "$wired" ]] && found=1
        done
        [[ $found -eq 1 ]] || fail "$wired は PreToolUse に配線されているが契約テストの一覧に無い"
    done <<<"$output"
}
