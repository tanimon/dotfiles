#!/usr/bin/env bash
# 組み込み Runtime Adapter "file": Source ファイルをそのまま Target 内容にする。
# 契約: file.sh render <staging-file> <target-json>
#   env HARNESS_SOURCE_DIR からの相対パス target.source を <staging-file> に cp する。
#   source 欠落・不在は exit 1(spec「Runtime Adapter 契約」)。
set -euo pipefail

if ! { [ "${1:-}" = render ] && [ $# -eq 3 ]; }; then
    echo "file adapter: 使い方: file.sh render <staging-file> <target-json>" >&2
    exit 64
fi
staging=$2
target=$3

source_rel=$(jq -r '.source // empty' <<<"$target")
[ -n "$source_rel" ] || {
    echo "file adapter: target に source がありません: $target" >&2
    exit 1
}
source_path="$HARNESS_SOURCE_DIR/$source_rel"
[ -f "$source_path" ] || {
    echo "file adapter: source がありません: $source_path" >&2
    exit 1
}
cp "$source_path" "$staging"
