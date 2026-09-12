#!/usr/bin/env bash
# Harness Manifest(JSON)の読み込み・検証・問い合わせ。harness.sh から source される。
# 依存: report.bash(die)、path.bash、jq、HARNESS_HOME(harness/ の絶対パス)
#
# スキーマは docs/superpowers/specs/2026-09-11-harness-sync-seam-design.md
# 「Harness Manifest スキーマ(version 1)」。検証エラーはすべて "manifest: <理由>" で exit 2。
#
# shellcheck disable=SC2016
# ファイル全体: jq クエリ中の $var はシェル変数ではなく jq 自身の --arg/--argjson 変数なので、
# シングルクォートのまま展開させない(SC2016 は意図した挙動への誤検知)。

# shellcheck source-path=SCRIPTDIR/../lib
# shellcheck source=path.bash
source "$HARNESS_HOME/lib/path.bash"

# minVersion / maxVerifiedVersion の形式(spec「Harness Manifest スキーマ」: semver X.Y.Z)
HARNESS_SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

# 検証済みの target 一覧。index が manifest の targets[] の添字と一致し、staging/<index> にも使う。
# bash 3.2 には連想配列が無いので、並行する index 配列で持つ(render / replace / compare の各ループで
# target ごとに jq を起動しないため)
HARNESS_TARGET_PATHS=()
HARNESS_TARGET_RUNTIMES=()
HARNESS_TARGET_OWNERS=()

# manifest_load PATH: 読み込んで検証し、HARNESS_MANIFEST(絶対パス)と
# HARNESS_MANIFEST_JSON(compact JSON)と HARNESS_TARGET_* を設定する
manifest_load() {
    local path=$1
    command -v jq >/dev/null 2>&1 || die 2 "manifest: jq が必要です (brew install jq)"
    [ -f "$path" ] || die 2 "manifest: ファイルがありません: $path"
    HARNESS_MANIFEST_JSON=$(jq -c . "$path" 2>/dev/null) || die 2 "manifest: JSON として解釈できません: $path"
    HARNESS_MANIFEST="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    export HARNESS_MANIFEST
    manifest_validate
}

# manifest_query JQ_ARGS...: HARNESS_MANIFEST_JSON に対して jq -r を実行する
manifest_query() {
    jq -r "$@" <<<"$HARNESS_MANIFEST_JSON"
}

# manifest_runtimes: runtime 名を 1 行ずつ出力
manifest_runtimes() {
    manifest_query '.runtimes | keys[]'
}

# manifest_runtime_field NAME FIELD: runtimes.NAME.FIELD(無ければ空)
manifest_runtime_field() {
    manifest_query --arg n "$1" --arg f "$2" '.runtimes[$n][$f] // empty'
}

# manifest_target INDEX: targets[INDEX] を compact JSON で出力(adapter に渡す)
manifest_target() {
    manifest_query -c --argjson i "$1" '.targets[$i]'
}

