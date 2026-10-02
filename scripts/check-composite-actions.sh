#!/usr/bin/env bash
# composite action(.github/actions/*/action.yml)の `run:` スクリプトを検査する。
#
# actionlint が shellcheck にかけるのは workflow の `run:` だけで、composite action の
# `run:` はどの linter も見ていない。`if: failure()` でしか走らない action は壊れていても
# 普段の CI で実行されず、harness-issue-alert は作成時から `unexpected EOF` で落ち続けていた
# のに約 3 か月気づかれなかった(#411)。
#
# 各 step の `run:` を YAML パーサで取り出し、`bash -n` と(入っていれば)shellcheck にかける。
# YAML を行単位で読まずパーサを通すのは、インデントがずれた行が `run:` の外に落ちる
# という、まさに検出したい壊れ方を見るため。
#
# 使い方: check-composite-actions.sh [action.yml ...]
#   引数を省くと .github/actions/*/action.yml をすべて検査する。
set -euo pipefail

if [ "$#" -eq 0 ]; then
    shopt -s nullglob
    set -- .github/actions/*/action.yml
    shopt -u nullglob
    if [ "$#" -eq 0 ]; then
        echo "No composite actions found"
        exit 0
    fi
fi

if ! command -v ruby >/dev/null 2>&1; then
    echo "ERROR: ruby is required to parse action.yml" >&2
    exit 1
fi

have_shellcheck=1
if ! command -v shellcheck >/dev/null 2>&1; then
    have_shellcheck=0
    echo "WARNING: shellcheck not found, running bash -n only"
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# 各 step の run を <workdir>/<n>.sh に書き出し、「<n>.sh<TAB><step 名>」を 1 行ずつ出す。
# `${{ … }}` はシェルの構文ではないので、評価後と同じく 1 語に置き換える。
# composite 以外(node / docker)の action は run: を持たないので何も出さない。
extract() {
    ruby -ryaml -e '
        doc = YAML.safe_load(File.read(ARGV[0]))
        abort "not a mapping" unless doc.is_a?(Hash)
        runs = doc["runs"]
        exit 0 unless runs.is_a?(Hash) && runs["using"] == "composite"
        steps = runs["steps"]
        abort "runs.steps is missing" unless steps.is_a?(Array)
        steps.each_with_index do |step, i|
            next unless step.is_a?(Hash) && step.key?("run")
            shell = step["shell"].to_s
            next unless shell == "bash" || shell.start_with?("bash ")
            path = File.join(ARGV[1], "#{i}.sh")
            File.write(path, step["run"].to_s.gsub(/\$\{\{.*?\}\}/m, "GHA_EXPR"))
            puts "#{i}.sh\t#{step["name"] || "step #{i}"}"
        end
    ' "$1" "$2"
}

status=0
for action in "$@"; do
    dir="$workdir/$(printf '%s' "$action" | tr '/' '_')"
    mkdir -p "$dir"
    if ! listing=$(extract "$action" "$dir"); then
        echo "FAIL $action: could not parse" >&2
        status=1
        continue
    fi
    [ -n "$listing" ] || continue
    while IFS=$'\t' read -r script name; do
        label="$action ($name)"
        if ! bash -n "$dir/$script"; then
            echo "FAIL $label: bash -n" >&2
            status=1
            continue
        fi
        if [ "$have_shellcheck" -eq 1 ] && ! shellcheck -s bash "$dir/$script"; then
            echo "FAIL $label: shellcheck" >&2
            status=1
            continue
        fi
        echo "ok   $label"
    done <<<"$listing"
done

exit "$status"
