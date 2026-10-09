#!/usr/bin/env bash
# ルールと指示のファイルと skill の本文(SKILL.md)が、ファイルごとのサイズ上限を超えていたら失敗する
# (ADR 0011 の肥大の歯止め)。
# 上限の値とその根拠は scripts/instruction-size-limits.txt にある。
#
# 使い方(どれもリポジトリのルートで実行する):
#   check-instruction-size.sh
#       INSTRUCTION_PATHSPECS に一致する、作業ツリーにあるファイル(git に追加していない新しいファイルも
#       含む。.gitignore で無視されるものは含まない)をファイルごとに測る。
#   check-instruction-size.sh --list-rendered
#       一覧の render: の行のテンプレートを 1 行 1 件で出す。出した名前はそのまま --rendered に渡せる。
#   check-instruction-size.sh --rendered <名前> <ファイル>
#       <ファイル>(<名前> のテンプレートを描画した出力)を、その render: の行の上限で測る。
#       描画はこのスクリプトでは行わない(test/rendered-instruction-size.bats が受け持つ)。
# どの使い方でも一覧全体を読み、読めない行があれば exit 2 にする。
#
# 終了コード: 0 = すべて上限内、1 = 上限を超えたファイルがある、2 = 上限の一覧か引数を読めない。
set -euo pipefail

mode=check
case ${1:-} in
'') ;;
--list-rendered)
    (($# == 1)) || {
        echo "instruction-size: --list-rendered は引数を取らない" >&2
        exit 2
    }
    mode=list-rendered
    ;;
--rendered)
    (($# == 3)) || {
        echo "instruction-size: 使い方: --rendered <名前> <ファイル>" >&2
        exit 2
    }
    mode=rendered
    rendered_name=$2
    rendered_file=$3
    ;;
*)
    echo "instruction-size: 知らない引数: $1" >&2
    exit 2
    ;;
esac

LIMITS_FILE='scripts/instruction-size-limits.txt'

# エージェントが指示として読み込むファイルと skill の本文。harness/modules/ は生成物の CLAUDE.md / AGENTS.md
# を通して縛られるので、ここには入れない(入れると同じ中身に上限を二重に登録することになる)。
# skill の補助ファイル(references/ など)は必要なときにしか読み込まれないので入れない。
INSTRUCTION_PATHSPECS=(
    ':(glob)**/CLAUDE.md'
    ':(glob)**/AGENTS.md'
    ':(glob).claude/rules/**/*.md'
    ':(glob)dot_claude/rules/**/*.md'
    ':(glob).cursor/rules/*.mdc'
    'dot_claude/CLAUDE.md.tmpl'
    'dot_codex/AGENTS.md.tmpl'
    '.chezmoitemplates/agent-instructions-common'
    ':(glob)**/SKILL.md'
)

is_skill() {
    [[ $1 == SKILL.md || $1 == */SKILL.md ]]
}

if [[ ! -f $LIMITS_FILE ]]; then
    echo "instruction-size: 上限の一覧が無い: $LIMITS_FILE" >&2
    exit 2
fi

is_target() {
    local target
    for target in ${targets[@]+"${targets[@]}"}; do
        [[ $target == "$1" ]] && return 0
    done
    return 1
}

# プロセス置換に直接つなぐと git の失敗が set -e に拾われないので、先に一時ファイルに書く。
# 改行区切りで読むと core.quotePath(既定 true)が非 ASCII のパスを "\346..." の形に引用し、
# -f が偽になってそのファイルが黙って判定から外れる。-z の出力は引用されない。
listed_file=$(mktemp)
trap 'rm -f "$listed_file"' EXIT
git ls-files -z --cached --others --exclude-standard -- "${INSTRUCTION_PATHSPECS[@]}" >"$listed_file" || {
    echo "instruction-size: git ls-files に失敗した" >&2
    exit 2
}
targets=()
while IFS= read -r -d '' file; do
    # --cached と --others は重ならないので重複は出ない
    [[ -n $file && -f $file ]] && targets+=("$file")
done <"$listed_file"

is_overridden() {
    local overridden
    for overridden in ${override_paths[@]+"${override_paths[@]}"}; do
        [[ $overridden == "$1" ]] && return 0
    done
    return 1
}

# report LABEL FILE MAX_LINES MAX_BYTES: FILE が上限を超えていたら表示して status を 1 にする。
# MAX_LINES が - なら行数は見ない。終了コードで返さないのは、呼び出し側が `report … || status=1` と
# 書くと関数の中で set -e が効かなくなり、awk や wc の失敗が黙って「上限内」になるため
report() {
    local actual_lines actual_bytes
    # wc -l は末尾に改行の無い最終行を数えない。awk にはリダイレクトで渡す: オペランドで渡すと
    # x=y/CLAUDE.md のような名前が変数代入と読まれ、ファイルの代わりに stdin を数える
    actual_lines=$(awk 'END { print NR }' <"$2")
    # BSD の wc -c は数値の前に空白を付ける
    actual_bytes=$(wc -c <"$2")
    actual_bytes=$((actual_bytes))
    if [[ $3 != '-' ]] && ((actual_lines > $3)); then
        echo "$1: $actual_lines 行(上限 ${3}、+$((actual_lines - $3)) 行)"
        status=1
    fi
    if ((actual_bytes > $4)); then
        echo "$1: $actual_bytes バイト(上限 ${4}、+$((actual_bytes - $4)) バイト)"
        status=1
    fi
}

