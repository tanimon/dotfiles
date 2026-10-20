#!/usr/bin/env bash
# 週次ジョブ(harness-weekly.sh)の Integrity Snapshot。source 専用。set は呼び出し側に従う(set -euo pipefail 下で動く)。
# 決定は ADR 0019。
#
# 週次ジョブの抽出と選別の claude は --dangerously-skip-permissions で動き、~/.claude に書ける。claude の後に
# job が使うファイルを claude が書き換えると、Evaluator を偽れる。そこで claude の起動前にハッシュを取り
# (スナップショット)、使う直前に比べる。
#
# 一覧の基準: claude の起動後に job が実行する・読み込む・commit するファイルの全部。一覧の正本はこの lib の
# harness_integrity_executables と _harness_integrity_data_files だけで、週次ジョブは一覧を持たない。
# - 実行物: claude の後に job が $HOME/.claude/scripts から実行するスクリプトと、それが読む設定。推移的な依存も
#   含める(failure-rates → Failure Pattern の一覧、rule-ledger → Verdict の CLI、eval-cases → eval 専用 plugin の
#   雛形)。source される lib は claude の起動前にメモリに載るので含めない。rule-ledger が使う identity leak guard は
#   origin/main のものなので含めない。実行物は正当には変わらないので、使うたびに全部を比べる。
# - データ: job が commit するか、PR の本文や commit する記録の材料として読むもの(週の再発率の記録・Rule Ledger の
#   記録と書き出した形・分類の記録・検出件数の記録)。claude が正当に書くもの(queue・判定の記録・PR の本文・
#   選別の結果ファイル)は守れないので含めない。job 自身も claude の後に正当に書く(rule-ledger の record と export)ので、
#   使うたびには比べない。各 claude の後(job 自身が書く前)は、claude の工程を通す入口 harness_integrity_run_untrusted が
#   claude の成否に関わらず比べる。repo に写す直前・記録を作る直前・PR の本文の材料に読む直前は、呼び出し元が
#   harness_integrity_check_data で比べる。
#   信頼する入口が書いたファイル(評価の結果、record が作った記録)は harness_integrity_seal で後から一覧に足す。
#   export が書く書き出した形は封印しないので、export より後にデータを比べないこと。
# CI の Guarded Path の一覧(scripts/guarded-paths.txt)とは意味が違うので統合しない。実行物の Source がその一覧に
# 載っていることは test/harness-integrity.bats が確かめる。
#
# 改ざん(書き換え・削除・追加)と照合不能(ハッシュを取れない)、スナップショットの前の使用は、どれも
# HARNESS_INTEGRITY_FAILED(3)を返す。信頼するスクリプトが明示的に返すのは 0〜2 なので、呼び出し元はスクリプト自身の
# 失敗と区別できる(set -e で伝わる子プロセスの終了コードが 3 と重なると照合の失敗として扱われるが、安全側の誤り)。
# $( ) の中の呼び出しでも終了コードで伝わる。呼び出し元が取りこぼしても公開しないよう、
# 公開の lib(harness-publish.bash)は push と gh pr create の直前に harness_integrity_gate を呼ぶ。
#
# スナップショットはこの lib のシェル変数にだけ持つ(ファイルに置くと claude が書き換えられる)。$( ) の中で
# 封印した値は呼び出し元に戻らないので、harness_integrity_snapshot と harness_integrity_seal は $( ) の外で呼ぶ。
#
# 残存リスク:
# - 週次ジョブ本体(harness-weekly.sh)は守れない。bash はスクリプトを実行しながら読むので、claude が書き換えると
#   その run の残りの振る舞いが変わりうる。
# - 照合と実行の間、record の実行と封印の間に書き換えられたものは見つけられない。
# - 分類器の claude はスナップショットの前に走る。ツール無しで起動するので書き換えられない前提に立つ。
# - 前の週の claude が書き換えて持ち越したデータは、この run のスナップショットが正として取る。
# - 週次ジョブの run の最中に手動の /harness-reflect(harness-select-pending.sh が検出件数の記録を書く)や
#   /harness-review(Rule Ledger の記録を作る)が走ると、書き換えとして見つけてその run は PR を作らずに失敗する。
#
# Interface: HARNESS_INTEGRITY_FAILED / harness_integrity_executables / harness_integrity_snapshot /
# harness_integrity_ready / harness_integrity_run / harness_integrity_run_untrusted / harness_integrity_gate /
# harness_integrity_check_data / harness_integrity_seal / harness_integrity_sealed。
# パスは呼び出しのたびに $HOME から作る。関数は || の右や $( ) の中で呼ばれ、set -e が効かないので、失敗は明示的に返す。

HARNESS_INTEGRITY_FAILED=3
# 「<パス>\t<ハッシュか missing>」の行。スナップショットを取る前は空
_HARNESS_INTEGRITY_EXECUTABLES=""
_HARNESS_INTEGRITY_DATA=""
_HARNESS_INTEGRITY_TAKEN=0

