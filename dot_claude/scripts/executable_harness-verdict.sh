#!/usr/bin/env bash
# Verdict(選別が queue の項目に付ける判定)を扱う CLI(ADR 0017)。判定の記録(~/.claude/harness/queue-archive.md)の
# Verdict 行の書式を知っているのはこのスクリプトだけにし、Rule Ledger のスクリプトなどの読み手は子プロセスとして呼ぶ。
#
#   entries
#
# entries は判定の記録の項目ごとに 1 行の JSON を出す:
#   {"title": "<見出し>", "kind": "adopted"|"rejected"|"handoff"|"merged"|"unknown",
#    "pr_url"?: "<URL>", "run"?: "<印>", "arg"?: "<引数>", "raw": "<Verdict 行の中身>", "sources": [<session id>]}
# 項目は `## ` の見出しから、次の `## ` か `# ` の見出しまで。Verdict と Source は項目ごとに最初の行を使う。
# 見出しと Verdict の中のタブは空白にする(それ以外の正規化はしない。title は Rule Ledger の id の材料になるため)。
# Verdict の読み方(どれも行頭から読み、閉じ括弧の後ろに続く補足は無視する):
#   adopted (PR <URL>)   kind adopted と pr_url(最初の ) の手前まで。URL かどうかは読み手が確かめる)
#   adopted (<それ以外>)  kind adopted と run(PR になっていない採用の印。`<branch> run <id>` と、run id の無い古い形)
#   rejected (<理由>)    kind rejected と arg(最初の ) の手前まで)
#   handoff (<repo>)     kind handoff と arg
#   merged into <見出し>  kind merged と arg(行末まで)
# どれにも当たらない行(括弧の無い rejected など)と Verdict 行の無い項目は kind unknown で、raw を見て扱う。
# sources は最初の Source 行に現れる session id(UUID)。判定の記録が無ければ何も出さずに成功する。
#
# 終了コード: 0 = 成功、1 = 失敗(判定の記録を読めない)、2 = 引数の誤り
set -euo pipefail

ARCHIVE="$HOME/.claude/harness/queue-archive.md"

usage() {
    printf 'usage: harness-verdict.sh entries\n' >&2
    exit 2
}

fail() {
    printf 'harness-verdict: %s\n' "$1" >&2
    exit 1
}

entries_mode() {
    [[ -e "$ARCHIVE" ]] || return 0
    [[ -f "$ARCHIVE" && -r "$ARCHIVE" ]] || fail "cannot read $ARCHIVE"
    awk '
        function flush() {
            if (title != "") print title "\t" verdict "\t" sources
            title = ""; verdict = ""; sources = ""
        }
        /^## / { flush(); title = substr($0, 4); gsub(/\t/, " ", title); next }
        /^# / { flush(); next }
        title != "" && verdict == "" && /^- \*\*Verdict:\*\* / { verdict = substr($0, 16); gsub(/\t/, " ", verdict); next }
        title != "" && sources == "" && /^- \*\*Source:\*\* / { sources = $0; gsub(/\t/, " ", sources); next }
        END { flush() }' "$ARCHIVE" |
        jq -R -c '
            split("\t") as $f | ($f[1] // "") as $v
            | {title: $f[0]}
            + (if ($v | test("^adopted \\([^)]*\\)")) then
                ($v | capture("^adopted \\((?<i>[^)]*)\\)").i) as $i
                | if ($i | startswith("PR ")) then {kind: "adopted", pr_url: $i[3:]}
                  else {kind: "adopted", run: $i} end
              elif ($v | test("^(rejected|handoff) \\([^)]*\\)")) then
                ($v | capture("^(?<k>rejected|handoff) \\((?<a>[^)]*)\\)")) | {kind: .k, arg: .a}
              elif ($v | test("^merged into .")) then {kind: "merged", arg: $v[12:]}
              else {kind: "unknown"} end)
            + {raw: $v, sources: [($f[2] // "") | scan("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")]}' ||
        fail "cannot read $ARCHIVE"
}

[[ $# -ge 1 ]] || usage
case $1 in
entries)
    [[ $# -eq 1 ]] || usage
    command -v jq >/dev/null 2>&1 || fail 'jq not found'
    entries_mode
    ;;
*) usage ;;
esac
