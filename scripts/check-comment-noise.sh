#!/usr/bin/env bash
# コードコメントと指示ファイル(CLAUDE.md・ルール・SKILL.md・harness/modules/ の Content Module)のうち、
# 機械的に判定できる種類のノイズを検出する。
# 規約の正本はルールファイル(RULE_FILE)で、ここには判定だけを置く。
set -euo pipefail
# トークン分割で glob 展開させない
set -f
# 判定をロケールに依存させない(マルチバイト文字はバイト列として扱う)
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST_FILE="${COMMENT_NOISE_ALLOWLIST:-${SCRIPT_DIR}/comment-noise-allowlist.txt}"
RULE_FILE="dot_claude/rules/common/code-comments.md"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PLAN_STEP_RE='(^|[^A-Za-z])(Task|Step) [0-9]+'
# 番号と動詞の間は 24 バイトまで(LC_ALL=C なので日本語は 1 文字 3 バイト)
ISSUE_ORIGIN_JA_RE='#[0-9]+[^#]{0,24}(で発覚|で追加|で導入|で修正|で判明|で実装|で撤去|で廃止)|経緯は ?#[0-9]+'
ISSUE_ORIGIN_EN_RE='(added|introduced|found|fixed) in #[0-9]+'
# 前の版と比べる書き方。今の事実だけを読む読み手には、比べる相手が無い
HISTORY_RE='初版|旧版|以前は|当初は|かつては'
# 指示ファイルの中の日付だけの語(「2026-09-24 に撤去した」「(2026-10-09 に実測)」)。ファイル名の一部の日付
# (specs/2026-07-25-….md)は前後が / や - に続くので当たらない
DATED_EVENT_RE='(^|[^-/0-9A-Za-z_.])20[0-9]{2}-[0-9]{2}-[0-9]{2}($|[^-0-9A-Za-z_])'

