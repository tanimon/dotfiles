#!/usr/bin/env bats
# PreToolUse の guard hook が起動時に守る約束の契約テスト。起動時の約束の正本はこのファイル。
#
# ADR 0009 の中核は「読めなければ ask(無出力にも、理由の無い exit 2 にもしない)」。この約束を守る
# 起動部(ログの確保、stdin・jq・.tool_input.command の取り出し、lib の検査)は起動 module
# (dot_claude/scripts/lib/command-guard.bash)にあり、起動 module 自体が読めないときの自前の部分だけを guard ごとに
# 写してある。module の振る舞いと写し同士のずれを、guard ごとの stdin → stdout でここで捕まえる。
# guard 固有の判定は各 guard の bats にある。
#
# 起動時の失敗と、そのとき見る入力:
#   起動 module か lib が無い / 空 / 構文エラー / guard が呼ぶ関数の 1 つが無い(古い lib)、jq が無い、
#   stdin が JSON でない
#     → 動詞を含む入力(VERB_INPUT)は ask(理由は起動 module の共通の固定文)、含まない入力(SILENT_INPUT)は無出力
#   stdin を読めない → ask
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

# 起動の失敗で ask を返すときの理由は起動 module の共通の固定文。判定中の ask の理由は guard ごとに違う。
STARTUP_REASON='フックの部品を読めないため承認が必要です('

# expect_startup_ask GUARD MODE INPUT: 直前の run の結果が、起動の失敗の共通の理由を持つ ask か。
expect_startup_ask() {
    expect "$1" "$2" "$3" ask
    local reason
    reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
    [[ "$reason" == "$1: $STARTUP_REASON"*')' ]] ||
        fail "$1 [$2] '$3': 起動の失敗の共通の理由のはずが: $reason"
}

# lib_functions_called NAME: guard が呼ぶ lib の関数を 1 行に 1 つ出す。lib に `name() {` で定義され、
# guard の script に名前が出る関数を拾う。guard の --require の一覧から独立に選ぶので、呼んでいるのに
# --require に無い関数も拾える(guard のコメントに lib の関数名を書くと、呼んでいなくても拾う)。
lib_functions_called() {
    local function_name
    while IFS= read -r function_name; do
        if grep -qw -- "$function_name" "$SCRIPTS/executable_$1.sh"; then
            printf '%s\n' "$function_name"
        fi
    done < <(sed -nE 's/^([a-z][a-z0-9_]*)\(\).*/\1/p' "$SCRIPTS"/lib/*.bash)
}

# guard_libraries NAME: guard が読む lib のうち、起動 module(command-guard.bash)以外の basename を 1 行に 1 つ出す。
# guard の script に basename が出る lib を拾う。拾える lib が無ければ失敗する(テストを空振りさせない)。
guard_libraries() {
    local library found=0
    for library in "$SCRIPTS"/lib/*.bash; do
        library=${library##*/}
        [[ "$library" == command-guard.bash ]] && continue
        if grep -qF -- "$library" "$SCRIPTS/executable_$1.sh"; then
            printf '%s\n' "$library"
            found=1
        fi
    done
    if [[ $found -eq 0 ]]; then
        printf '%s\n' "guard_libraries: $1 が読む lib が見つからない" >&2
        return 1
    fi
}

