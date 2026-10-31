#!/usr/bin/env bash
# Verdict(選別が queue の項目に下した結果。GLOSSARY.md)を扱う CLI(ADR 0017)。判定の記録(~/.claude/harness/queue-archive.md)の
# Verdict 行の書式を知っているのはこのスクリプトだけにする。選別(harness-review skill の Bookkeeping)と Rule Ledger のスクリプトは
# 子プロセスとして呼ぶ。週次ジョブの採用の印も mark で組み立て、publish・adopted・unpublished で扱う。印の書式は
# このスクリプトだけが持つ。
#
#   entries
#   settle --title <見出し> adopted [--pr-url <URL>] | rejected <理由> | handoff <repo> | merged <統合先の見出し>
#   publish --run <印> --pr-url <URL>
#   adopted --run <印>
#   unpublished [--branch <ブランチ>]
#   mark --branch <ブランチ> --run-id <run id>
#
# publish・adopted・unpublished の「印」は、PR になっていない採用の Verdict 行 `adopted (<印>)` の括弧の中
# (entries の run。週次ジョブの印は HARNESS_REVIEW_RUN の値)。どれも entries と同じ読み方で、項目ごとに最初の
# Verdict 行だけを見る(本文やコードフェンスの中の同じ文字列は印として読まない)。
#   publish      印が <印> と一致する採用の Verdict 行を `adopted (PR <URL>)` に置き換え(括弧の後ろの補足は残す)、
#                置き換えた件数を出す。0 件(陳腐化の修正だけの PR)でも exit 0 で、判定の記録は書き換えない。
#                書き戻し方(一時ファイルからの mv、mode を保つ、直前の cmp と 3 回までの作り直し)は settle と同じ
#   adopted      印が <印> と一致する採用の見出しを 1 行ずつ出す
#   unpublished  PR になっていない採用の印を、重複を除いて記録の順に 1 行ずつ出す。週次ジョブが書く印は
#                publish の --run にそのまま渡せる。手書きの印のうち空のもの(`adopted ()`)は空行になり、
#                タブを含むものは entries と同じくタブを空白にして出すので、どちらも publish では置き換わらない。
#                --branch を付けると、印が <ブランチ> そのもの(run id を付けていなかった頃の形)か
#                `<ブランチ> run ` で始まるものに絞る(名前が <ブランチ> で始まる別のブランチは含めない)
#   mark         週次ジョブの採用の印 `<ブランチ> run <run id>` を 1 行で出す。判定の記録は読まない。印は settle が括弧で
#                囲む値なので、どちらの値も settle と同じ規則で検査する。`PR ` で始まるブランチは、印が publish の --run に
#                渡せなくなるので誤り
# 値の誤り(欠落・空・改行や ) を含む・余分な引数、`PR ` で始まる --run と --branch)は exit 2。判定の記録が無ければ、何も出さない(publish は 0 を出す)。
#
# settle は queue(~/.claude/harness/queue.md)の見出し `## <見出し>` の項目(区切りは entries と同じ)を queue から外し、
# 末尾の空行を落として Verdict 行を 1 行付け、判定の記録の末尾に前の項目と空行で区切って足す。書く Verdict 行:
#   adopted   環境変数 HARNESS_REVIEW_RUN(週次ジョブの選別では mark が作った印)があれば `adopted (<その値>)`、
#             無ければ --pr-url が要り `adopted (PR <URL>)`。両方ある・両方とも無い・値が空は誤り
#   rejected  `rejected (<理由>)`        handoff  `handoff (<repo>)`
#   merged    `merged into <見出し>`。統合先は queue か判定の記録に `## <見出し>` として実在すること
# 括弧で囲む値(理由・repo・URL・HARNESS_REVIEW_RUN)は `)` を含めない(entries は最初の `)` の手前までを読む)。
# 見出しと統合先は `)` を含んでよい(実際の見出しに `(N)` などがあり、merged into は行末まで読む)。どの値も改行を含めない。
# 誤り(見出しが無いか複数、kind が enum に無い、引数の欠落・空・余り、統合先が無い)は、何も書き換えずに exit 2 にする。
# 書き込みは判定の記録への追記 → queue からの削除の順で、どちらも一時ファイルから mv する。間で止まった項目は両方に残り、
# 再実行は判定の記録の同じ見出しの最後の項目が今回の追記と同じ内容なら queue からの削除だけを行う(違えば exit 2)。
# Verdict だけでなく本文も比べるのは、同じ見出しの別の項目(前に選別した項目)を再実行と取り違えて queue から消さないため。
# 書き戻す直前に、queue と判定の記録を読み取り時の写しと比べ(cmp)、変わっていれば読み直して作り直す。対話セッションの
# /harness-reflect が LLM の Write/Edit で queue に追記しうるため(lock を守らせられない)。3 回続けて変われば、その回は何も書かずに exit 1。
# 比べてから mv するまでの区間で入った追記は失われうる(LLM の Edit と同じリスクとして受け入れる)。
#
# entries は判定の記録の項目ごとに 1 行の JSON を出す:
#   {"title": "<見出し>", "kind": "adopted"|"rejected"|"handoff"|"merged"|"unknown",
#    "pr_url"?: "<URL>", "run"?: "<印>", "arg"?: "<引数>", "raw": "<Verdict 行の中身>", "sources": [<session id>]}
# 項目は `## ` の見出しから、次の `## ` か `# ` の見出しまで。コードフェンス(行頭の ``` か ~~~)の中の行は `# ` の見出しとも
# Verdict 行・Source 行とも読まない(シェルのコメントで項目が切れないため)。`## ` だけはフェンスの中でも見出しとして読み、
# 開いたままのフェンスもそこで閉じる(閉じ忘れたフェンスが後ろの項目をすべて飲み込まないため)。
# Verdict と Source は項目ごとに最初の行を使う。
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
    printf '       harness-verdict.sh publish --run <mark> --pr-url <url>\n' >&2
    printf '       harness-verdict.sh adopted --run <mark>\n' >&2
    printf '       harness-verdict.sh unpublished [--branch <branch>]\n' >&2
    printf '       harness-verdict.sh mark --branch <branch> --run-id <run id>\n' >&2
    exit 2
}