# 指示ファイル以外の Markdown(拡張子が .md でないテンプレートと生成物を含む)・docs は経緯の記録が
# 正当な場合が多く、JSON はコメントを持たない。指示ファイルは is_instruction_file で先に振り分ける
is_excluded() {
    case $1 in
    *.md | *.md.tmpl | *.mdc | .chezmoitemplates/agent-instructions-common | docs/* | *.json | pnpm-lock.yaml) return 0 ;;
    esac
    return 1
}

# 許可リストの、コメント行と空行を除いた行を出す。ファイルが無ければ何も出さない
read_allowlist() {
    local line
    [[ -f $ALLOWLIST_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*# ]] && continue
        [[ -z ${line//[[:space:]]/} ]] && continue
        printf '%s\n' "$line"
    done <"$ALLOWLIST_FILE"
}
ALLOW_ENTRIES="$(read_allowlist)"

# =~ の終了コード 2(不正な正規表現)を返す。0 と 1 はどちらも 0 にする
regex_status() {
    local regex=$1 status=0
    # shellcheck disable=SC2319
    [[ '' =~ $regex ]] || status=$?
    ((status == 2)) && return 2
    return 0
}

# 不正な正規表現は、そのエントリに一致する違反が出る前に止める
if [[ -n $ALLOW_ENTRIES ]]; then
    while IFS= read -r entry; do
        if ! regex_status "${entry#*:}"; then
            printf 'error: invalid regex in %s: %s\n' "$ALLOWLIST_FILE" "$entry" >&2
            exit 2
        fi
    done <<<"$ALLOW_ENTRIES"
fi

# 許可リストの各行は <path-suffix or *>:<regex>
is_allowed() {
    local file=$1 text=$2 entry suffix regex
    [[ -n $ALLOW_ENTRIES ]] || return 1
    while IFS= read -r entry; do
        suffix=${entry%%:*}
        regex=${entry#*:}
        [[ $suffix == '*' || $file == *"$suffix" ]] || continue
        [[ $text =~ $regex ]] && return 0
    done <<<"$ALLOW_ENTRIES"
    return 1
}

# git 管理下のトップレベルのディレクトリ。先頭の要素がこれと一致するトークンだけを
# リポジトリ内のパスとみなす(~/ で始まる配置先のパスや、ファイルからの相対パスを避ける)
TOP_DIRS="$(git ls-files | grep / | cut -d/ -f1 | sort -u || true)"

is_top_dir() {
    case $'\n'"$TOP_DIRS"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

# 指示ファイル: 共通の範囲(scripts/instruction-pathspecs.bash)に Content Module を足し、harness/project.json の
# Target(生成物)を外す。生成物を読むと、同じ違反を正本の module と二重に出し、直す先を生成物に向けてしまう
# shellcheck source=scripts/instruction-pathspecs.bash
source "${SCRIPT_DIR}/instruction-pathspecs.bash"
GENERATED_TARGETS=""
if [[ -f harness/project.json ]]; then
    GENERATED_TARGETS="$(jq -r '.targets[].path' harness/project.json)"
fi
INSTRUCTION_FILES="$(git ls-files -- "${INSTRUCTION_PATHSPECS[@]}" ':(glob)harness/modules/**/*.md')"

is_instruction_file() {
    case $'\n'"$GENERATED_TARGETS"$'\n' in
    *$'\n'"$1"$'\n'*) return 1 ;;
    esac
    case $'\n'"$INSTRUCTION_FILES"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

violations=0

report() {
    local file=$1 lineno=$2 pattern=$3 text=$4
    is_allowed "$file" "$text" && return 0
    printf '%s:%s: [%s] %s\n' "$file" "$lineno" "$pattern" "$text"
    violations=$((violations + 1))
}

check_paths() {
    local file=$1 lineno=$2 text=$3 tokens token
    # パスに使う文字以外を区切りにする。:行番号・#アンカー・括弧・句読点・CR はここで落ちる。
    # 行ごとに外部コマンドを起動しないよう、パラメータ展開で置き換える
    local separator='[!A-Za-z0-9_./~{}<>*$-]'
    tokens=${text//$separator/ }
    for token in $tokens; do
        while [[ $token == *. ]]; do token=${token%.}; done
        token=${token#./}
        [[ $token == */* ]] || continue
        case $token in *'{'* | *'}'* | *'<'* | *'>'* | *'*'* | *'$'*) continue ;; esac
        is_top_dir "${token%%/*}" || continue
        # 実在は作業ツリーで見るので、未追跡のファイルへの参照はローカルでは通り、
        # そのファイルを commit せずに push すると CI でだけ止まる
        [[ -e $token ]] && continue
        # gitignore されたパス(ローカルにだけ置くファイル)は、無いのが正常。
        # マシンごとのグローバルな除外(core.excludesfile)は読まない。.git/info/exclude は
        # 設定では外せないので読む(そこで除外したパスへの参照も、CI でだけ止まる)
        git -c core.excludesfile=/dev/null check-ignore -q --no-index -- "$token" && continue
        report "$file" "$lineno" missing-path "$text"
    done
}

check_line() {
    local file=$1 lineno=$2 text=$3
    if [[ $text =~ $PLAN_STEP_RE ]]; then
        report "$file" "$lineno" plan-step "$text"
    fi
    if [[ $text =~ $ISSUE_ORIGIN_JA_RE || $text =~ $ISSUE_ORIGIN_EN_RE ]]; then
        report "$file" "$lineno" issue-origin "$text"
    fi
    if [[ $text =~ $HISTORY_RE ]]; then
        report "$file" "$lineno" history "$text"
    fi
    check_paths "$file" "$lineno" "$text"
}

# 指示ファイルは行全体を読む。plan-step と missing-path は見ない(skill の手順は Step N と書くのが正当で、
# リンクは check-md-links が見る)。ルールの frontmatter の date: は台帳(check-rule-ledger)の項目なので見ない
check_instruction_line() {
    local file=$1 lineno=$2 text=$3
    if [[ $text =~ $ISSUE_ORIGIN_JA_RE || $text =~ $ISSUE_ORIGIN_EN_RE ]]; then
        report "$file" "$lineno" issue-origin "$text"
    fi
    if [[ $text =~ $HISTORY_RE ]]; then
        report "$file" "$lineno" history "$text"
    fi
    if [[ $text != date:* && $text =~ $DATED_EVENT_RE ]]; then
        report "$file" "$lineno" dated-event "$text"
    fi
}

while IFS= read -r -d '' file; do
    [[ -f $file ]] || continue
    if is_instruction_file "$file"; then
        while IFS= read -r hit; do
            check_instruction_line "$file" "${hit%%:*}" "${hit#*:}"
        done < <(grep -n '' -- "$file" || true)
        continue
    fi
    is_excluded "$file" && continue
    while IFS= read -r hit; do
        lineno=${hit%%:*}
        text=${hit#*:}
        [[ $lineno == 1 && $text == '#!'* ]] && continue
        check_line "$file" "$lineno" "$text"
    done < <(grep -InE '^[[:space:]]*(#|//)' -- "$file" || true)
done < <(git ls-files -z)

if ((violations > 0)); then
    printf '\n%d 件のコメントと指示ファイルの記述が規約に反しています。経緯は commit・PR・ADR に書き、今の事実だけを残してください。規約: %s\n' "$violations" "$RULE_FILE" >&2
    printf '残すべきものは %s に <path-suffix or *>:<regex> で追加してください。\n' "$ALLOWLIST_FILE" >&2
    exit 1
fi