# copy_guard NAME KIND [TARGET]: guard を lib ごと別の場所に写し、写した script の path を出す。
# KIND は missing / empty / syntax / stale / intact。
# missing / empty / syntax は lib/ の TARGET(basename)だけを消す・空にする・構文エラーにし、他の lib は正常なまま写す。
# TARGET を command-guard.bash にすると起動 module 自体が壊れ、guard_libraries の lib にすると起動 module は正常なまま
# reader などの lib だけが壊れる。
# stale は TARGET(関数名)を定義する lib の末尾に `unset -f TARGET` を足す(読めて構文も正しいが、その関数だけが無い)。
copy_guard() {
    # 写し先は KIND と TARGET ごとに分ける(stale_copies などは写しを全部作ってから使うので、同じ場所だと上書きし合う)。
    local dir="$BATS_TEST_TMPDIR/$1-$2${3:+-$3}"
    mkdir -p "$dir/lib"
    cp "$SCRIPTS/executable_$1.sh" "$dir/guard.sh"
    cp "$SCRIPTS"/lib/*.bash "$dir/lib/"
    case $2 in
    missing | empty | syntax)
        if [[ ! -f "$dir/lib/$3" ]]; then
            printf '%s\n' "copy_guard: 壊す lib が無い: ${3:-指定なし}" >&2
            return 1
        fi
        ;;
    esac
    case $2 in
    missing) rm "$dir/lib/$3" ;;
    empty) : >"$dir/lib/$3" ;;
    syntax) printf '%s\n' 'broken_function() {' >"$dir/lib/$3" ;;
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
    *)
        printf '%s\n' "copy_guard: 未知の KIND: $2" >&2
        return 1
        ;;
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
# assert_lib_contract KIND: 起動 module は正常なまま、guard が読む lib を 1 つずつ KIND で壊して確かめる。
assert_lib_contract() {
    local index name libraries library script
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        libraries=$(guard_libraries "$name") || fail "$name の lib を拾えない"
        while IFS= read -r library; do
            script=$(copy_guard "$name" "$1" "$library") || fail "$name の写しを作れない"
            run --separate-stderr bash "$script" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
            expect_startup_ask "$name" "$library $1" "${GUARD_VERB_INPUTS[$index]}"
            run --separate-stderr bash "$script" <<<"$(payload "${GUARD_SILENT_INPUTS[$index]}")"
            expect "$name" "$library $1" "${GUARD_SILENT_INPUTS[$index]}" ''
        done <<<"$libraries"
    done
}

@test "一覧の guard はすべて script が存在する" {
    [[ ${#GUARD_NAMES[@]} -gt 0 ]] || fail "一覧が空"
    local name
    for name in "${GUARD_NAMES[@]}"; do
        [[ -f "$SCRIPTS/executable_$name.sh" ]] || fail "$name の script が無い"
    done
}

@test "起動 module は正常で lib が無いとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_lib_contract missing
}

@test "起動 module は正常で lib が空のとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_lib_contract empty
}

@test "起動 module は正常で lib が構文エラーのとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_lib_contract syntax
}

# 起動 module 自体が読めないときは、各 guard に残した自前の部分が固定文の ask を返す。
# assert_module_contract KIND: 起動 module を KIND で壊して確かめる。
assert_module_contract() {
    local index name script
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        script=$(copy_guard "$name" "$1" command-guard.bash) || fail "$name の写しを作れない"
        run --separate-stderr bash "$script" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
        expect_startup_ask "$name" "module $1" "${GUARD_VERB_INPUTS[$index]}"
        run --separate-stderr bash "$script" <<<"$(payload "${GUARD_SILENT_INPUTS[$index]}")"
        expect "$name" "module $1" "${GUARD_SILENT_INPUTS[$index]}" ''
    done
}

@test "起動 module が無いとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_module_contract missing
}

@test "起動 module が空のとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_module_contract empty
}

@test "起動 module が構文エラーのとき、動詞を含む入力は ask、含まない入力は無出力" {
    assert_module_contract syntax
}

# assert_diagnostics_kept NAME INPUT: 動詞を含む INPUT で、壊れた lib の診断がログに、壊れた起動 module の診断が
# フックの stderr に残るか。
assert_diagnostics_kept() {
    local name=$1 input=$2 libraries library script log="$HOME/.claude/logs/$1-errors.log"
    libraries=$(guard_libraries "$name") || fail "$name の lib を拾えない"
    while IFS= read -r library; do
        rm -f "$log"
        script=$(copy_guard "$name" syntax "$library") || fail "$name の写しを作れない"
        run --separate-stderr bash "$script" <<<"$(payload "$input")"
        grep -qF -- "$library" "$log" 2>/dev/null ||
            fail "$name [$library syntax]: ログに診断が無い: $(cat "$log" 2>/dev/null)"
    done <<<"$libraries"
    script=$(copy_guard "$name" syntax command-guard.bash) || fail "$name の写しを作れない"
    run --separate-stderr bash "$script" <<<"$(payload "$input")"
    [[ "$stderr" == *command-guard.bash* ]] || fail "$name [module syntax]: stderr に診断が無い: $stderr"
}

# 壊れた lib の診断(`"$BASH" -n` の構文エラー)は、ログを開けるならログに残る。起動 module 自体の診断は
# ログを開く前に出るので、フックの stderr に出る。
@test "lib が構文エラーのときの診断はログに、起動 module の診断はフックの stderr に残る" {
    local index
    for index in "${!GUARD_NAMES[@]}"; do
        assert_diagnostics_kept "${GUARD_NAMES[$index]}" "${GUARD_VERB_INPUTS[$index]}"
    done
    for index in "${!FAIL_OPEN_NAMES[@]}"; do
        assert_diagnostics_kept "${FAIL_OPEN_NAMES[$index]}" "${FAIL_OPEN_DECISION_INPUTS[$index]}"
    done
}

# デプロイ先で guard だけが新しく lib が古い場合。lib は読めて構文も正しいので、declare -F だけが
# exit 127(フェイルオープン)を塞ぐ。guard が呼ぶ関数(起動 module の関数を含む)を 1 つずつ欠かし、そのときの
# 振る舞いを関数ごとに確かめる。理由まで共通の固定文であることを見るので、guard が呼ぶのに --require に無い関数は、
# 未定義の 127 が呼び出し側でたまたま ask になっても red になる。
@test "lib に guard が呼ぶ関数の 1 つが無いとき、動詞を含む入力は ask、含まない入力は無出力" {
    local index name copies function_name script
    for index in "${!GUARD_NAMES[@]}"; do
        name=${GUARD_NAMES[$index]}
        copies=$(stale_copies "$name")
        while read -r function_name script; do
            run --separate-stderr bash "$script" <<<"$(payload "${GUARD_VERB_INPUTS[$index]}")"
            expect_startup_ask "$name" "lib without $function_name" "${GUARD_VERB_INPUTS[$index]}"
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
        expect_startup_ask "$name" "no jq" "${GUARD_VERB_INPUTS[$index]}"
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
        expect_startup_ask "$name" "not json" "${GUARD_VERB_INPUTS[$index]}"
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <<<"not json: ${GUARD_SILENT_INPUTS[$index]}"
        expect "$name" "not json" "${GUARD_SILENT_INPUTS[$index]}" ''
    done
}

# stdin の読み取りの失敗は空の入力と区別する(空なら動詞が無いので無出力になる)。ディレクトリを stdin にすると cat が失敗する。
@test "stdin を読めないとき、ask" {
    local name
    for name in "${GUARD_NAMES[@]}"; do
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <"$BATS_TEST_TMPDIR"
        expect_startup_ask "$name" "stdin unreadable" '(ディレクトリ)'
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

@test "フェイルオープンの guard は、起動 module は正常で lib が無い・空・構文エラーのとき無出力" {
    local index name script kind libraries library
    for index in "${!FAIL_OPEN_NAMES[@]}"; do
        name=${FAIL_OPEN_NAMES[$index]}
        libraries=$(guard_libraries "$name") || fail "$name の lib を拾えない"
        for kind in missing empty syntax; do
            while IFS= read -r library; do
                script=$(copy_guard "$name" "$kind" "$library") || fail "$name の写しを作れない"
                run --separate-stderr bash "$script" <<<"$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")"
                expect "$name" "$library $kind" "${FAIL_OPEN_DECISION_INPUTS[$index]}" ''
            done <<<"$libraries"
        done
    done
}

@test "フェイルオープンの guard は、起動 module が無い・空・構文エラーのとき無出力" {
    local index name script kind
    for index in "${!FAIL_OPEN_NAMES[@]}"; do
        name=${FAIL_OPEN_NAMES[$index]}
        for kind in missing empty syntax; do
            script=$(copy_guard "$name" "$kind" command-guard.bash) || fail "$name の写しを作れない"
            run --separate-stderr bash "$script" <<<"$(payload "${FAIL_OPEN_DECISION_INPUTS[$index]}")"
            expect "$name" "module $kind" "${FAIL_OPEN_DECISION_INPUTS[$index]}" ''
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

@test "フェイルオープンの guard は、stdin を読めないとき無出力" {
    local name
    for name in "${FAIL_OPEN_NAMES[@]}"; do
        run --separate-stderr bash "$SCRIPTS/executable_$name.sh" <"$BATS_TEST_TMPDIR"
        expect "$name" "stdin unreadable" '(ディレクトリ)' ''
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