SKIP_LINE_PATTERN='^[[:space:]]*(#|$)'
RENDER_PREFIX='render:'
SKILL_DEFAULT='skill:*'
default_lines=''
default_bytes=''
skill_default_lines=''
skill_default_bytes=''
override_paths=()
override_lines=()
override_bytes=()
# render: の行。テンプレートの名前は render: を外したもの。既定値には落とさない(行で明示する)
rendered_templates=()
rendered_lines=()
rendered_bytes=()
while IFS= read -r line || [[ -n $line ]]; do
    # 字下げしたコメント行と空白だけの行も読み飛ばす
    [[ $line =~ $SKIP_LINE_PATTERN ]] && continue
    read -r path max_lines max_bytes extra <<<"$line"
    # 行数の - は render: の行にだけ許す。Codex が切り捨てるのはバイト数だけで、合成後の AGENTS.md の
    # 行数には既定値の根拠(CLAUDE.md の目安)が当てはまらない
    lines_pattern='^[0-9]+$'
    [[ $path == "$RENDER_PREFIX"* ]] && lines_pattern='^([0-9]+|-)$'
    if [[ -n ${extra:-} || ! ${max_lines:-} =~ $lines_pattern || ! ${max_bytes:-} =~ ^[0-9]+$ ]]; then
        echo "instruction-size: $LIMITS_FILE の行を読めない(<パス> <行数> <バイト数>、skill:* <行数> <バイト数>、render:<テンプレート> <行数か -> <バイト数> のどれかの形にする): $line" >&2
        exit 2
    fi
    # 重複を後勝ちにすると、末尾に緩い行を足すだけで上限を上げられる
    if [[ $path == '*' && -n $default_lines ]] || [[ $path == "$SKILL_DEFAULT" && -n $skill_default_lines ]] ||
        is_overridden "$path"; then
        echo "instruction-size: $LIMITS_FILE に同じパスの行が複数ある: $path" >&2
        exit 2
    fi
    if [[ $path == '*' ]]; then
        default_lines=$max_lines
        default_bytes=$max_bytes
    elif [[ $path == "$SKILL_DEFAULT" ]]; then
        skill_default_lines=$max_lines
        skill_default_bytes=$max_bytes
    elif [[ $path == "$RENDER_PREFIX"* ]]; then
        # テンプレートが消えた行が残っていると、測るつもりの出力が黙って測られなくなる
        if [[ ! -f ${path#"$RENDER_PREFIX"} ]]; then
            echo "instruction-size: $LIMITS_FILE の render: の行のテンプレートが存在しない: $path" >&2
            exit 2
        fi
        # 重複の検出は render: を付けたままのパスで行う(同じテンプレートの通常の行とは別物)
        override_paths+=("$path")
        override_lines+=("$max_lines")
        override_bytes+=("$max_bytes")
        rendered_templates+=("${path#"$RENDER_PREFIX"}")
        rendered_lines+=("$max_lines")
        rendered_bytes+=("$max_bytes")
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

# skill の本文に * の既定値を当てると、根拠(起動時に読み込まれるファイル向けの値)の違う上限で測ることになる
if [[ -z $skill_default_lines ]]; then
    for file in ${targets[@]+"${targets[@]}"}; do
        if is_skill "$file"; then
            echo "instruction-size: $LIMITS_FILE に skill の既定値の行(skill:* <行数> <バイト数>)が無い: $file" >&2
            exit 2
        fi
    done
fi

if [[ $mode == list-rendered ]]; then
    for template in ${rendered_templates[@]+"${rendered_templates[@]}"}; do
        printf '%s\n' "$template"
    done
    exit 0
fi

status=0
if [[ $mode == rendered ]]; then
    found=''
    for i in ${rendered_templates[@]+"${!rendered_templates[@]}"}; do
        [[ ${rendered_templates[$i]} == "$rendered_name" ]] && found=$i
    done
    if [[ -z $found ]]; then
        # 既定値で測ると、一覧から行を消すだけで上限が既定値に戻る
        echo "instruction-size: $LIMITS_FILE に render:${rendered_name} の行が無い" >&2
        exit 2
    fi
    if [[ ! -f $rendered_file ]]; then
        echo "instruction-size: 測るファイルが無い: $rendered_file" >&2
        exit 2
    fi
    report "${RENDER_PREFIX}${rendered_name}" "$rendered_file" "${rendered_lines[$found]}" "${rendered_bytes[$found]}"
else
    for file in ${targets[@]+"${targets[@]}"}; do
        limit_lines=$default_lines
        limit_bytes=$default_bytes
        if is_skill "$file"; then
            limit_lines=$skill_default_lines
            limit_bytes=$skill_default_bytes
        fi
        for i in ${override_paths[@]+"${!override_paths[@]}"}; do
            if [[ ${override_paths[$i]} == "$file" ]]; then
                limit_lines=${override_lines[$i]}
                limit_bytes=${override_bytes[$i]}
            fi
        done
        report "$file" "$file" "$limit_lines" "$limit_bytes"
    done
fi

if ((status != 0)); then
    echo "instruction-size: 上限を超えたファイルがある。上限と根拠は $LIMITS_FILE" >&2
fi
exit "$status"
