#!/usr/bin/env bash
# Verdict(選別が queue の項目に下した結果。CONTEXT.md)を扱う CLI(ADR 0017)。判定の記録(~/.claude/harness/queue-archive.md)の
# Verdict 行の書式を知っているのはこのスクリプトだけにする。選別(harness-review skill の Bookkeeping)と Rule Ledger のスクリプトは
# 子プロセスとして呼ぶ。週次ジョブの印の照合(PR の URL への置き換えなど)は、サブコマンドに移すまでこのスクリプトの外にも書式を持つ(ADR 0017)。
#
#   entries
#   settle --title <見出し> adopted [--pr-url <URL>] | rejected <理由> | handoff <repo> | merged <統合先の見出し>
#
# settle は queue(~/.claude/harness/queue.md)の見出し `## <見出し>` の項目(次の `## ` か `# ` の見出しまで)を queue から外し、
# 末尾の空行を落として Verdict 行を 1 行付け、判定の記録の末尾に前の項目と空行で区切って足す。書く Verdict 行:
#   adopted   環境変数 HARNESS_REVIEW_RUN(週次ジョブが `<branch> run <id>` を渡す)があれば `adopted (<その値>)`、
#             無ければ --pr-url が要り `adopted (PR <URL>)`。両方ある・両方とも無い・値が空は誤り
#   rejected  `rejected (<理由>)`        handoff  `handoff (<repo>)`
#   merged    `merged into <見出し>`。統合先は queue か判定の記録に `## <見出し>` として実在すること
# 括弧で囲む値(理由・repo・URL・HARNESS_REVIEW_RUN)は `)` を含めない(entries は最初の `)` の手前までを読む)。
# 見出しと統合先は `)` を含んでよい(実際の見出しに `(N)` などがあり、merged into は行末まで読む)。どの値も改行を含めない。
# 誤り(見出しが無いか複数、kind が enum に無い、引数の欠落・空・余り、統合先が無い)は、何も書き換えずに exit 2 にする。
# 書き込みは判定の記録への追記 → queue からの削除の順で、どちらも一時ファイルから mv する。間で止まった項目は両方に残り、
# 再実行は判定の記録の同じ見出しの最後の項目が今回の追記と同じ内容なら queue からの削除だけを行う(違えば exit 2)。
# 書き戻す直前に、queue と判定の記録を読み取り時の写しと比べ(cmp)、変わっていれば読み直して作り直す。対話セッションの
# /harness-reflect が LLM の Write/Edit で queue に追記しうるため(lock を守らせられない)。3 回続けて変われば、その回は何も書かずに exit 1。
# 比べてから mv するまでの区間で入った追記は失われうる(LLM の Edit と同じリスクとして受け入れる)。
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
# sources は最初の Source 行に現れる session id(UUID)。判定の記録が無ければ何も出さずに成功する(リンク先の無い symlink は無いとは読まずに失敗する)。
#
# 終了コード: 0 = 成功、1 = 失敗(ファイルを読み書きできない、queue が変わり続けた)、2 = 引数の誤り
set -euo pipefail

HARNESS_DIR="$HOME/.claude/harness"
ARCHIVE="$HARNESS_DIR/queue-archive.md"
QUEUE="$HARNESS_DIR/queue.md"

usage() {
    printf 'usage: harness-verdict.sh entries\n' >&2
    printf '       harness-verdict.sh settle --title <title> adopted [--pr-url <url>] | rejected <reason> | handoff <repo> | merged <title>\n' >&2
    exit 2
}

fail() {
    printf 'harness-verdict: %s\n' "$1" >&2
    exit 1
}

reject() {
    printf 'harness-verdict: %s; nothing written\n' "$1" >&2
    exit 2
}

entries_mode() {
    [[ -e "$ARCHIVE" || -L "$ARCHIVE" ]] || return 0
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

# settle の値の検査。空・改行を含む値は誤り。括弧で囲む値(第 3 引数が paren)は ) も誤り
check_value() { # <名前> <値> [paren]
    [[ -n "$2" ]] || reject "$1 is empty"
    case $2 in *$'\n'* | *$'\r'*) reject "$1 contains a line break" ;; esac
    if [[ "${3:-}" == paren ]]; then
        case $2 in *')'*) reject "$1 contains ')', which ends the verdict early" ;; esac
    fi
    return 0
}