fail() {
    printf 'harness-verdict: %s\n' "$1" >&2
    exit 1
}

# 引数の誤り(どのサブコマンドでも何も書く前に判定する)。settle が再試行の前の回で判定の記録に追記を済ませていれば、
# 何も書いていないとは言わずに exit 1 にする
SETTLE_APPENDED=0
reject() {
    if [[ "$SETTLE_APPENDED" -eq 1 ]]; then
        fail "$1; the entry was already appended to $ARCHIVE in an earlier attempt"
    fi
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
        /^## / { flush(); fence = 0; title = substr($0, 4); gsub(/\t/, " ", title); next }
        /^ ? ? ?(```|~~~)/ { fence = !fence; next }
        fence { next }
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

# 引数の値の検査。空・改行を含む値は誤り。括弧で囲む値(第 3 引数が paren)は ) も誤り
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
# 項目の区切りは entries と同じ(フェンスの中の `# ` では切らない)
last_entry() { # <ファイル>
    awk 'BEGIN { h = "## " ENVIRON["SETTLE_HEADING"] }
        /^## / { fence = 0; inside = ($0 == h); if (inside) { n = 0; last = 0 } }
        !fence && /^# / { inside = 0 }
        inside { buf[++n] = $0; if ($0 !~ /^[ \t\r]*$/) last = n }
        /^ ? ? ?(```|~~~)/ { fence = !fence }
        END { for (i = 1; i <= last; i++) print buf[i] }' "$1"
}

# 見出しが $SETTLE_HEADING の項目を除いた queue を出す
without_entry() { # <ファイル>
    awk 'BEGIN { h = "## " ENVIRON["SETTLE_HEADING"] }
        /^## / { fence = 0; inside = ($0 == h) }
        !fence && /^# / { inside = 0 }
        !inside { print }
        /^ ? ? ?(```|~~~)/ { fence = !fence }' "$1"
}

# 判定の記録を写し、空でなければ最後の行が空行になるよう区切りの空行を足す(末尾に改行が無ければ足す)
archive_with_separator() { # <ファイル>
    awk '{ print; last = $0 } END { if (NR > 0 && last !~ /^[ \t\r]*$/) print "" }' "$1"
}

TMP_FILES=""
cleanup_tmp_files() {
    # shellcheck disable=SC2086 # 空白を含まない mktemp のパスを並べたもの
    [[ -z "$TMP_FILES" ]] || rm -f $TMP_FILES
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
    trap cleanup_tmp_files EXIT
    queue_copy=$(mktemp "$HARNESS_DIR/.settle-queue.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    TMP_FILES=$queue_copy
    archive_copy=$(mktemp "$HARNESS_DIR/.settle-archive.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    new_queue=$(mktemp "$HARNESS_DIR/.settle-new-queue.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    new_archive=$(mktemp "$HARNESS_DIR/.settle-new-archive.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    TMP_FILES="$queue_copy $archive_copy $new_queue $new_archive"
    export SETTLE_HEADING="$title"

    local archive_existed headings block archived expected changed=$QUEUE
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
            [[ "$arg" != "$title" ]] ||
                reject "an entry cannot be merged into itself. To merge it into an earlier entry with the same title in $ARCHIVE, rename only its '## ' line in $QUEUE (e.g. append the date) and settle it under the new title with merged '$title'"
        fi
        block=$(last_entry "$queue_copy") || fail "cannot read $QUEUE"
        expected=$(printf '%s\n- **Verdict:** %s' "$block" "$verdict")
        archived=$(last_entry "$archive_copy") || fail "cannot read $ARCHIVE"
        # 置き換えるファイルの mode を保つため、元のファイルを写してから中身を書く(mktemp の 0600 にしない)
        cp -p "$QUEUE" "$new_queue" || fail "cannot write $new_queue"
        without_entry "$queue_copy" >"$new_queue" || fail "cannot write $new_queue"

        if [[ -z "$archived" ]]; then
            if [[ "$archive_existed" -eq 1 ]]; then
                cp -p "$ARCHIVE" "$new_archive" || fail "cannot write $new_archive"
            else
                # 新しく作る判定の記録は mktemp の 0600 ではなく、ふつうに作ったファイルと同じ umask どおりの mode にする
                chmod "$(printf '%o' $((0666 & ~$(umask))))" "$new_archive" || fail "cannot write $new_archive"
            fi
            { archive_with_separator "$archive_copy" && printf '%s\n' "$expected"; } >"$new_archive" ||
                fail "cannot write $new_archive"
            changed=$QUEUE
            cmp -s "$QUEUE" "$queue_copy" || continue
            changed=$ARCHIVE
            if [[ "$archive_existed" -eq 1 ]]; then
                cmp -s "$ARCHIVE" "$archive_copy" || continue
            else
                [[ ! -e "$ARCHIVE" ]] || continue
            fi
            mv "$new_archive" "$ARCHIVE" || fail "cannot write $ARCHIVE"
            SETTLE_APPENDED=1
        elif [[ "$archived" != "$expected" ]]; then
            # 再実行(前回の追記の後に queue から外せなかった)なら、同じ内容の項目が判定の記録の最後にある
            # それ以外は、前に選別した別の項目と見出しが同じ。引数を直しても通らないので、見出しを変える手順を伝える
            reject "$ARCHIVE already has an entry titled '## $title' with a different verdict or body. If this is a rerun, pass the same verdict as before. Otherwise the queue entry is a different one with the same title: rename only its '## ' line in $QUEUE (e.g. append the date) and settle it under the new title"
        fi
        changed=$QUEUE
        cmp -s "$QUEUE" "$queue_copy" || continue
        mv "$new_queue" "$QUEUE" || fail "cannot write $QUEUE"
        return 0
    done
    if [[ "$SETTLE_APPENDED" -eq 1 ]]; then
        fail "$QUEUE kept changing while settling '## $title'; it was appended to $ARCHIVE but is still in $QUEUE (run the same settle again to remove it)"
    fi
    # 最後に変わっていたファイルを伝える(判定の記録が変わっても同じ枠を使う)
    fail "$changed kept changing while settling '## $title' (3 times); nothing written"
}

# publish・adopted・unpublished・mark の名前付きの値を読む。OPT_RUN・OPT_PR_URL・OPT_BRANCH・OPT_RUN_ID に入れ、
# 渡されたものを OPT_GIVEN に「 名前 」の形で並べる。許す名前のほかの引数は exit 2
OPT_RUN='' OPT_PR_URL='' OPT_BRANCH='' OPT_RUN_ID='' OPT_GIVEN=' '
read_options() { # <許す名前(空白区切り)> <引数…>
    local allowed=" $1 "
    shift
    while [[ $# -gt 0 ]]; do
        [[ "$allowed" == *" $1 "* ]] || reject "unexpected argument '$1'"
        [[ $# -ge 2 ]] || reject "$1 needs a value"
        case $1 in
        --run) OPT_RUN=$2 ;;
        --pr-url) OPT_PR_URL=$2 ;;
        --branch) OPT_BRANCH=$2 ;;
        --run-id) OPT_RUN_ID=$2 ;;
        esac
        OPT_GIVEN+="$1 "
        shift 2
    done
}

require_option() { # <名前> <値>
    [[ "$OPT_GIVEN" == *" $1 "* ]] || reject "$1 is required"
    check_value "$1" "$2" paren
    # 印は PR になっていない採用の括弧の中なので、`PR ` で始まる値は印ではない(entries はそれを pr_url として読む)
    if [[ "$1" == --run && "$2" == 'PR '* ]]; then
        reject "--run '$2' is a PR URL verdict, not a mark (marks are the run values listed by unpublished)"
    fi
    if [[ "$1" == --branch && "$2" == 'PR '* ]]; then
        reject "--branch '$2' would make a mark read as a PR URL verdict"
    fi
    return 0
}

adopted_mode() {
    local listed
    read_options '--run' "$@"
    require_option --run "$OPT_RUN"
    listed=$(entries_mode) || exit 1
    jq -r --arg run "$OPT_RUN" 'select(.kind == "adopted" and .run == $run) | .title' <<<"$listed" ||
        fail "cannot read $ARCHIVE"
}

unpublished_mode() {
    local listed all=true
    read_options '--branch' "$@"
    if [[ "$OPT_GIVEN" == *' --branch '* ]]; then
        check_value --branch "$OPT_BRANCH" paren
        all=false
    fi
    listed=$(entries_mode) || exit 1
    jq -r --arg branch "$OPT_BRANCH" --argjson all "$all" '
        select(.kind == "adopted" and has("run")) | .run
        | select($all or . == $branch or startswith($branch + " run "))' <<<"$listed" |
        awk '!seen[$0]++' || fail "cannot read $ARCHIVE"
}

mark_mode() {
    read_options '--branch --run-id' "$@"
    require_option --branch "$OPT_BRANCH"
    require_option --run-id "$OPT_RUN_ID"
    printf '%s run %s\n' "$OPT_BRANCH" "$OPT_RUN_ID"
}

# 判定の記録を写し、印が $PUBLISH_RUN の採用の Verdict 行を置き換えて $PUBLISH_OUT に書き、置き換えた件数を出す。
# 項目と Verdict 行の決め方は entries と同じ(フェンスの中は読まない。`## ` はフェンスを閉じる。項目ごとに最初の Verdict 行)
publish_rewrite() { # <ファイル>
    awk 'BEGIN { from = "- **Verdict:** adopted (" ENVIRON["PUBLISH_RUN"] ")"; to = "- **Verdict:** adopted (PR " ENVIRON["PUBLISH_URL"] ")"; out = ENVIRON["PUBLISH_OUT"] }
        /^## / { fence = 0; inside = (length($0) > 3); seen = 0; print > out; next }
        /^ ? ? ?(```|~~~)/ { fence = !fence; print > out; next }
        fence { print > out; next }
        /^# / { inside = 0; print > out; next }
        inside && !seen && /^- \*\*Verdict:\*\* / {
            seen = 1
            if (substr($0, 1, length(from)) == from) { $0 = to substr($0, length(from) + 1); n++ }
        }
        { print > out }
        END { print n + 0 }' "$1"
}

publish_mode() {
    local copy new count
    read_options '--run --pr-url' "$@"
    require_option --run "$OPT_RUN"
    require_option --pr-url "$OPT_PR_URL"
    if [[ ! -e "$ARCHIVE" && ! -L "$ARCHIVE" ]]; then
        printf '0\n'
        return 0
    fi
    [[ -f "$ARCHIVE" && -r "$ARCHIVE" ]] || fail "cannot read $ARCHIVE"
    trap cleanup_tmp_files EXIT
    copy=$(mktemp "$HARNESS_DIR/.publish-archive.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    TMP_FILES=$copy
    new=$(mktemp "$HARNESS_DIR/.publish-new-archive.XXXXXX") || fail "cannot create a temp file in $HARNESS_DIR"
    TMP_FILES="$copy $new"
    export PUBLISH_RUN="$OPT_RUN" PUBLISH_URL="$OPT_PR_URL" PUBLISH_OUT="$new"
    for _ in 1 2 3; do
        cp "$ARCHIVE" "$copy" || fail "cannot read $ARCHIVE"
        # 置き換えるファイルの mode を保つため、元のファイルを写してから中身を書く
        cp -p "$ARCHIVE" "$new" || fail "cannot write $new"
        count=$(publish_rewrite "$copy") || fail "cannot rewrite $ARCHIVE"
        if [[ "$count" -eq 0 ]]; then
            printf '0\n'
            return 0
        fi
        cmp -s "$ARCHIVE" "$copy" || continue
        mv "$new" "$ARCHIVE" || fail "cannot write $ARCHIVE"
        printf '%s\n' "$count"
        return 0
    done
    fail "$ARCHIVE kept changing while publishing '$OPT_RUN' (3 times); nothing written"
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
publish)
    shift
    publish_mode "$@"
    ;;
mark)
    shift
    mark_mode "$@"
    ;;
adopted | unpublished)
    command -v jq >/dev/null 2>&1 || fail 'jq not found'
    mode=$1
    shift
    "${mode}_mode" "$@"
    ;;
*) usage ;;
esac
