#!/usr/bin/env bash
# PreToolUse hook: gate the destructive spellings of `git push`.
#
# `permissions` offers prefix matching only, so `Bash(git push --force:*)` in
# deny fires for `git push --force origin main` but not for
# `git push origin main --force` — the write intent lives in a flag whose
# position is free. That is why `Bash(git push:*)` sat in `ask` and prompted on
# every routine push. This hook replaces that blanket gate: it reads the whole
# command string, so it can find the dangerous flag wherever it sits, and stays
# silent for the everyday push that prompted nobody's attention.
#
# Decision contract (docs: PreToolUse hookSpecificOutput):
#   deny  — force / delete / mirror / prune spellings, at any argument position
#   ask   — the push segment contains something this scan cannot read through,
#           or a `git send-pack` / `git-send-pack` segment (push の plumbing。引数に関係なく ask)
#   (no output) — plain push; falls through to defaultMode: auto's classifier
#
# Fail-closed: anything unreadable that may contain `push` becomes `ask`, never
# silence. `ask` prompts even under defaultMode: auto, so an unparseable payload
# carrying a push cannot slip past.
#
# このフックが見ない残存: alias / シェル関数と `gh api`(tier-model spec)、および
# .claude/rules/git-push-guard.md の「残存(受容)」の各項。
#
# classify_segment とその呼び先は shell_reader_each_segment が名前で間接的に呼ぶ。
# 新しい shellcheck は SC2329、CI の ubuntu に入っている古い版は同じ指摘を SC2317 で出すので両方を抑制する。
# shellcheck disable=SC2317,SC2329
set -euo pipefail

# 起動の自前の部分。起動 module(lib/command-guard.bash)が無い・壊れているときも ask を返すため、各 guard が持つ。
# 手順と理由は module のヘッダ。動詞を含まない入力は module を読まずに終わる。
COMMAND_GUARD_STDIN_FAILED=0
COMMAND_GUARD_STDIN=$(cat) || COMMAND_GUARD_STDIN_FAILED=1
# 動詞は自前の部分の照合と command_guard_start の --verb で共有する(ずれると動詞を含む入力が module に届かない)。
COMMAND_GUARD_VERB='*push*'
# `git send-pack` は push の下位コマンドで `push` を含まないので、動詞をもう 1 つ持つ。
COMMAND_GUARD_VERB_SEND_PACK='*send-pack*'
# JSON は文字を \uXXXX でも書けるので、`\u` を含む入力も module に渡す(module が jq で取り出す COMMAND の照合より狭くしない)。
# shellcheck disable=SC2053 # 動詞は glob として照合する
[[ $COMMAND_GUARD_STDIN_FAILED -eq 1 || "$COMMAND_GUARD_STDIN" == $COMMAND_GUARD_VERB ||
    "$COMMAND_GUARD_STDIN" == $COMMAND_GUARD_VERB_SEND_PACK || "$COMMAND_GUARD_STDIN" == *\\u* ]] || exit 0