# 見出し(`## ` を除く)が $SETTLE_HEADING と一致する行の数を出す
count_headings() { # <ファイル>
    awk 'BEGIN { h = "## " ENVIRON["SETTLE_HEADING"] } $0 == h { n++ } END { print n + 0 }' "$1"
}

# 見出しが $SETTLE_HEADING の項目のうち最後のものを、末尾の空行を落として出す(無ければ何も出さない)。
# 項目は次の `## ` か `# ` の見出しまで(entries と同じ区切り)
last_entry() { # <ファイル>
    awk 'BEGIN { h = "## " ENVIRON["SETTLE_HEADING"] }
        /^## / || /^# / { inside = ($0 == h); if (inside) { n = 0; last = 0 } }
        inside { buf[++n] = $0; if ($0 !~ /^[ \t\r]*$/) last = n }
        END { for (i = 1; i <= last; i++) print buf[i] }' "$1"
}

# 見出しが $SETTLE_HEADING の項目を除いた queue を出す
without_entry() { # <ファイル>
    awk 'BEGIN { h = "## " ENVIRON["SETTLE_HEADING"] }
        /^## / || /^# / { inside = ($0 == h) }
        !inside { print }' "$1"
}

# 判定の記録を写し、空でなければ最後の行が空行になるよう区切りの空行を足す(末尾に改行が無ければ足す)
archive_with_separator() { # <ファイル>
    awk '{ print; last = $0 } END { if (NR > 0 && last !~ /^[ \t\r]*$/) print "" }' "$1"
}

SETTLE_TMP_FILES=""
cleanup_settle() {
    # shellcheck disable=SC2086 # 空白を含まない mktemp のパスを並べたもの
    [[ -z "$SETTLE_TMP_FILES" ]] || rm -f $SETTLE_TMP_FILES
}

