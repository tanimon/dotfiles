#!/usr/bin/env bash
# ルールと指示のファイルと skill の本文(SKILL.md)が、ファイルごとのサイズ上限を超えていたら失敗する
# (ADR 0011 の肥大の歯止め)。
# 上限の値とその根拠は scripts/instruction-size-limits.txt にある。
#
# 使い方(どれもリポジトリのルートで実行する):
#   check-instruction-size.sh
#       判定の対象のファイルのうち、ソースのまま測るものをファイルごとに測る(配置先が判定の対象のテンプレートは
#       INSTRUCTION_PATHSPECS に一致するものだけをソースのまま測る)。判定の対象は、作業ツリーにある
#       ファイル(git に追加していない新しいファイルも含む。.gitignore で無視されるものは含まない)のうち、
#       INSTRUCTION_PATHSPECS に一致するものと、chezmoi が配置する先のパスがその形に一致するもの
#       (chezmoi_destination。private_SKILL.md、exact_rules/ など)。
#   check-instruction-size.sh --list-rendered
#       一覧の render: の行のテンプレートを 1 行 1 件で出す。出した名前はそのまま --rendered に渡せる。
#   check-instruction-size.sh --list-templates
#       配置先が判定の対象のテンプレート(SKILL.md.tmpl など)のうち、render: の行が無いものを 1 行 1 件で出す。
#       出した名前はそのまま --rendered に渡せる。
#   check-instruction-size.sh --rendered <名前> <ファイル>
#       <ファイル>(<名前> のテンプレートを描画した出力)を測る。render: の行があればその行の上限で、
#       --list-templates のテンプレートなら個別の上限の行か配置先の種類の既定値で測る。
#       描画はこのスクリプトでは行わない(test/rendered-instruction-size.bats が受け持つ)。
# どの使い方でも一覧全体を読み、読めない行があるか、SKILL.md があるのに skill:* の行が無いか、配置先が判定の対象か
# .claude/rules の祖先か配下なのに中身をソースから測れない source(modify_・symlink_・encrypted_)があれば exit 2 にする。
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
--list-templates)
    (($# == 1)) || {
        echo "instruction-size: --list-templates は引数を取らない" >&2
        exit 2
    }
    mode=list-templates
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

# エージェントが指示として読み込むファイルと skill の本文(source のパスで照合する。配置先のパスでの照合は
# is_instruction_destination)。harness/modules/ は生成物の CLAUDE.md / AGENTS.md
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

# 引数は配置先のパス(chezmoi に配置されないファイルは source のパス)。source のファイル名で決めると
# private_SKILL.md のような名前で skill:* の上限を逃れられる
is_skill() {
    [[ $1 == SKILL.md || $1 == */SKILL.md ]]
}

# is_instruction_destination DEST: chezmoi の配置先のパス DEST(~/ からの相対)が判定の対象か。
# INSTRUCTION_PATHSPECS の各パターンの配置先の形。source の名前の付け方(属性の接頭辞・.tmpl・.literal)を
# 変えても配置先は変わらないので、判定から外れない
is_instruction_destination() {
    case ${1##*/} in
    CLAUDE.md | AGENTS.md | SKILL.md) return 0 ;;
    esac
    [[ $1 == .claude/rules/*.md ]] && return 0
    [[ $1 == .cursor/rules/*.mdc && $1 != .cursor/rules/*/* ]]
}

# may_hold_rules DEST: 配置先のパス DEST が .claude/rules の祖先か自身か配下か。そこに置いた symlink が
# ディレクトリを指すと、リンク先の .md が名前を問わず rules として読み込まれる(Claude Code は .claude/rules/ の
# 下の symlink を、ファイルでもディレクトリでも辿る)。リンク先を . で始まるディレクトリのような判定の対象の形に
# 一致しない場所に置けば、配置先が .md で終わらなくても上限を逃れられる
may_hold_rules() {
    [[ .claude/rules/ == "$1"/* || $1 == .claude/rules/* ]]
}

# chezmoi_destination SOURCE: リポジトリのルートを chezmoi の source とみなし、SOURCE が配置される先のパスを
# destination に、配置される中身の種類を content_kind に入れる。content_kind は file(source の中身がそのまま配置される)、
# template(描画した出力が配置される)、opaque(中身が source から決まらない)、空(何も配置されない)のどれか。
# 名前の対応づけは chezmoi の source state attributes の規則で、接頭辞は決まった順にだけ外す
# (private_encrypted_x は encrypted_x に配置される)。chezmoi は呼ばない: chezmoi target-path は run_ や
# . で始まるパスにも配置先を返し、encrypted_ の拡張子の扱いが設定で変わるので、どのみち自前で種類を判定する。
# .chezmoiignore は評価しない(Guarded Path ではなく profile で結果が変わるので、頼ると判定の対象を外せる)
chezmoi_destination() {
    local rest=$1 component name verbatim='' encrypted='' prefix
    destination=''
    content_kind=''
    while [[ $rest == */* ]]; do
        component=${rest%%/*}
        rest=${rest#*/}
        if [[ -z $verbatim ]]; then
            # . で始まるもの(.chezmoi* を含む)は chezmoi が source として読まない
            [[ $component == .* ]] && return 0
            component=${component#remove_}
            # external_ のディレクトリの中は名前を対応づけずにそのまま配置される
            [[ $component == external_* ]] && verbatim=1
            for prefix in external_ exact_ private_ readonly_; do
                component=${component#"$prefix"}
            done
            case $component in
            dot_*) component=.${component#dot_} ;;
            literal_*) component=${component#literal_} ;;
            esac
        fi
        destination+=$component/
    done
    name=$rest
    if [[ -n $verbatim ]]; then
        destination+=$name
        content_kind='file'
        return 0
    fi
    case $name in
    .* | remove_* | run_*) return 0 ;;
    esac
    content_kind='file'
    # ファイルの種類ごとに付けられる属性の接頭辞(付ける順)
    local prefixes='encrypted_ private_ readonly_ empty_ executable_'
    case $name in
    create_*) name=${name#create_} ;;
    symlink_*)
        name=${name#symlink_}
        content_kind='opaque'
        prefixes=''
        ;;
    modify_*)
        name=${name#modify_}
        content_kind='opaque'
        prefixes='encrypted_ private_ readonly_ executable_'
        ;;
    esac
    [[ $name == encrypted_* && -n $prefixes ]] && encrypted=1
    for prefix in $prefixes; do
        name=${name#"$prefix"}
    done
    case $name in
    dot_*) name=.${name#dot_} ;;
    literal_*) name=${name#literal_} ;;
    esac
    if [[ -n $encrypted ]]; then
        content_kind='opaque'
        # 拡張子は暗号化の設定で決まる。どちらも外しておけば、配置先が判定の対象なのに見逃すことはない
        name=${name%.age}
        name=${name%.asc}
    fi
    case $name in
    *.literal) name=${name%.literal} ;;
    *.tmpl)
        name=${name%.tmpl}
        name=${name%.literal}
        [[ $content_kind == file ]] && content_kind='template'
        ;;
    esac
    destination+=$name
}

if [[ ! -f $LIMITS_FILE ]]; then
    echo "instruction-size: 上限の一覧が無い: $LIMITS_FILE" >&2
    exit 2
fi

is_target() {
    local target
    for target in ${targets[@]+"${targets[@]}"} ${templates[@]+"${templates[@]}"}; do
        [[ $target == "$1" ]] && return 0
    done
    return 1
}

# プロセス置換に直接つなぐと git の失敗が set -e に拾われないので、先に一時ファイルに書く。
# 改行区切りで読むと core.quotePath(既定 true)が非 ASCII のパスを "\346..." の形に引用し、
# -f が偽になってそのファイルが黙って判定から外れる。-z の出力は引用されない。
listed_file=$(mktemp)
pathspec_file=$(mktemp)
trap 'rm -f "$listed_file" "$pathspec_file"' EXIT
if ! git ls-files -z --cached --others --exclude-standard >"$listed_file" ||
    ! git ls-files -z --cached --others --exclude-standard -- "${INSTRUCTION_PATHSPECS[@]}" >"$pathspec_file"; then
    echo "instruction-size: git ls-files に失敗した" >&2
    exit 2
fi
# INSTRUCTION_PATHSPECS に一致する source。. で始まるリポジトリ専用のパスと、テンプレートのソースそのものを
# 測る行(dot_claude/CLAUDE.md.tmpl など)はこれでしか拾えない
pathspec_matched=$'\n'
while IFS= read -r -d '' file; do
    pathspec_matched+=$file$'\n'
done <"$pathspec_file"

# targets はソースをそのまま測るファイル、templates は配置先が判定の対象のテンプレート(描画は
# test/rendered-instruction-size.bats)。*_destinations はそれぞれの配置先のパス(配置されないものは source のパス)で、当てる既定値を決める
targets=()
target_destinations=()
templates=()
template_destinations=()
opaque_found=''
while IFS= read -r -d '' file; do
    # --cached と --others は重ならないので重複は出ない
    [[ -n $file && -f $file ]] || continue
    by_pathspec=''
    [[ $pathspec_matched == *$'\n'"$file"$'\n'* ]] && by_pathspec=1
    chezmoi_destination "$file"
    if [[ $content_kind == opaque ]] && { is_instruction_destination "$destination" || may_hold_rules "$destination"; }; then
        # このスクリプトは読めない入力を exit 2 にする。黙って通すと、名前を変えるだけで上限を逃れられる
        echo "instruction-size: 判定の対象になりうる配置先の中身をソースから測れない: $file($destination に配置される)" >&2
        opaque_found=1
        continue
    fi
    if [[ -n $content_kind ]] && is_instruction_destination "$destination"; then
        if [[ $content_kind == template ]]; then
            templates+=("$file")
            template_destinations+=("$destination")
            # INSTRUCTION_PATHSPECS に一致するテンプレートは、描画した出力に加えてソースもそのまま測る
            [[ -n $by_pathspec ]] || continue
        fi
        targets+=("$file")
        target_destinations+=("$destination")
    elif [[ -n $by_pathspec ]]; then
        targets+=("$file")
        target_destinations+=("$file")
    fi
done <"$listed_file"
[[ -z $opaque_found ]] || exit 2

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
    for destination in ${target_destinations[@]+"${target_destinations[@]}"} ${template_destinations[@]+"${template_destinations[@]}"}; do
        if is_skill "$destination"; then
            echo "instruction-size: $LIMITS_FILE に skill の既定値の行(skill:* <行数> <バイト数>)が無い: $destination" >&2
            exit 2
        fi
    done
fi

# limit_for SOURCE DEST: SOURCE に当てる上限を limit_lines と limit_bytes に入れる。個別の上限の行が優先し、
# 無ければ配置先のパス DEST の種類の既定値
limit_for() {
    limit_lines=$default_lines
    limit_bytes=$default_bytes
    if is_skill "$2"; then
        limit_lines=$skill_default_lines
        limit_bytes=$skill_default_bytes
    fi
    local i
    for i in ${override_paths[@]+"${!override_paths[@]}"}; do
        if [[ ${override_paths[$i]} == "$1" ]]; then
            limit_lines=${override_lines[$i]}
            limit_bytes=${override_bytes[$i]}
        fi
    done
}

# has_render_line TEMPLATE: TEMPLATE に render: の行があるか。あれば描画後の出力はその行だけで測る
# (理由は scripts/instruction-size-limits.txt の render: の行の説明)
has_render_line() {
    local template
    for template in ${rendered_templates[@]+"${rendered_templates[@]}"}; do
        [[ $template == "$1" ]] && return 0
    done
    return 1
}

if [[ $mode == list-rendered ]]; then
    for template in ${rendered_templates[@]+"${rendered_templates[@]}"}; do
        printf '%s\n' "$template"
    done
    exit 0
fi

if [[ $mode == list-templates ]]; then
    for template in ${templates[@]+"${templates[@]}"}; do
        has_render_line "$template" || printf '%s\n' "$template"
    done
    exit 0
fi

status=0
if [[ $mode == rendered ]]; then
    found=''
    for i in ${rendered_templates[@]+"${!rendered_templates[@]}"}; do
        [[ ${rendered_templates[$i]} == "$rendered_name" ]] && found=$i
    done
    template_found=''
    if [[ -z $found ]]; then
        for i in ${templates[@]+"${!templates[@]}"}; do
            [[ ${templates[$i]} == "$rendered_name" ]] && template_found=$i
        done
    fi
    if [[ -z $found && -z $template_found ]]; then
        # 既定値で測ると、一覧から行を消すだけで上限が既定値に戻る。配置先が判定の対象のテンプレートは
        # --list-templates に出るもので、その名前だけを既定値で測る
        echo "instruction-size: $LIMITS_FILE に render:${rendered_name} の行が無く、--list-templates のテンプレートでもない" >&2
        exit 2
    fi
    if [[ ! -f $rendered_file ]]; then
        echo "instruction-size: 測るファイルが無い: $rendered_file" >&2
        exit 2
    fi
    if [[ -n $found ]]; then
        report "${RENDER_PREFIX}${rendered_name}" "$rendered_file" "${rendered_lines[$found]}" "${rendered_bytes[$found]}"
    else
        limit_for "$rendered_name" "${template_destinations[$template_found]}"
        report "$rendered_name" "$rendered_file" "$limit_lines" "$limit_bytes"
    fi
else
    for i in ${targets[@]+"${!targets[@]}"}; do
        limit_for "${targets[$i]}" "${target_destinations[$i]}"
        report "${targets[$i]}" "${targets[$i]}" "$limit_lines" "$limit_bytes"
    done
fi

if ((status != 0)); then
    echo "instruction-size: 上限を超えたファイルがある。上限と根拠は $LIMITS_FILE" >&2
fi
exit "$status"
