#!/usr/bin/env bash
# ルールと指示のファイルが、ファイルごとのサイズ上限を超えていたら失敗する(ADR 0011 の肥大の歯止め)。
# 上限の値とその根拠は scripts/instruction-size-limits.txt にある。
#
# 使い方: リポジトリのルートで check-instruction-size.sh を実行する。
# 判定の対象は INSTRUCTION_PATHSPECS に一致する、作業ツリーにあるファイル(git に追加していない
# 新しいファイルも含む。.gitignore で無視されるものは含まない)。
#
# 終了コード: 0 = すべて上限内、1 = 上限を超えたファイルがある、2 = 上限の一覧を読めない。
set -euo pipefail

LIMITS_FILE='scripts/instruction-size-limits.txt'

# エージェントが指示として読み込むファイル。harness/modules/ は生成物の CLAUDE.md / AGENTS.md
# を通して縛られるので、ここには入れない(入れると同じ中身に上限を二重に登録することになる)。
INSTRUCTION_PATHSPECS=(
    ':(glob)**/CLAUDE.md'
    ':(glob)**/AGENTS.md'
    ':(glob).claude/rules/**/*.md'
    ':(glob)dot_claude/rules/**/*.md'
    ':(glob).cursor/rules/*.mdc'
    'dot_claude/CLAUDE.md.tmpl'
    'dot_codex/AGENTS.md.tmpl'
    '.chezmoitemplates/agent-instructions-common'
)

if [[ ! -f $LIMITS_FILE ]]; then
    echo "instruction-size: 上限の一覧が無い: $LIMITS_FILE" >&2
    exit 2
fi

# プロセス置換に直接つなぐと git の失敗が set -e に拾われないので、先に代入する
listed=$(git ls-files --cached --others --exclude-standard -- "${INSTRUCTION_PATHSPECS[@]}") || {
    echo "instruction-size: git ls-files に失敗した" >&2
    exit 2
}
targets=()
while IFS= read -r file; do
    [[ -n $file && -f $file ]] && targets+=("$file")
done < <(sort -u <<<"$listed")

is_target() {
    local target
    for target in ${targets[@]+"${targets[@]}"}; do
        [[ $target == "$1" ]] && return 0
    done
    return 1
}

is_overridden() {
    local overridden
    for overridden in ${override_paths[@]+"${override_paths[@]}"}; do
        [[ $overridden == "$1" ]] && return 0
    done
    return 1
}

default_lines=''
default_bytes=''
override_paths=()
override_lines=()
override_bytes=()
while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    read -r path max_lines max_bytes extra <<<"$line"
    if [[ -n ${extra:-} || ! ${max_lines:-} =~ ^[0-9]+$ || ! ${max_bytes:-} =~ ^[0-9]+$ ]]; then
        echo "instruction-size: $LIMITS_FILE の行を読めない(<パス> <行数> <バイト数> の形にする): $line" >&2
        exit 2
    fi
    # 重複を後勝ちにすると、末尾に緩い行を足すだけで上限を上げられる
    if [[ $path == '*' && -n $default_lines ]] || is_overridden "$path"; then
        echo "instruction-size: $LIMITS_FILE に同じパスの行が複数ある: $path" >&2
        exit 2
    fi
    if [[ $path == '*' ]]; then
        default_lines=$max_lines
        default_bytes=$max_bytes
    elif is_target "$path"; then
        override_paths+=("$path")
        override_lines+=("$max_lines")
        override_bytes+=("$max_bytes")
    else
        # 消えたファイルの上限が残っていると、同じ名前で作り直したファイルが既定値を超えて通る
        echo "instruction-size: $LIMITS_FILE のパスが判定の対象のファイルとして存在しない: $path" >&2
        exit 2
    fi
done <"$LIMITS_FILE"

if [[ -z $default_lines ]]; then
    echo "instruction-size: $LIMITS_FILE に既定値の行(* <行数> <バイト数>)が無い" >&2
    exit 2
fi

status=0
for file in ${targets[@]+"${targets[@]}"}; do
    limit_lines=$default_lines
    limit_bytes=$default_bytes
    for i in ${override_paths[@]+"${!override_paths[@]}"}; do
        if [[ ${override_paths[$i]} == "$file" ]]; then
            limit_lines=${override_lines[$i]}
            limit_bytes=${override_bytes[$i]}
        fi
    done
    # wc -l は末尾に改行の無い最終行を数えない
    actual_lines=$(awk 'END { print NR }' "$file")
    # BSD の wc -c は数値の前に空白を付ける
    actual_bytes=$(($(wc -c <"$file")))
    if ((actual_lines > limit_lines)); then
        echo "$file: $actual_lines 行(上限 ${limit_lines}、+$((actual_lines - limit_lines)) 行)"
        status=1
    fi
    if ((actual_bytes > limit_bytes)); then
        echo "$file: $actual_bytes バイト(上限 ${limit_bytes}、+$((actual_bytes - limit_bytes)) バイト)"
        status=1
    fi
done

if ((status != 0)); then
    echo "instruction-size: 上限を超えたファイルがある。上限と根拠は $LIMITS_FILE" >&2
fi
exit "$status"