settle_mode() {
    local title='' has_title=0 pr_url='' has_pr_url=0 kind='' arg='' count=0 verdict
    while [[ $# -gt 0 ]]; do
        case $1 in
        --title)
            [[ $# -ge 2 ]] || usage
            title=$2 has_title=1
            shift 2
            ;;
        --pr-url)
            [[ $# -ge 2 ]] || usage
            pr_url=$2 has_pr_url=1
            shift 2
            ;;
        *)
            count=$((count + 1))
            case $count in
            1) kind=$1 ;;
            2) arg=$1 ;;
            *) reject 'too many arguments' ;;
            esac
            shift
            ;;
        esac
    done
    [[ "$has_title" -eq 1 ]] || reject '--title is required'
    check_value --title "$title"
    case $kind in
    adopted)
        [[ "$count" -eq 1 ]] || reject 'adopted takes no argument (use --pr-url)'
        if [[ -n "${HARNESS_REVIEW_RUN+set}" ]]; then
            [[ "$has_pr_url" -eq 0 ]] || reject 'both HARNESS_REVIEW_RUN and --pr-url are given (the weekly job sets HARNESS_REVIEW_RUN; pass --pr-url only by hand)'
            check_value HARNESS_REVIEW_RUN "$HARNESS_REVIEW_RUN" paren
            verdict="adopted ($HARNESS_REVIEW_RUN)"
        else
            [[ "$has_pr_url" -eq 1 ]] || reject 'adopted needs --pr-url <PR URL> (or HARNESS_REVIEW_RUN in the weekly job)'
            check_value --pr-url "$pr_url" paren
            verdict="adopted (PR $pr_url)"
        fi
        ;;
    rejected | handoff | merged)
        [[ "$count" -eq 2 ]] || reject "$kind needs exactly one argument"
        [[ "$has_pr_url" -eq 0 ]] || reject '--pr-url is only for adopted'
        if [[ "$kind" == merged ]]; then
            check_value "$kind" "$arg"
            verdict="merged into $arg"
        else
            check_value "$kind" "$arg" paren
            verdict="$kind ($arg)"
        fi
        ;;
    '') reject 'a kind (adopted | rejected | handoff | merged) is required' ;;
    *) reject "unknown kind '$kind' (adopted | rejected | handoff | merged)" ;;
    esac
    [[ -e "$QUEUE" ]] || reject "$QUEUE does not exist"
    [[ -f "$QUEUE" && -r "$QUEUE" ]] || fail "cannot read $QUEUE"
    [[ ! -e "$ARCHIVE" && ! -L "$ARCHIVE" ]] || [[ -f "$ARCHIVE" && -r "$ARCHIVE" ]] || fail "cannot read $ARCHIVE"

    local queue_copy archive_copy new_queue new_archive
    trap cleanup_settle EXIT
    queue_copy=$(mktemp "$HARNESS_DIR/.settle-queue.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    SETTLE_TMP_FILES=$queue_copy
    archive_copy=$(mktemp "$HARNESS_DIR/.settle-archive.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    new_queue=$(mktemp "$HARNESS_DIR/.settle-new-queue.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    new_archive=$(mktemp "$HARNESS_DIR/.settle-new-archive.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    SETTLE_TMP_FILES="$queue_copy $archive_copy $new_queue $new_archive"
    export SETTLE_HEADING="$title"

    local archive_existed headings block archived expected appended=0
    for _ in 1 2 3; do
        cp "$QUEUE" "$queue_copy" || fail "cannot read $QUEUE"
        archive_existed=0
        : >"$archive_copy"
        if [[ -e "$ARCHIVE" ]]; then
            cp "$ARCHIVE" "$archive_copy" || fail "cannot read $ARCHIVE"
            archive_existed=1
        fi
        headings=$(count_headings "$queue_copy") || fail "cannot read $QUEUE"
        [[ "$headings" -ne 0 ]] || reject "no entry titled '## $title' in $QUEUE"
        [[ "$headings" -eq 1 ]] || reject "$headings entries are titled '## $title' in $QUEUE"
        if [[ "$kind" == merged ]]; then
            headings=$(SETTLE_HEADING="$arg" count_headings "$queue_copy") || fail "cannot read $QUEUE"
            [[ "$headings" -gt 0 ]] || headings=$(SETTLE_HEADING="$arg" count_headings "$archive_copy") || fail "cannot read $ARCHIVE"
            [[ "$headings" -gt 0 ]] || reject "the merge target '## $arg' is in neither $QUEUE nor $ARCHIVE"
        fi
        block=$(last_entry "$queue_copy") || fail "cannot read $QUEUE"
        expected=$(printf '%s\n- **Verdict:** %s' "$block" "$verdict")
        archived=$(last_entry "$archive_copy") || fail "cannot read $ARCHIVE"
        without_entry "$queue_copy" >"$new_queue" || fail "cannot write $new_queue"

        if [[ -z "$archived" ]]; then
            { archive_with_separator "$archive_copy" && printf '%s\n' "$expected"; } >"$new_archive" ||
                fail "cannot write $new_archive"
            cmp -s "$QUEUE" "$queue_copy" || continue
            if [[ "$archive_existed" -eq 1 ]]; then
                cmp -s "$ARCHIVE" "$archive_copy" || continue
            else
                [[ ! -e "$ARCHIVE" ]] || continue
            fi
            mv "$new_archive" "$ARCHIVE" || fail "cannot write $ARCHIVE"
            appended=1
        elif [[ "$archived" != "$expected" ]]; then
            # 再実行(前回の追記の後に queue から外せなかった)なら、同じ内容の項目が判定の記録の最後にある
            reject "$ARCHIVE already has an entry titled '## $title' with a different verdict or body"
        fi
        cmp -s "$QUEUE" "$queue_copy" || continue
        mv "$new_queue" "$QUEUE" || fail "cannot write $QUEUE"
        return 0
    done
    if [[ "$appended" -eq 1 ]]; then
        fail "$QUEUE kept changing while settling '## $title'; it was appended to $ARCHIVE but is still in $QUEUE (run the same settle again to remove it)"
    fi
    fail "$QUEUE kept changing while settling '## $title' (3 times); nothing written"
}

[[ $# -ge 1 ]] || usage
case $1 in
entries)
    [[ $# -eq 1 ]] || usage
    command -v jq >/dev/null 2>&1 || fail 'jq not found'
    entries_mode
    ;;
settle)
    shift
    settle_mode "$@"
    ;;
*) usage ;;
esac