# 実行物のパスを 1 行ずつ出す
harness_integrity_executables() {
    local scripts="$HOME/.claude/scripts"
    printf '%s\n' \
        "$scripts/harness-failure-rates.sh" \
        "$scripts/harness-failure-patterns.json" \
        "$scripts/harness-verdict.sh" \
        "$scripts/harness-rule-ledger.sh" \
        "$scripts/harness-eval-cases.sh" \
        "$scripts/harness-eval-plugin/.claude-plugin/plugin.json" \
        "$scripts/harness-eval-plugin/hooks/hooks.json"
}

# データとして比べるファイルのうち、いま在るものを 1 行ずつ出す
_harness_integrity_data_files() {
    local harness_dir="$HOME/.claude/harness" file
    for file in "$harness_dir"/failure-pattern-rates/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].json \
        "$harness_dir"/rule-ledger/*.json "$harness_dir"/rule-ledger/exported/*.json \
        "$harness_dir/classifications.jsonl" "$harness_dir/detections.jsonl"; do
        [[ -f "$file" ]] && printf '%s\n' "$file"
    done
    return 0
}

# <パス>\t<ハッシュか missing> を出す。在るのにハッシュを取れなければ 1 を返す
_harness_integrity_digest() { # <パス>
    local digest
    if [[ ! -e "$1" && ! -L "$1" ]]; then
        printf '%s\tmissing\n' "$1"
        return 0
    fi
    digest=$(git hash-object -- "$1" 2>/dev/null) || return 1
    [[ -n "$digest" ]] || return 1
    printf '%s\t%s\n' "$1" "$digest"
}

# パスの一覧(stdin)の「<パス>\t<ハッシュか missing>」を出す。ハッシュを取れないパスがあれば、その旨を出して 3 を返す
_harness_integrity_digests() {
    local path line out=""
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        if ! line=$(_harness_integrity_digest "$path"); then
            printf 'harness-integrity: could not hash %s; it cannot be verified\n' "$path" >&2
            _harness_integrity_remedy
            return "$HARNESS_INTEGRITY_FAILED"
        fi
        out+="$line"$'\n'
    done
    printf '%s' "$out"
}

# 1 通りの文面。<対象> はメッセージの主語、<前>・<後> は「<パス>\t<ハッシュか missing>」の行(ハッシュは出さない)
_harness_integrity_report() { # <対象> <前> <後>
    local path digest before
    printf 'harness-integrity: %s changed after the claude runs started; not trusted:\n' "$1" >&2
    while IFS=$'\t' read -r path digest; do
        [[ -n "$path" ]] || continue
        before=$(awk -F'\t' -v p="$path" '$1 == p { print $2; exit }' <<<"$2")
        if [[ -z "$before" || "$before" == missing ]] && [[ "$digest" != missing ]]; then
            printf '  added: %s\n' "$path" >&2
        elif [[ "$digest" == missing && "$before" != missing ]]; then
            printf '  missing: %s\n' "$path" >&2
        elif [[ "$digest" != "$before" ]]; then
            printf '  changed: %s\n' "$path" >&2
        fi
    done <<<"$3"
    _harness_integrity_remedy
}

_harness_integrity_remedy() {
    printf 'harness-integrity: restore the scripts with chezmoi apply (data under ~/.claude/harness is not restored by it; check it by hand), and find what changed them before rerunning\n' >&2
}

_harness_integrity_require_snapshot() {
    [[ "$_HARNESS_INTEGRITY_TAKEN" == 1 ]] && return 0
    printf 'harness-integrity: used before the snapshot was taken (call harness_integrity_snapshot before the claude runs start)\n' >&2
    return "$HARNESS_INTEGRITY_FAILED"
}

# 現在のデータの「<パス>\t<ハッシュか missing>」を出す。スナップショットに在るパスと、いま在るパスの和
_harness_integrity_current_data() {
    { _harness_integrity_data_files && cut -f1 <<<"$_HARNESS_INTEGRITY_DATA"; } | LC_ALL=C sort -u | _harness_integrity_digests
}

# claude の起動前に 1 回呼び、実行物とデータのハッシュを取る。ハッシュを取れなければ 3 を返す
harness_integrity_snapshot() {
    local executables data
    executables=$(harness_integrity_executables | _harness_integrity_digests) || return "$HARNESS_INTEGRITY_FAILED"
    data=$(_harness_integrity_data_files | LC_ALL=C sort -u | _harness_integrity_digests) || return "$HARNESS_INTEGRITY_FAILED"
    _HARNESS_INTEGRITY_EXECUTABLES=$executables
    _HARNESS_INTEGRITY_DATA=$data
    _HARNESS_INTEGRITY_TAKEN=1
}

# スナップショットを取った後なら 0
harness_integrity_ready() {
    [[ "$_HARNESS_INTEGRITY_TAKEN" == 1 ]]
}

# 実行物の全部をスナップショットと比べる。公開(push と gh pr create)の直前に呼ぶ関門で、入口も実行の直前に呼ぶ
harness_integrity_gate() {
    local current
    _harness_integrity_require_snapshot || return "$HARNESS_INTEGRITY_FAILED"
    current=$(harness_integrity_executables | _harness_integrity_digests) || return "$HARNESS_INTEGRITY_FAILED"
    [[ "$current" == "$_HARNESS_INTEGRITY_EXECUTABLES" ]] && return 0
    _harness_integrity_report 'the scripts the weekly job runs after claude' "$_HARNESS_INTEGRITY_EXECUTABLES" "$current"
    return "$HARNESS_INTEGRITY_FAILED"
}

# 信頼して実行する入口。<スクリプト> が実行物の一覧にあり、実行物の全部がスナップショットと一致すれば
# bash <スクリプト> <引数…> を実行して、その終了コードを返す。照合に落ちたら実行せずに 3 を返す
harness_integrity_run() { # <スクリプト> [<引数>…]
    local script=${1:-} executables
    executables=$(harness_integrity_executables) || return "$HARNESS_INTEGRITY_FAILED"
    if ! grep -qxF -- "$script" <<<"$executables"; then
        printf 'harness-integrity: %s is not in the list of trusted executables; not run\n' "$script" >&2
        return "$HARNESS_INTEGRITY_FAILED"
    fi
    harness_integrity_gate || return "$HARNESS_INTEGRITY_FAILED"
    shift
    bash "$script" "$@"
}

# 信頼しない工程(抽出と選別の claude)の入口。<コマンド> を実行し、成否に関わらずその後でデータの全部を比べる。
# 照合に落ちたら 3、コマンドが失敗したら 1(コマンド自身の 3 も 1 に揃え、3 は照合の失敗だけにする)、どちらも無ければ 0。
# スナップショットの前なら実行せずに 3 を返す。今の照合はシェル変数を読むだけだが、照合が状態を書く形(seal のような
# 一覧への追加)に変わっても結果が呼び出し元に残るよう、snapshot・seal と同じく $( ) とサブシェルの外で呼ぶ。
# <コマンド> はサブシェルで走らせる。コマンドが exit や set -u の中断でシェルごと終わっても照合まで進むようにするため
# (親のシェルで走らせると照合が飛び、bash 3.2 では EXIT trap がある run は exit 0 で終わりうる)。そのためコマンドは
# 呼び出し元の変数や作業ディレクトリを変えられない
harness_integrity_run_untrusted() { # <コマンド> [<引数>…]
    local status=0
    _harness_integrity_require_snapshot || return "$HARNESS_INTEGRITY_FAILED"
    ("$@") || status=$?
    harness_integrity_check_data || return "$HARNESS_INTEGRITY_FAILED"
    [[ "$status" -eq 0 ]] || return 1
}

# データの全部をスナップショット(封印したものを含む)と比べる。呼ぶ時点はこの lib のヘッダの「データ」の項
harness_integrity_check_data() {
    local current
    _harness_integrity_require_snapshot || return "$HARNESS_INTEGRITY_FAILED"
    current=$(_harness_integrity_current_data) || return "$HARNESS_INTEGRITY_FAILED"
    [[ "$current" == "$_HARNESS_INTEGRITY_DATA" ]] && return 0
    _harness_integrity_report 'the records the weekly job commits or reads' "$_HARNESS_INTEGRITY_DATA" "$current"
    return "$HARNESS_INTEGRITY_FAILED"
}

# 信頼する入口が書いたファイルを、いまの内容でデータの一覧に足す(既に在れば置き換える)。$( ) の外で呼ぶ
harness_integrity_seal() { # <パス>
    local line
    _harness_integrity_require_snapshot || return "$HARNESS_INTEGRITY_FAILED"
    if [[ ! -f "$1" ]] || ! line=$(_harness_integrity_digest "$1"); then
        printf 'harness-integrity: could not hash %s; not sealed\n' "$1" >&2
        return "$HARNESS_INTEGRITY_FAILED"
    fi
    _HARNESS_INTEGRITY_DATA=$({
        awk -F'\t' -v p="$1" '$1 != p' <<<"$_HARNESS_INTEGRITY_DATA"
        printf '%s\n' "$line"
    } | sed '/^$/d' | LC_ALL=C sort -u)
}

# <パス> が封印されたか、スナップショットのデータに在れば 0
harness_integrity_sealed() { # <パス>
    [[ "$_HARNESS_INTEGRITY_TAKEN" == 1 ]] || return 1
    awk -F'\t' -v p="$1" '$1 == p { found = 1 } END { exit !found }' <<<"$_HARNESS_INTEGRITY_DATA"
}