command_guard_dir=${BASH_SOURCE[0]%/*}
[[ "$command_guard_dir" != "${BASH_SOURCE[0]}" ]] || command_guard_dir=.
# shellcheck source-path=SCRIPTDIR source=lib/command-guard.bash
if [[ ! -r "$command_guard_dir/lib/command-guard.bash" ]] || ! "$BASH" -n "$command_guard_dir/lib/command-guard.bash" ||
    ! source "$command_guard_dir/lib/command-guard.bash" || ! declare -F command_guard_start command_guard_emit >/dev/null; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"git-push-guard: フックの部品を読めないため承認が必要です(起動 module を読めない)"}}'
    exit 0
fi

command_guard_start --name git-push-guard --verb "$COMMAND_GUARD_VERB" --verb "$COMMAND_GUARD_VERB_SEND_PACK" --on-unreadable ask \
    --lib shell-reader.bash \
    --require 'shell_reader_read shell_reader_each_segment shell_reader_token_has_mark shell_reader_segment_follows shell_reader_command_word shell_reader_text_floor_matches'
# command_guard_start から戻った時点で、COMMAND(.tool_input.command。動詞に一致する)と jq が使える。

ASK_REASON='git-push-guard: この push は引数を読み切れないか、push の下位コマンド(git send-pack)を含むため確認が必要です(変数・コマンド置換・push 関連の -c 上書きなど)。素の push なら無確認で通ります。'

# --- 危険な綴りの語彙 -----------------------------------------------------------------------
# push を壊す綴りの正本。token の判定(classify_from と、そこから呼ぶ述語)と字面の床(DANGER_FLAG_RE)は
# どちらもここから引く。綴りを足すときはここだけを変える。DANGER_FLAG_RE と `-c` の値の 2 つの段階
# (DANGER_CONFIG_BROAD_*_RE / DANGER_CONFIG_NARROW_RE)は手で書かず、起動時にこの表から組み立てる。
# 英字は小文字だけで書く(大文字小文字を区別しない照合は case_insensitive_pattern が作る)。
#
# 長オプション(`--` の後ろ)。git は長オプションの一意な前方一致を受け付ける(`--dele` は `--delete`)ので、
# token の判定も床も前方一致で見る。
DANGER_LONG_OPTIONS=(force force-with-lease force-if-includes delete mirror prune)
# 短オプションの束に含まれると危険な文字(`-f` は --force、`-d` は --delete)。束は数字も含みうる
# (`-4f` は `--ipv4` + `--force`)。
DANGER_SHORT_LETTERS=fd
# refspec の先頭の文字。`+` は強制更新、src が空の `:` はリモート ref の削除。
DANGER_REFSPEC_LEADS='+:'
# `-c` / `--config-env` の値のうち push を壊すもの。git の設定キーは大文字小文字を区別しない。
# `remote.<name>.push` は force の refspec を、`remote.<name>.mirror` は mirror push を運ぶ。
DANGER_REMOTE_SECTION=remote
DANGER_REMOTE_KEYS=(push mirror)
# `include.path` / `includeIf.*.path` は読めないファイルの設定(`remote.origin.mirror=true` を含みうる)を取り込む。
DANGER_INCLUDE_KEY=include
# `-c` と同じ設定を環境変数で運ぶ token の接頭辞(`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` /
# `GIT_CONFIG_PARAMETERS`)。環境変数の名前は大文字小文字を区別する。
DANGER_ENV_PREFIX=GIT_CONFIG

# $1(小文字の英字と英字以外)の英字を `[Xx]` にした、大文字小文字を区別しない POSIX ERE を
# CASE_INSENSITIVE_PATTERN に返す。英字以外は ERE の特殊文字を含まない前提でそのまま写す。fork しないよう、
# 変換は表を引いて行う。
CASE_INSENSITIVE_PATTERN=''
case_insensitive_pattern() {
    local word=$1 lower=abcdefghijklmnopqrstuvwxyz upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ character before index=0
    CASE_INSENSITIVE_PATTERN=''
    while [[ $index -lt ${#word} ]]; do
        character=${word:index:1}
        case "$character" in
        [a-z])
            before=${lower%%"$character"*}
            CASE_INSENSITIVE_PATTERN+="[${upper:${#before}:1}${character}]"
            ;;
        *) CASE_INSENSITIVE_PATTERN+=$character ;;
        esac
        index=$((index + 1))
    done
}

# `-c` / `--config-env` の値(`key=value` か `key`)が push を壊しうるかの 2 つの段階。どちらも ERE で、
# token の判定は config_value_mentions_danger / config_is_dangerous から、字面の床は広い段階だけを使う。
# - 広い段階: 値のどこかに DANGER_REMOTE_KEYS の語があるか、DANGER_INCLUDE_KEY で始まる。コマンドの位置が
#   確定した segment で使う。値の先頭からの一致として 1 つの形(danger_config_broad_shape)に書き、値の 1 文字に
#   当たる `@` だけを置き換えて 2 つ作る(token の判定は値 1 つが対象なので `.`、床は行の中の値なので空白以外)。
# - 狭い段階: `<DANGER_REMOTE_SECTION>.<name>.<DANGER_REMOTE_KEYS の語>`(`=` 以降は任意)か、DANGER_INCLUDE_KEY で
#   始まる。コマンドの位置を確定できない segment で使う(`-c push.autoSetupRemote=true` を巻き込まない)。
danger_remote_keys_re=''
for word in "${DANGER_REMOTE_KEYS[@]}"; do
    case_insensitive_pattern "$word"
    danger_remote_keys_re+=${danger_remote_keys_re:+|}$CASE_INSENSITIVE_PATTERN
done
case_insensitive_pattern "$DANGER_INCLUDE_KEY"
danger_include_re=$CASE_INSENSITIVE_PATTERN
case_insensitive_pattern "$DANGER_REMOTE_SECTION"
danger_remote_section_re=$CASE_INSENSITIVE_PATTERN
danger_config_broad_shape="(@*(${danger_remote_keys_re})|${danger_include_re})"
DANGER_CONFIG_BROAD_TOKEN_RE="^${danger_config_broad_shape//@/.}"
DANGER_CONFIG_BROAD_FLOOR_RE=${danger_config_broad_shape//@/[^[:space:]]}
DANGER_CONFIG_NARROW_RE="^(${danger_remote_section_re}\\..*\\.(${danger_remote_keys_re})(=|\$)|${danger_include_re})"

# 字面の床の危険な綴り。語彙から組み立てる。
# - 長オプション: 各オプションのすべての前方一致を選択肢にする(`--f` から `--force-with-lease` まで)。
# - `-c` / `--config-env` の値: 広い段階(DANGER_CONFIG_BROAD_FLOOR_RE)。床は ask にしかならないので、
#   狭い段階にはしない。
# - `GIT_CONFIG*`: 語頭にあるもの(前置きの代入でも `export` でも)。
danger_long_prefixes=''
for word in "${DANGER_LONG_OPTIONS[@]}"; do
    length=1
    while [[ $length -le ${#word} ]]; do
        case "|$danger_long_prefixes|" in
        *"|${word:0:length}|"*) ;;
        *) danger_long_prefixes+=${danger_long_prefixes:+|}${word:0:length} ;;
        esac
        length=$((length + 1))
    done
done
DANGER_FLAG_RE="(--(${danger_long_prefixes})([^[:alnum:]_-]|\$)"
DANGER_FLAG_RE+="|[[:space:]](-c|--config-env)[[:space:]=]*${DANGER_CONFIG_BROAD_FLOOR_RE}"
DANGER_FLAG_RE+="|[[:space:]]-[[:alnum:]]*[${DANGER_SHORT_LETTERS}][[:alnum:]]*([^[:alnum:]_-]|\$)"
DANGER_FLAG_RE+="|[[:space:]][${DANGER_REFSPEC_LEADS}][^[:space:]]"
DANGER_FLAG_RE+="|(^|[^[:alnum:]_])${DANGER_ENV_PREFIX})"
unset word length danger_long_prefixes danger_remote_keys_re danger_include_re danger_remote_section_re danger_config_broad_shape

# 字面の床の「push の呼び出し」。git-core の dashed binary(`…/git-core/git-push`)と `send-pack` も、
# token の判定と同じく床で見る。
DANGER_TEXT_RE='(^|[^[:alnum:]_-])(git[[:space:]].*push|git-push|git[[:space:]-]+send-pack)'
# 床は 1 行ごとに見る。heredoc の PR 本文では、別々の行にある「git push の手順」と「+12 行」を
# 組み合わせて ask にしないようにする。
# 行の分割と、引用符・backslash・行継続の正規化は lib の shell_reader_text_floor_matches が行う
# (`'git' push …` や `git push … \⏎--force` も同じ行の `git push … --force` として見る)。

# 長すぎる入力では reader が token を作らない(安く読めない)。segment の走査は何もせず、字面の床
# (shell_reader_text_floor_matches)が生のコマンド全体を見る(一致しなければ classifier に任せる。ADR 0009)。
shell_reader_read "$COMMAND"

DANGER_TOKEN=""
NEEDS_ASK=0

# `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_PARAMETERS` などの環境変数は `-c` と同じ
# 設定を運ぶ(`GIT_CONFIG_KEY_0=remote.origin.mirror` + `GIT_CONFIG_VALUE_0=true` で mirror push)。
# 前置きの代入でも前の segment の `export` でも効くので、コマンド全体の token を語頭で見る。
# push の segment ごとにコマンド全体を走査すると segment 数 × token 数の二乗になり、8 KB 近い
# `git push origin main --force;git push;…` が 5 秒を越えてフックの timeout(= 判定なし =
# フェイルオープン)に届いた。そこでここで 1 回だけ数え、classify_from は結果だけを見る。
GIT_CONFIG_IN_COMMAND=0
# 空配列の展開は bash 3.2 の set -u で落ちるので数を先に見る。
if [[ ${#SHELL_READER_TOKENS[@]} -gt 0 ]]; then
    for token in "${SHELL_READER_TOKENS[@]}"; do
        case "$token" in "$DANGER_ENV_PREFIX"*) GIT_CONFIG_IN_COMMAND=1 ;; esac
    done
fi

# 番兵の byte が入力にあると、reader が作る segment の境目を偽造できる(`git push origin main 2>\x01 --force`
# は bash では stderr の redirect 先が `\x01` の force push だが、reader には `--force` だけの segment が
# 別にあるように見える)。この時点でコマンドは `push` を含むので、読み切れないとして ask にする。
# プロセス置換も同じ: `git push origin <(echo) --force` の `)` の後ろは git の引数の続きだが、reader の
# segment では `--force` だけの segment に見える。
# ここで終わらずに segment の走査を続ける。読み切れた別の segment に危険な綴りがあれば deny が勝つ
# (`git push origin main --force; cat <(true)` を ask に格下げしない)。
if [[ $SHELL_READER_SEP_IN_INPUT -eq 1 || $SHELL_READER_PROCESS_SUBSTITUTION -eq 1 ]]; then
    NEEDS_ASK=1
fi

# reader が引用符を外すので、ここで外すのはバッククォートだけ。`` `git push … --force` `` は
# 実行されるので、前後の 1 つを外して読む。token ごとに呼ぶので $(…) で fork しない。
STRIPPED=''
strip_backticks() {
    STRIPPED=${1#\`}
    STRIPPED=${STRIPPED%\`}
}

# $1(`--` 付き、`=` より前)が、語彙の長オプションのどれかの前方一致か。
long_option_is_dangerous() {
    local option
    for option in "${DANGER_LONG_OPTIONS[@]}"; do
        [[ "--$option" == "$1"* ]] && return 0
    done
    return 1
}

# 現在の segment の $1 番目(segment の中の index)の token に、ブレース展開かパス名展開の印があるか。
token_has_expansion_mark() {
    shell_reader_token_has_mark "$1" brace glob
}

# 現在の segment(token_count 個の token)にブレース展開かパス名展開(引用符の外の * ? [)があるか。
# 展開の結果は reader の token に現れない(`{main,--force}` の token は `main,--force`、`-?` は cwd に
# `-f` があれば `-f` になる)ので、危険な綴りを探す代わりに、展開がある push を読み切れないとして扱う。
segment_has_expansion_mark() {
    local position=0
    while [[ $position -lt $token_count ]]; do
        token_has_expansion_mark "$position" && return 0
        position=$((position + 1))
    done
    return 1
}

# $1(`-c` の値)が、語彙の設定のどれかに言及するか(広い段階。定義は DANGER_CONFIG_BROAD_TOKEN_RE)。
config_value_mentions_danger() {
    [[ "$1" =~ $DANGER_CONFIG_BROAD_TOKEN_RE ]]
}

# $1(`-c` の値)が push を壊す設定そのものか(狭い段階。定義は DANGER_CONFIG_NARROW_RE)。
config_is_dangerous() {
    [[ "$1" =~ $DANGER_CONFIG_NARROW_RE ]]
}

# Classify one segment as a git invocation whose binary sits at token index $1.
# Reads the `tokens` / `token_count` globals classify_segment sets.
#
# $2 is 1 when that index is the command position — the segment's first token,
# or the first one past a recognized prefix — and 0 when the `git` token was
# merely found somewhere further along. The two cases warrant different
# verdicts: `xargs -n1 git push origin main --force` is a real push this scan
# cannot confirm will run, while `- git push --force を deny する` inside a
# heredoc PR body tokenizes identically and pushes nothing. `ask` covers the
# first without making the second unwritable; `deny` there would re-create the
# friction this hook exists to remove.
#
# $3 は dashed binary(`…/git-core/git-push`)の名前が決めるサブコマンド。渡されたら $1 の後ろの
# token はすべてそのサブコマンドの引数なので、git の全体オプションの走査を飛ばす。
#
# サブコマンドが `send-pack` なら、$2 に関係なく ask(引数の文法が push と違い、判定器を別に持たない。
# 日常では使わない)。そのため $2 が 0 の散文(`echo see git send-pack docs`)も ask になる。
classify_from() {
    local start=$1 strict=$2
    local index=$((start + 1))
    local subcommand="" config_ask=0 config_danger=0 alias_ask=0 danger="" token value argument

    if [[ -n "${3:-}" ]]; then
        subcommand=$3
        index=$start
    fi

    # Walk git's own options to find the subcommand. `-c <cfg>` and friends take
    # a separate value token, so they advance by two.
    while [[ -z "$subcommand" && $index -lt $token_count ]]; do
        strip_backticks "${tokens[$index]}"
        token=$STRIPPED
        case "$token" in
        -c | --config-env)
            strip_backticks "${tokens[$((index + 1))]:-}"
            value=$STRIPPED
            # 設定は、push の引数の走査が見るフラグを 1 つも書かずに素の push を破壊的にできる
            # (語彙の DANGER_REMOTE_KEYS / DANGER_INCLUDE_KEY)。安全ではなく読み切れないとして扱う。
            config_value_mentions_danger "$value" && config_ask=1
            config_is_dangerous "$value" && config_danger=1
            # `-c alias.p='push --force' p` は、サブコマンドが `push` でなくても push になる。
            # git の設定キーは大文字小文字を区別しないので、`ALIAS.p=…` も同じに扱う。
            case "$value" in [Aa][Ll][Ii][Aa][Ss].*=*push*) alias_ask=1 ;; esac
            # `--config-env alias.p=VAR` の `=` の後ろは値ではなく環境変数の名前で、展開先
            # (`VAR='push --force'`)はここから読めない。alias のキーなら値に関係なく ask。
            if [[ "$token" == --config-env ]]; then
                case "$value" in [Aa][Ll][Ii][Aa][Ss].*) alias_ask=1 ;; esac
            fi
            index=$((index + 2))
            ;;
        # `--attr-source <tree>` も値を別の token に取る(git 2.55 で実測)。並べないと値が
        # サブコマンドに見え、`git --attr-source HEAD push … --force` が無出力になる。
        -C | --git-dir | --work-tree | --namespace | --exec-path | --attr-source)
            index=$((index + 2))
            ;;
        -c* | --config-env=*)
            case "$token" in
            --config-env=*) value=${token#--config-env=} ;;
            *) value=${token#-c} ;;
            esac
            config_value_mentions_danger "$value" && config_ask=1
            config_is_dangerous "$value" && config_danger=1
            case "$token" in
            -c[Aa][Ll][Ii][Aa][Ss].*=*push* | --config-env=[Aa][Ll][Ii][Aa][Ss].*) alias_ask=1 ;;
            esac
            index=$((index + 1))
            ;;
        -*)
            index=$((index + 1))
            ;;
        *)
            subcommand=$token
            break
            ;;
        esac
    done
    # 下の `push` でないときの早期 return より前に立てる(alias の展開先はここでは読めない)。
    [[ $alias_ask -eq 1 ]] && NEEDS_ASK=1
    # 引数に関係なく ask にする理由は、この関数の前のコメントにある。
    [[ "$subcommand" == "send-pack" ]] && NEEDS_ASK=1
    # サブコマンドそのものを展開で作る綴り(`git {push,origin,main,--force}`)は、token が
    # `push,origin,main,--force` なので push に見えない。印のある token が push を含めば ask。
    if [[ "$subcommand" != "push" && $index -lt $token_count ]] && token_has_expansion_mark "$index"; then
        case "$subcommand" in *push*) NEEDS_ASK=1 ;; esac
    fi
    [[ "$subcommand" == "push" ]] || return 0

    local expansion=0 raw_argument after_comment=0 commented_danger=0 danger_before
    # ブレース展開とパス名展開は `--force` や `+main` を token に現さずに作れる
    # (`git push origin {main,--force}`、cwd に `-f` を置いた `git push origin main -?`)。
    # strict=0 でも同じ理由で ask にする(`expansion` は両方の分岐で ask になる)。
    segment_has_expansion_mark && expansion=1
    argument=$((index + 1))
    while [[ $argument -lt $token_count ]]; do
        # strict=0 用: push の引数に `$` かバッククォートがあるか。末尾の 1 つだけは除く —
        # `` x=`git push origin main` `` の `` main` `` は、git を包む置換を閉じるだけのもの。
        raw_argument=${tokens[$argument]%\`}
        case "$raw_argument" in *'$'* | *'`'*) expansion=1 ;; esac
        strip_backticks "${tokens[$argument]}"
        token=$STRIPPED
        # 語頭の `#` から行末まではコメント(reader はコメントを知らない)。その後ろの危険な綴りは
        # deny ではなく ask にする(`git push origin main # do not --force`)。引用された `'#x'` と
        # 区別できないので、無視はせず ask 止まりにする。
        [[ "$token" == \#* ]] && after_comment=1
        danger_before=$danger
        case "$token" in
        --?*)
            # git は長オプションの一意な前方一致を受け付ける(`--dele` は `--delete`、`--force-w` は
            # `--force-with-lease`)。そこで `=` より前が危険なオプションの前方一致なら danger にする。
            # 曖昧な前方一致(`--d` は `--dry-run` とも一致する)は git 自身がエラーにするので、
            # deny しても失うものは無い。部分一致ではなく前方一致なので、`--no-force-with-lease` は
            # 一致しない。
            if long_option_is_dangerous "${token%%=*}"; then
                [[ -z "$danger" ]] && danger=$token
            fi
            ;;
        -*)
            # 短オプションの束(語彙の DANGER_SHORT_LETTERS)。
            case "$token" in
            *[$DANGER_SHORT_LETTERS]*) [[ -z "$danger" ]] && danger=$token ;;
            esac
            ;;
        [$DANGER_REFSPEC_LEADS]*)
            # refspec の先頭(語彙の DANGER_REFSPEC_LEADS)。
            [[ -z "$danger" ]] && danger=$token
            ;;
        esac
        if [[ $after_comment -eq 1 && "$danger" != "$danger_before" ]]; then
            danger=$danger_before
            commented_danger=1
        fi
        argument=$((argument + 1))
    done
    [[ $commented_danger -eq 1 ]] && NEEDS_ASK=1
    # heredoc 演算子より後ろの segment は、危険な綴りでも ask 止まり。reader は heredoc の本文を知らないので、
    # 本文の行は普通の segment に見える(本文の `git push --force を deny する` は、承認しても通せない deny に
    # しない)。heredoc の後ろに実際に書かれた force push も ask に下がるのは受容した格下げ。本文を持たない
    # here-string(`<<<`)と `< <(…)` は reader が heredoc に数えないので、格下げしない。
    if [[ -n "$danger" ]] && shell_reader_segment_follows heredoc; then
        danger=''
        NEEDS_ASK=1
    fi

    if [[ $strict -eq 0 ]]; then
        # コマンド位置を確定できないので deny にはしない(ask 止まり)。下の -c の検査は散文でも
        # 立ちうるので使わず、危険な綴りと、push の引数の `$` / バッククォートだけを見る。
        # 後者が無いと、`` x=`git push origin $r` `` のように変数が --force を運ぶ push が、
        # バッククォートで包むだけで無出力になる。push の引数に限るので、git より前の token や
        # 引用符の中の散文(`echo "git push origin $r"` は token 1 つで、git と読める token が無い)は巻き込まない。
        # ただし push を壊す設定(remote.*.push / remote.*.mirror / include)と GIT_CONFIG_* は見る。
        # オプションか引数を付けた前置詞(`nice -n 0` / `timeout 60` / `sudo -n`)の後ろの git はこの分岐に来るので、見ないと
        # `timeout 60 git -c remote.origin.mirror=true push origin` が無出力になる。ask 止まりなので
        # deny は増えない。`-c push.autoSetupRemote=true` のような無害な設定は巻き込まない。
        [[ -n "$danger" || $expansion -eq 1 || $config_danger -eq 1 || $GIT_CONFIG_IN_COMMAND -eq 1 ]] && NEEDS_ASK=1
        return 0
    fi

    [[ $config_ask -eq 1 ]] && NEEDS_ASK=1

    # A variable or command substitution can carry `--force` or `+main` into the
    # argument list without either appearing here. Scoped to the push segment on
    # purpose: `git commit -m "$(date)" && git push origin x` stays frictionless.
    local raw
    for raw in "${tokens[@]}"; do
        case "$raw" in *'$'* | *'`'*) NEEDS_ASK=1 ;; esac
    done
    # コマンド全体の token の `GIT_CONFIG*`(GIT_CONFIG_IN_COMMAND を設定するループの説明)。
    [[ $GIT_CONFIG_IN_COMMAND -eq 1 ]] && NEEDS_ASK=1
    [[ $expansion -eq 1 ]] && NEEDS_ASK=1

    [[ -n "$danger" && -z "$DANGER_TOKEN" ]] && DANGER_TOKEN=$danger
    return 0
}

# token index $1 の語 $3 が git(パスつきも)か git-core の dashed binary なら、$2 の強さで判定して 0 を返す。
# それ以外は 1。dashed binary はサブコマンドが名前で決まる。
classify_git_word() {
    case "${3##*/}" in
    git) classify_from "$1" "$2" ;;
    git-push) classify_from "$1" "$2" push ;;
    git-send-pack) classify_from "$1" "$2" send-pack ;;
    *) return 1 ;;
    esac
    return 0
}

