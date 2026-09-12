#!/usr/bin/env bash
# Capability Probe: runtime の存在・バージョン・必須 capability を実際の挙動で確かめる。
# harness.sh から source される。依存: report.bash、manifest.bash
#
# バージョン文字列だけでは機能の有無が分からないので、capability は
# `bin args` の出力を pattern(ERE)で照合する(spec「決定事項サマリ」Capability Probe)。
#
# shellcheck disable=SC2016
# ファイル全体: jq クエリ中の $var はシェル変数ではなく jq 自身の --arg/--argjson 変数なので、
# シングルクォートのまま展開させない(SC2016 は意図した挙動への誤検知)。

# version_lt A B: semver A < B なら 0(sort -V で比較)
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# extract_version TEXT: 最初の X.Y.Z を出力。無ければ return 1
# (head -n1 は pipefail 下で SIGPIPE による偽陰性を持ちうるため sed -n 1p を使う)
extract_version() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$1" | sed -n 1p | grep .
}

# run_capture BIN ARGS...: stdout+stderr を結合して出力。exit code は握りつぶす
# (--help で非 0 を返すツールがあっても照合だけできればよい)
run_capture() {
    "$@" 2>&1 || true
}

# args_key ARGS...: 引数列を 1 つの文字列にする(直前の実行と同じ引数かの比較用。区切りは US 0x1f)
args_key() {
    local IFS=$'\x1f'
    printf '%s' "$*"
}

# probe_runtime NAME: 1 runtime を検査し、OK / WARN / FAIL のいずれか 1 行以上を報告する
probe_runtime() {
    local name=$1 bin min max
    bin=$(manifest_runtime_field "$name" bin)
    min=$(manifest_runtime_field "$name" minVersion)
    max=$(manifest_runtime_field "$name" maxVerifiedVersion)

    if ! command -v "$bin" >/dev/null 2>&1; then
        report_fail "runtime $name: 見つかりません (bin: $bin)"
        return 0
    fi

    local version_args=() arg
    while IFS= read -r arg; do
        version_args+=("$arg")
    done < <(manifest_query --arg n "$name" '.runtimes[$n].versionArgs // ["--version"] | .[]')

    # 直前に実行した引数列とその出力を 1 組だけ覚え、同じ引数の capability は再実行しない
    # (実 manifest では全 capability が同じ --help で、apm --help は約 1 秒かかる)
    local output version last_args last_output
    output=$(run_capture "$bin" ${version_args[@]+"${version_args[@]}"})
    last_args=$(args_key ${version_args[@]+"${version_args[@]}"})
    last_output=$output
    if ! version=$(extract_version "$output"); then
        # ${arr[*]-}: 空配列を bash 3.2 の set -u で unbound にしない(unbound で abort すると FAIL 行も summary も出ない)
        report_fail "runtime $name: バージョンを解釈できません (\`$bin ${version_args[*]-}\` の出力: $(head -n1 <<<"$output"))"
        return 0
    fi
    if version_lt "$version" "$min"; then
        report_fail "runtime $name $version: minVersion $min 未満"
        return 0
    fi

    local failed=0 cap_count i cap_name pattern cap_args key
    cap_count=$(manifest_query --arg n "$name" '.runtimes[$n].capabilities // [] | length')
    for ((i = 0; i < cap_count; i++)); do
        cap_name=$(manifest_query --arg n "$name" --argjson i "$i" '.runtimes[$n].capabilities[$i].name')
        pattern=$(manifest_query --arg n "$name" --argjson i "$i" '.runtimes[$n].capabilities[$i].pattern')
        cap_args=()
        while IFS= read -r arg; do
            cap_args+=("$arg")
        done < <(manifest_query --arg n "$name" --argjson i "$i" '.runtimes[$n].capabilities[$i].args // [] | .[]')
        key=$(args_key ${cap_args[@]+"${cap_args[@]}"})
        if [ "$key" != "$last_args" ]; then
            output=$(run_capture "$bin" ${cap_args[@]+"${cap_args[@]}"})
            last_args=$key
            last_output=$output
        else
            output=$last_output
        fi
        if ! grep -qE -- "$pattern" <<<"$output"; then
            report_fail "runtime $name $version: capability $cap_name がありません (pattern: $pattern)"
            failed=1
        fi
    done
    [ "$failed" -eq 0 ] || return 0

    if [ -n "$max" ] && version_lt "$max" "$version"; then
        report_warn "runtime $name $version: maxVerifiedVersion $max を超えています (再検証が必要)"
        return 0
    fi
    report_ok "runtime $name $version"
}
