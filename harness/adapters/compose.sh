#!/usr/bin/env bash
# 組み込み Runtime Adapter "compose": 複数の Content Module を 1 つの Target に連結する。
# 契約: compose.sh render <staging-file> <target-json>
#   target.modules[]   (必須) HARNESS_SOURCE_DIR からの相対パス。宣言順に連結する
#   target.frontmatter (任意) 空でないオブジェクト。--- で囲んだ YAML として先頭に出す(値はスカラーのみ)
#   target.banner      (任意) 1 行の文字列。frontmatter の直後に <!-- ... --> として出す
# 詳細: docs/superpowers/specs/2026-09-12-project-instruction-sync-design.md
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

if ! { [ "${1:-}" = render ] && [ $# -eq 3 ]; }; then
    echo "compose adapter: 使い方: compose.sh render <staging-file> <target-json>" >&2
    exit 64
fi
staging=$2
target=$3

# modules / source の相対パス規則は file adapter と共通(HARNESS_SOURCE_DIR の外を読ませない)
# shellcheck source=../lib/path.bash
source "${HARNESS_HOME:?compose adapter: HARNESS_HOME が未設定です (harness.sh から実行してください)}/lib/path.bash"

fail() {
    echo "compose adapter: $*" >&2
    exit 1
}

# 形の検査は jq 1 回で「最初の理由」だけを受け取る(manifest.bash の validate と同じ形)。
# modules の相対パス規則をここで通すのが重要: この後の read ループは行単位なので、
# 改行を含む 1 エントリを先に弾いておかないと 1 宣言が複数パスに分裂する。
# frontmatter は値だけでなく**キー**も検査する。改行や ":" を含むキーは --- ブロックを
# 途中で閉じてしまい、alwaysApply が本文へ落ちて rule が黙って常時適用でなくなる。
# 空の frontmatter({})も拒否する: frontmatter の無い .cursor/rules ファイルは Cursor に無視される。
# shellcheck disable=SC2016 # $re / $rule は jq の --arg 変数(シェル変数ではない)
reason=$(jq -r --arg re "$HARNESS_RELPATH_REJECT_RE" --arg rule "$HARNESS_RELPATH_RULE_TEXT" '
    def bad_paths: [.modules[] | select(test($re))];
    if (has("modules") | not) or (.modules | type) != "array"
        then "target に modules (文字列の配列) がありません"
    elif ([.modules[] | strings | select(. != "")] | length) != (.modules | length)
        then "target の modules には空でない文字列だけを並べてください"
    elif (.modules | length) == 0
        then "target の modules が空です (連結するモジュールを 1 つ以上並べてください)"
    elif (bad_paths | length) > 0
        then "modules の \(bad_paths[0] | @json) は正規化された相対パスでなければなりません (\($rule))"
    elif has("frontmatter") and (.frontmatter | type) != "object"
        then "target の frontmatter はオブジェクトでなければなりません"
    elif has("frontmatter") and (.frontmatter | length) == 0
        then "target の frontmatter が空です (省略するか、1 つ以上の項目を書いてください)"
    elif has("frontmatter") and ([.frontmatter | keys_unsorted[] | select(test("^[A-Za-z0-9_.-]+$") | not)] | length) > 0
        then "target の frontmatter のキーは英数字・_・.・- だけで書いてください (\([.frontmatter | keys_unsorted[] | select(test("^[A-Za-z0-9_.-]+$") | not)][0] | @json))"
    elif has("frontmatter") and ([.frontmatter[] | select((type | . == "string" or . == "boolean" or . == "number") | not)] | length) > 0
        then "target の frontmatter の値は文字列・真偽値・数値のいずれかでなければなりません"
    elif has("banner") and (.banner | type) != "string"
        then "target の banner は文字列でなければなりません"
    elif has("banner") and (.banner | test("[[:cntrl:]]|-->"))
        then "target の banner に制御文字と \"-->\" は使えません"
    else empty end' <<<"$target" | sed -n 1p) || fail "target を JSON として解釈できません: $target"
[ -z "$reason" ] || fail "$reason"

# 制御文字は上で弾いてあるので、行単位の read で 1 行 1 エントリが保証される
modules=()
while IFS= read -r rel; do
    modules+=("$rel")
done < <(jq -r '.modules[]' <<<"$target")

for rel in "${modules[@]}"; do
    [ -f "$HARNESS_SOURCE_DIR/$rel" ] || fail "モジュールがありません: $HARNESS_SOURCE_DIR/$rel"
done

# 値が文字列なら tojson(二重引用符付き)にする。YAML としても常に妥当で、Cursor の公式例も同じ形
frontmatter_yaml=""
if [ "$(jq -r 'has("frontmatter")' <<<"$target")" = true ]; then
    frontmatter_yaml=$(jq -r '.frontmatter | to_entries[]
        | "\(.key): \(if (.value | type) == "string" then (.value | tojson) else (.value | tostring) end)"' <<<"$target")
fi
banner=$(jq -r '.banner // empty' <<<"$target")

# 各モジュールは末尾改行を落としてから改行 1 つに正規化する(末尾改行の無いモジュールが
# 次のモジュールの見出しと同じ行に繋がるのを防ぐ)。モジュール同士は空行 1 つで区切る。
# cat の終了ステータスは必ず見る: $(cat ...) の中で失敗しても printf は成功するので、
# 読めないモジュールが「空のセクション」として静かに Target へ入ってしまう
{
    [ -z "$frontmatter_yaml" ] || printf -- '---\n%s\n---\n\n' "$frontmatter_yaml"
    [ -z "$banner" ] || printf '<!-- %s -->\n\n' "$banner"
    first=1
    for rel in "${modules[@]}"; do
        [ "$first" -eq 1 ] || printf '\n'
        first=0
        content=$(cat "$HARNESS_SOURCE_DIR/$rel") || fail "モジュールを読めません: $HARNESS_SOURCE_DIR/$rel"
        printf '%s\n' "$content"
    done
} >"$staging"