# segment への分割と、グルーピング記号・リダイレクトの `&`・継続行の正規化は
# reader が行う(test/shell-reader.bats)。`git commit -m wip && git push --force` が
# 最初の動詞に隠れず、`(cd dir && git push … --force)` の `)` がフラグに接着しないのは
# そのため。この関数は segment ごとに tokens / token_count を設定して判定する。
#
# shell_reader_each_segment の callback。常に 0 を返す(全 segment を見る)。
# classify_from は tokens / token_count を動的スコープ(または global)経由で読む。
# reader の local は `_sr_` 接頭辞なので、ここの変数名と衝突しない。
classify_segment() {
    # 空配列の展開は bash 3.2 の set -u で落ちるが、callback は空でない segment でしか呼ばれない。
    tokens=("$@")
    token_count=$#
    # 関数を token ごとに呼ぶので、位置引数を空にする(shell_reader_each_segment のコメントを参照)。
    set --

    # binary の前に正当に立つもの(代入・シェルのキーワード・前置詞)の読み飛ばしは reader が行う。
    # 1 行の `for … do git push … ; done` や `if true; then …; fi` はエージェントが普通に書く綴り。
    # 読み飛ばした前置詞はすべて透過する(git の引数は前置詞を通しても変わらない)。
    shell_reader_command_word
    command_start=$SHELL_READER_COMMAND_INDEX

    # コマンドの位置の語そのものを展開で作る綴り(bash の `{git,push,origin,main,--force}`、
    # `/usr/bin/gi? push …`)は、`git` と読める token が無いので下の走査が何も見つけない。コマンドの
    # 位置の token に印があり、segment に push を含む token があれば読み切れないとして ask にする。
    # コマンドの位置に限るのは、`grep -n push *.sh` のような引数の glob を巻き込まないため。
    # 置換や変数がコマンドの位置にある綴り(`$G push …`、`` `which git` push … ``、
    # `"$(command -v git)" push …`)も同じく git と読める token が無いので、同じ扱いにする。
    # 単独の `$` は、後ろの token にブレースの印があるときだけ数える: 引用符の外の `${G}` は reader が
    # `{` で切るので `$` と `G` に分かれる。印が無い単独の `$` は bash でも zsh でも文字のままで、
    # heredoc 本文のプロンプト表記(`$ git push origin main`)がこの形になる。
    # 引用符の外の `$(which git) push …` は reader が `)` で segment を切るので、push の segment が
    # `push` そのものか、git の全体オプション・リダイレクト(`-C . push …`、`2>/dev/null push …`)から
    # 始まる。これは前置きが無く、segment が引用符の外の `$(` より後ろにあるときに限る(heredoc の散文の
    # 行頭の push と、`` x=`git push origin main` `` の代入の後ろの push を巻き込まないため)。
    command_word_unreadable=0
    if [[ $command_start -lt $token_count ]]; then
        token_has_expansion_mark "$command_start" && command_word_unreadable=1
        case "${tokens[$command_start]}" in
        '$')
            if [[ $((command_start + 1)) -lt $token_count ]] && token_has_expansion_mark $((command_start + 1)); then
                command_word_unreadable=1
            fi
            ;;
        *'$'* | *'`'*) command_word_unreadable=1 ;;
        esac
        if [[ $command_start -eq 0 ]] && shell_reader_segment_follows substitution; then
            case "${tokens[0]}" in
            push | -* | *[\<\>]*) command_word_unreadable=1 ;;
            esac
        fi
    fi
    if [[ $command_word_unreadable -eq 1 ]]; then
        for marked_token in "${tokens[@]}"; do
            case "$marked_token" in *push*)
                NEEDS_ASK=1
                break
                ;;
            esac
        done
    fi

    if [[ $command_start -lt $token_count ]]; then
        # 名前は reader が先頭のバッククォートと zsh の EQUALS の `=` を外している(`=git` は PATH 上の git に
        # 展開される。Bash ツールが zsh で動く環境では、そのまま force push になる)。末尾のバッククォートは
        # ここで外す(`` `git` push … `` の語は `` git` `` になる)。
        binary=${SHELL_READER_COMMAND_NAME%\`}
        # Accept an absolute or relative path to git as well as the bare name.
        classify_git_word "$command_start" 1 "$binary" && return 0
    fi

    # The command position is something else. `git` may still be in here — as a
    # wrapper's argument, inside a substitution, or as a word in a heredoc — so
    # look for it and classify from there, at `ask` strength only.
    # 丸ごと引用された `echo "git push --force"` が無出力なのは、reader がそれを basename が
    # `git` でない 1 token として返すため。先頭のバッククォートは実行されるので外して見る。
    # token の途中のバッククォートも同じく実行される。引用符の外の `` x=`git push … --force` `` は
    # reader が空白で割るので、代入の token が `` x=`git `` になり、上の前置の読み飛ばしで
    # command_start の手前に置かれる。そこで走査は先頭から始め、最後のバッククォートより後ろを見る
    # (バッククォートを含まない token では何も外さない)。command_start の手前にあるのは代入と
    # キーワード・前置詞だけで、ここから見つかった git は ask 止まり(危険な綴りがあるときだけ)。
    probe=0
    while [[ $probe -lt $token_count ]]; do
        raw=${tokens[$probe]##*\`}
        raw=${raw#=}
        classify_git_word "$probe" 0 "$raw" && break
        probe=$((probe + 1))
    done
    return 0
}

shell_reader_each_segment classify_segment

# reader が読み切れない部分(引用符の中の置換に埋まった push、PR 本文の heredoc、閉じていない引用符、
# 長さ超過のコマンド全体。対象は lib の shell_reader_text_floor_matches)に、git・push・危険な綴りが
# 同じ行にそろっていれば ask にする。deny にしないのは、PR 本文の散文も同じ形になるため。
# 同じ行に「git … push」と ` -f ` や ` :x` を含む散文が ask になるのは、受容した誤 ask。
# deny が決まっていれば ask は出ないので、床を走らせない。
if [[ -z "$DANGER_TOKEN" ]] && shell_reader_text_floor_matches "$DANGER_TEXT_RE" "$DANGER_FLAG_RE"; then
    NEEDS_ASK=1
fi

if [[ -n "$DANGER_TOKEN" ]]; then
    command_guard_emit deny "git-push-guard: 破壊的な push の綴りを検出しました(${DANGER_TOKEN})。force push とリモートブランチ削除は人間が自分の端末で行う方針です。"
    exit 0
fi

if [[ $NEEDS_ASK -eq 1 ]]; then
    command_guard_emit ask "$ASK_REASON"
    exit 0
fi

exit 0
