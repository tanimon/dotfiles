#!/usr/bin/env bash
# ネイティブ Bash サンドボックス(`command claude` 経路の escape hatch。dot_config/nono/CLAUDE.md の
# 「Native Bash sandbox (escape hatch)」)の振る舞いを確かめる smoke test。`just smoke-native-sandbox`
# から、素のターミナル(どのサンドボックスの外)で人間が実行する。API 費用がかかるので lint と
# CI には入れていない。
#
# ネイティブサンドボックスは単体の CLI として呼べないので、使い捨ての一時ディレクトリを cwd に
# して `claude -p` を起動し、scripts/native-sandbox-probe.sh を Bash ツールで 1 回実行させる。
# 判定はプローブが書く results.tsv だけで行い、モデルの応答文は見ない。results.tsv が無ければ
# 再試行せずに fail する。
#
# 検証するのはデプロイ済みの ~/.claude/settings.json の sandbox ブロックであり、このブランチの
# dot_claude/settings.json.tmpl ではない。`claude -p` は user settings を読み、--settings は
# それにマージされるだけなので、ブランチ側の設定を差し込めない。source とデプロイ先が
# 食い違っていれば警告する(fail にはしない)。
#
# 対象は filesystem の denyRead / allowRead と、/tmp(許可)・$HOME 直下(拒否)への書き込み。
# excludedCommands と network 系の設定は検証しない。
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
PROBE="$REPO/scripts/native-sandbox-probe.sh"
SETTINGS="$HOME/.claude/settings.json"
BUDGET_USD="${NATIVE_SANDBOX_SMOKE_BUDGET_USD:-0.5}"
# --allowedTools のパターンとプロンプトで指示するコマンドは、この 1 つの文字列から作る。
# ずれるとプローブの実行が拒否され、results.tsv が残らず fail になる
PROBE_COMMAND='bash ./probe.sh'

die() {
    printf 'native-sandbox-smoke: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'native-sandbox-smoke: warning: %s\n' "$*" >&2
}

# サンドボックスの内側からは意味のある結果が出ないので、skip ではなく fail にする。
# macOS は入れ子の sandbox_apply を拒否し、プローブの Bash ツールが起動できないか、
# 外側の境界の結果を測ることになる。変数は誰でも立てられるので境界ではなく誤用の検出
for var in INSIDE_NONO_SANDBOX CLAUDECODE SANDBOX_RUNTIME; do
    [[ -z "${!var:-}" ]] && continue
    case "$var" in
    INSIDE_NONO_SANDBOX) where='nono の内側' ;;
    CLAUDECODE) where='Claude Code のセッション(Bash ツールや ! 実行)の内側' ;;
    SANDBOX_RUNTIME) where='ネイティブ Bash サンドボックスの内側' ;;
    esac
    die "${var} が設定されている(${where})。入れ子のサンドボックスは macOS が拒否するため、素のターミナルで実行すること"
done

command -v jq >/dev/null 2>&1 || die 'jq not found (brew install jq)'
command -v claude >/dev/null 2>&1 || die 'claude not found'
[[ -f "$SETTINGS" ]] || die "${SETTINGS} not found"
jq -e '.sandbox.enabled == true' "$SETTINGS" >/dev/null 2>&1 ||
    die "sandbox.enabled is not true in ${SETTINGS}; there is no native sandbox to test"

printf 'native-sandbox-smoke: testing the deployed %s (not this branch)\n' "$SETTINGS"
rendered=''
if command -v chezmoi >/dev/null 2>&1 &&
    rendered=$(chezmoi execute-template --source "$REPO" <"$REPO/dot_claude/settings.json.tmpl" 2>/dev/null) &&
    source_sandbox=$(jq -S '.sandbox' <<<"$rendered" 2>/dev/null); then
    deployed_sandbox=$(jq -S '.sandbox' "$SETTINGS")
    [[ "$source_sandbox" == "$deployed_sandbox" ]] ||
        warn "the sandbox block in ${SETTINGS} differs from dot_claude/settings.json.tmpl in ${REPO}; the deployed one is what gets tested (run chezmoi apply after merging to test the source)"
else
    warn "could not compare the deployed sandbox block with the chezmoi source (chezmoi missing or execute-template failed)"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/native-sandbox-smoke.XXXXXX")
rand=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
TMP_WRITE="/tmp/native-sandbox-probe.${rand}"
HOME_WRITE="$HOME/.native-sandbox-probe.${rand}"
# プローブは書き込みの後で必ず消すが、プローブが途中で止まった場合に備えて外側でも消す
cleanup() {
    rm -f -- "$TMP_WRITE" "$HOME_WRITE" 2>/dev/null || true
    rm -rf -- "$WORK"
}
trap cleanup EXIT