# adapter_path OWNER: adapter 実行ファイルのパスを出力。
# 解決順は HARNESS_ADAPTER_DIR(設定時)→ $HARNESS_HOME/adapters。無ければ return 1
adapter_path() {
    local owner=$1 dir candidate dirs=()
    [ -z "${HARNESS_ADAPTER_DIR:-}" ] || dirs+=("$HARNESS_ADAPTER_DIR")
    dirs+=("$HARNESS_HOME/adapters")
    for dir in "${dirs[@]}"; do
        candidate="$dir/$owner.sh"
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# manifest_load_targets: 検証済みの targets[] を HARNESS_TARGET_* に展開する。
# 区切りは US(0x1f)。path / owner は制御文字を拒否済み、runtime 名は英数字等に限定済みなので衝突しない
manifest_load_targets() {
    local us=$'\x1f' path runtime owner
    HARNESS_TARGET_PATHS=()
    HARNESS_TARGET_RUNTIMES=()
    HARNESS_TARGET_OWNERS=()
    while IFS="$us" read -r path runtime owner; do
        HARNESS_TARGET_PATHS+=("$path")
        HARNESS_TARGET_RUNTIMES+=("$runtime")
        HARNESS_TARGET_OWNERS+=("$owner")
    done < <(manifest_query --arg us "$us" '.targets[] | [.path, .runtime, .owner] | join($us)')
}

manifest_validate() {
    local version reason
    # -r を付けずに JSON 表記で受け、数値の 1 だけを通す("1" は "\"1\"" になるので通らない)
    version=$(jq -c 'if has("version") then .version else empty end' <<<"$HARNESS_MANIFEST_JSON")
    [ "$version" = "1" ] || die 2 "manifest: version は 1 でなければなりません (現在: ${version:-未設定})"

    # runtime の暗黙検出は許さない: runtimes は非空オブジェクトで、"*" キーや bin:"auto" を含まない
    [ "$(manifest_query '.runtimes | type')" = "object" ] ||
        die 2 "manifest: runtimes を明示してください (runtime の暗黙検出はしません)"
    [ "$(manifest_query '.runtimes | length')" -gt 0 ] ||
        die 2 "manifest: runtimes が空です (runtime の暗黙検出はしません)"
    [ "$(manifest_query '.runtimes | has("*")')" = "false" ] ||
        die 2 'manifest: runtimes に "*" は使えません (runtime を明示してください)'

    # 形の検査は jq 1 回で「最初の理由」だけを受け取る。値の型を見てから index するので、
    # 型が違っても jq のエラー(exit 5)ではなく "manifest: <理由>" で exit 2 になる
    # 理由に埋め込む名前・path は @json で 1 行に収める(制御文字を含む値でも sed -n 1p で途中で切れない)。
    # minVersion / maxVerifiedVersion は X.Y.Z 形式に限る(version_lt の sort -V は任意文字列を黙って並べる)
    reason=$(manifest_query --arg semver_re "$HARNESS_SEMVER_RE" '
        .runtimes | to_entries[] | .key as $n | .value as $r
        | if ($n | test("^[A-Za-z0-9_.-]+$") | not) then "runtimes の名前 \($n | @json) は英数字・_・.・- のみ使えます"
          elif ($r | type) != "object" then "runtimes.\($n) はオブジェクトでなければなりません"
          elif ($r.bin | type) != "string" or $r.bin == "" then "runtimes.\($n).bin が必要です (文字列)"
          elif $r.bin == "auto" then "runtimes.\($n).bin に \"auto\" は使えません (実行ファイル名を明示してください)"
          elif ($r.minVersion | type) != "string" or $r.minVersion == "" then "runtimes.\($n).minVersion が必要です (文字列)"
          elif ($r.minVersion | test($semver_re) | not)
               then "runtimes.\($n).minVersion は X.Y.Z 形式でなければなりません (現在: \($r.minVersion | @json))"
          elif $r.maxVerifiedVersion != null and ($r.maxVerifiedVersion | type) != "string"
               then "runtimes.\($n).maxVerifiedVersion は文字列でなければなりません"
          elif $r.maxVerifiedVersion != null and ($r.maxVerifiedVersion | test($semver_re) | not)
               then "runtimes.\($n).maxVerifiedVersion は X.Y.Z 形式でなければなりません (現在: \($r.maxVerifiedVersion | @json))"
          elif $r.versionArgs != null and (($r.versionArgs | type) != "array" or ([$r.versionArgs[] | strings] | length) != ($r.versionArgs | length))
               then "runtimes.\($n).versionArgs は文字列の配列でなければなりません"
          elif $r.capabilities != null and ($r.capabilities | type) != "array"
               then "runtimes.\($n).capabilities は配列でなければなりません"
          elif ([($r.capabilities // [])[]
                 | select((type != "object") or (.name | type) != "string" or .name == ""
                          or (.pattern | type) != "string" or .pattern == ""
                          or (.args != null and ((.args | type) != "array" or ([.args[] | strings] | length) != (.args | length))))]
                 | length) > 0
               then "runtimes.\($n).capabilities[] には name と pattern (空でない文字列) が必要です (args は文字列の配列)"
          else empty end' | sed -n 1p)
    [ -z "$reason" ] || die 2 "manifest: $reason"

    [ "$(manifest_query '.targets | type')" = "array" ] || die 2 "manifest: targets は配列でなければなりません"
    reason=$(manifest_query --arg re "$HARNESS_RELPATH_REJECT_RE" --arg rule "$HARNESS_RELPATH_RULE_TEXT" --arg owner_re "$HARNESS_OWNER_RE" '
        .runtimes as $rts
        | .targets | to_entries[] | .key as $i | .value as $t
        | if ($t | type) != "object" then "targets[\($i)] はオブジェクトでなければなりません"
          elif ($t.path | type) != "string" or $t.path == "" then "targets[\($i)].path が必要です (文字列)"
          elif ($t.runtime | type) != "string" or $t.runtime == "" then "targets[\($i)].runtime が必要です (文字列)"
          elif ($t.owner | type) != "string" or $t.owner == "" then "targets[\($i)].owner が必要です (文字列)"
          elif ($t.path | test($re))
               then "target \($t.path | @json) の path は正規化された相対パスでなければなりません (\($rule))"
          elif ($t.owner | test($owner_re) | not)
               then "target \($t.path | @json) の owner \($t.owner | @json) は adapter 名 (英数字・_・-) でなければなりません"
          elif ($rts | has($t.runtime) | not)
               then "target \($t.path | @json) の runtime \($t.runtime | @json) は runtimes に宣言されていません"
          else empty end' | sed -n 1p)
    [ -z "$reason" ] || die 2 "manifest: $reason"

    # Target Owner は 1 target につき 1 つ: 同じ path が 2 回出たら manifest 全体を reject。
    # 主対象の macOS(APFS 既定)は大文字小文字を区別しないので、比較も区別せずに行う
    local dup owners
    dup=$(manifest_query '[.targets[].path] | group_by(ascii_downcase) | map(select(length > 1) | .[0]) | .[0] // empty')
    if [ -n "$dup" ]; then
        owners=$(manifest_query --arg p "$dup" '[.targets[] | select((.path | ascii_downcase) == ($p | ascii_downcase)) | .owner] | join(", ")')
        die 2 "manifest: target \"$dup\" の owner が重複しています ($owners)"
    fi

    manifest_load_targets
    local i
    for ((i = 0; i < ${#HARNESS_TARGET_PATHS[@]}; i++)); do
        adapter_path "${HARNESS_TARGET_OWNERS[$i]}" >/dev/null ||
            die 2 "manifest: target \"${HARNESS_TARGET_PATHS[$i]}\" の owner \"${HARNESS_TARGET_OWNERS[$i]}\" に対応する adapter がありません"
    done
}
