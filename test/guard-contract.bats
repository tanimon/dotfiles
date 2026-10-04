#!/usr/bin/env bats
# PreToolUse の guard hook が起動時に守る約束の契約テスト。起動時の約束の正本はこのファイル。
#
# ADR 0009 の中核は「読めなければ ask(無出力にも、理由の無い exit 2 にもしない)」。この約束を守る
# 起動部(ログの確保、stdin・jq・.tool_input.command の取り出し、shell-reader の lib の検査)は
# guard ごとに写してあるので、写し同士のずれをここで捕まえる。guard 固有の判定は各 guard の bats にある。
#
# 起動時の失敗と、そのとき見る入力:
#   lib が無い / 空 / 構文エラー、jq が無い、stdin が JSON でない
#     → 動詞を含む入力(VERB_INPUT)は ask、含まない入力(SILENT_INPUT)は無出力
#   HOME に書き込めない / 未設定
#     → 判定を返す入力(DECISION_INPUT)の判定が変わらない、VERB_INPUT と SILENT_INPUT は無出力
#     (ログを開けないだけで guard は読めるので、VERB_INPUT を ask にするのは誤り。DECISION_INPUT の
#     期待値が ask の guard では、常に ask を返す退行を VERB_INPUT の無出力で見分ける)
# lib が必要な関数の一部だけを欠く場合は guard ごとに必要な関数が違うので、空の lib で代表させる。
#
# VERB_INPUT は lib が正常なら無出力になる入力にする。正常でも ask になる入力だと、失敗の扱いが
# 壊れていても ask が出てテストが通ってしまう。SAFE_INPUT が無出力であることを lib が正常な
# コピーで確かめる(Contrast Pair: 常に ask を返す guard はここで落ちる)。
#
# 一覧(guard 関数の呼び出し)は配線の正本ではない。描画した settings.json の PreToolUse に
# 配線された *-guard.sh が一覧にすべてあることを、最後の test が確かめる。

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

# copy_guard NAME LIB_KIND: guard を lib ごと別の場所に写し、写した script の path を出す。
# LIB_KIND は missing / empty / syntax / intact。
copy_guard() {
    local dir="$BATS_TEST_TMPDIR/$1"
    mkdir -p "$dir"
    cp "$SCRIPTS/executable_$1.sh" "$dir/guard.sh"
    [[ $2 == missing ]] || mkdir -p "$dir/lib"
    case $2 in
    missing) ;;
    empty) : >"$dir/lib/shell-reader.bash" ;;
    syntax) printf '%s\n' 'shell_reader_read() {' >"$dir/lib/shell-reader.bash" ;;
    intact) cp "$SCRIPTS/lib/shell-reader.bash" "$dir/lib/" ;;
    esac
    printf '%s\n' "$dir/guard.sh"
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

# Contrast Pair: 上の 3 つが「常に ask を返す guard」でも通らないことの裏付け。
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

# ファイル名で拾わないのは、PostToolUse の secretlint-guard.sh(失敗を通す側に倒す別の契約)が混ざるため。
# command の置き場所は問わず、basename が *-guard.sh なら拾う(scripts 以外に置いた guard も一覧の検査に乗る)。
@test "PreToolUse に配線された *-guard.sh はすべて一覧にある" {
    run jq -r '[.hooks.PreToolUse[].hooks[] | (.command // "")
        | scan("([A-Za-z0-9._-]+-guard)\\.sh") | .[0]] | unique[]' "$SETTINGS"
    assert_success
    # 抽出が空なら検査が空振りする。今ある 2 本は必ず含まれる
    assert_line git-push-guard
    assert_line curl-localhost-guard
    local wired listed found
    while IFS= read -r wired; do
        found=0
        for listed in "${GUARD_NAMES[@]}"; do
            [[ "$listed" == "$wired" ]] && found=1
        done
        [[ $found -eq 1 ]] || fail "$wired は PreToolUse に配線されているが契約テストの一覧に無い"
    done <<<"$output"
}