# targets.tsv を組む。存在と種類はここ(サンドボックスの外)で判定する。内側では拒否された
# パスの stat も失敗することがあり、「無い」と「読めない」を区別できないため。
# denyRead と allowRead の両方にあるパスは allowRead が優先されるので許可側に入れる。
# 拒否側のディレクトリは、列挙に加えて直下のファイル(allowRead にあるものを除く)の
# 読み取りも項目にする。列挙の拒否だけでは中身の読み取りの拒否を示さないため
expand() {
    local path=$1
    # settings の値に書かれたリテラルの ~ と照合するので、展開させないのが意図どおり
    # shellcheck disable=SC2088
    case "$path" in
    '~') printf '%s\n' "$HOME" ;;
    '~/'*) printf '%s\n' "$HOME/${path#\~/}" ;;
    *) printf '%s\n' "$path" ;;
    esac
}
allow_list=$(jq -r '.sandbox.filesystem.allowRead // [] | .[]' "$SETTINGS")
deny_list=$(jq -r '.sandbox.filesystem as $f | ($f.denyRead // []) - ($f.allowRead // []) | .[]' "$SETTINGS")
allowed_paths=$(while IFS= read -r entry; do [[ -n "$entry" ]] && expand "$entry"; done <<<"$allow_list")
add_read_target() {
    local expect=$1 target=$2
    if [[ -d "$target" ]]; then
        printf 'read-dir\t%s\t%s\n' "$expect" "$target"
    elif [[ -e "$target" ]]; then
        printf 'read-file\t%s\t%s\n' "$expect" "$target"
    else
        printf 'read-absent\t%s\t%s\n' "$expect" "$target"
    fi
}
{
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        target=$(expand "$entry")
        add_read_target deny "$target"
        [[ -d "$target" ]] || continue
        while IFS= read -r child; do
            grep -qxF -- "$child" <<<"$allowed_paths" || printf 'read-file\tdeny\t%s\n' "$child"
        done < <(find "$target" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort || true)
    done <<<"$deny_list"
    while IFS= read -r target; do
        [[ -n "$target" ]] && add_read_target allow "$target"
    done <<<"$allowed_paths"
    printf 'write\tallow\t%s\n' "$TMP_WRITE"
    printf 'write\tdeny\t%s\n' "$HOME_WRITE"
} >"$WORK/targets.tsv"
cp "$PROBE" "$WORK/probe.sh"

# --settings はデプロイ済みの sandbox ブロック全体に上書きを足したものを渡す。sandbox だけを
# 渡すとマージの深さ次第で filesystem が消え、別の設定を検査することになるため。
#   allowUnsandboxedCommands: false  拒否されたコマンドをモデルがサンドボックス外で再実行すると、
#                                    偽の結果になるうえ認証情報が実際に読まれる
#   autoAllowBashIfSandboxed: false  サンドボックス内のコマンドを無条件に許可させず、
#                                    --allowedTools のプローブ 1 つだけを通す
# --permission-mode default は、デプロイ先の defaultMode(auto)の分類器がプローブ以外の
# コマンドを通さないため。--tools Bash は、Bash サンドボックスの対象外の Read などで
# モデルが結果ファイルを作れないようにするため。残余: デプロイ先の permissions.allow に
# ある Bash ルールは有効なままなので、モデルがそれを使って results.tsv を偽造する経路は
# 塞いでいない
sandbox_settings=$(jq -c '{sandbox: (.sandbox + {enabled: true, allowUnsandboxedCommands: false, autoAllowBashIfSandboxed: false})}' "$SETTINGS")
prompt="Use the Bash tool to run exactly this command once: ${PROBE_COMMAND}
Do not run any other command, do not retry, and do not read or write any file yourself. Its exit status does not matter. Then reply with the single word: done."

claude_status=0
claude_output=$(cd "$WORK" && HARNESS_DISABLE=1 claude -p "$prompt" \
    --model haiku \
    --max-budget-usd "$BUDGET_USD" \
    --permission-mode default \
    --tools Bash \
    --allowedTools "Bash(${PROBE_COMMAND})" \
    --strict-mcp-config \
    --settings "$sandbox_settings" \
    --output-format json 2>&1) || claude_status=$?

results="$WORK/results.tsv"
if [[ ! -f "$results" ]]; then
    printf '%s\n' "$claude_output" >&2
    die "results.tsv was not written (claude exit ${claude_status}); the probe did not run. Not retrying"
fi

printf 'item\texpect\texit\tverdict\n'
cat "$results"

# 期待する行がすべて揃っていることを要求する。空のファイルや途中で切れたファイルを、
# FAIL の行が無いという理由で PASS にしないため。行数は targets.tsv の項目と coverage の 2 行
expected=$(($(wc -l <"$WORK/targets.tsv") + 2))
actual=$(wc -l <"$results")
if [[ "$actual" -ne "$expected" ]] ||
    ! grep -q $'^coverage:deny\t' "$results" ||
    ! grep -q $'^coverage:allow\t' "$results"; then
    printf '%s\n' "$claude_output" >&2
    die "results.tsv is incomplete (${actual} of ${expected} lines)"
fi
if grep -q $'\tFAIL$' "$results"; then
    die 'FAIL: the native sandbox did not behave as configured'
fi
printf 'native-sandbox-smoke: PASS\n'
