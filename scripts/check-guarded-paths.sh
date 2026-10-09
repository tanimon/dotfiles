#!/usr/bin/env bash
# 自己改善ループが作った PR が Guarded Path に触れていたら失敗する(ADR 0011)。
# 人が出した PR は判定しない。Guarded Path(Evaluator と改善ループ自身)を変えるのは人の PR だけ、という決まりを強制する。
#
# 使い方: check-guarded-paths.sh [<ブランチ名> [<base の revision>]]
#   ブランチ名の既定値は GITHUB_HEAD_REF(pull_request イベントで設定される)、
#   無ければ現在のブランチ名。
#   base の既定値は、GITHUB_HEAD_REF があれば HEAD^1(pull_request の checkout は
#   merge commit で、第 1 親が base。checkout に fetch-depth: 2 が要る)、
#   無ければ origin/main と HEAD の merge-base。
#
# 一覧の行が + で始まるディレクトリは「追加だけ許す」: ループの PR はそこへ新しいファイルを足せるが、
# 既存のファイルの変更・削除・移動は Guarded Path に触れたものとして落とす。Rule Ledger(1 ルール 1 ファイル)の
# ように、週次ジョブがループの PR で記録を足すが、ループに過去の記録を書き換えさせない置き場に使う。
#
# 終了コード: 0 = 通過、1 = ループの PR が Guarded Path に触れた、2 = 判定できない。
# ループの PR で判定できないときは通さない(fail-closed)。
#
# CI(lint.yml の guarded-paths job)は、head 側のこのスクリプトに加えて、merge commit の
# 第 1 親(base)にあるこのスクリプトを just を経由せずに実行する。ループの PR がこの
# スクリプトや一覧を書き換えても、base 側の版の判定で落ちる。
# 残存: base 側の版を実行する step も、それを含む lint.yml も head 側の版が使われる
# (pull_request の CI は head の workflow を実行する)。ループの PR が job や step を消すか
# 書き換えれば、その PR ではガードが走らない。これを止めるのは、main の ruleset が job 名
# 「Guarded paths」を required status check に指定していること(リポジトリ設定。コードの外にあり、
# このリポジトリのどの検査も確かめない)。指定されていれば、ガードが赤のときと、job を消すか改名して
# 結果が報告されないときはマージが止まる。指定が無いか別の名前を照合していると、ガードが赤でも
# マージは止まらず、照合先の名前が報告されないので全 PR が必須チェック待ちで止まる。job 名を変える
# ときは ruleset の指定も同時に変え、`gh api repos/{owner}/{repo}/rulesets` で照合先を確かめる。
# 指定されていても止まらないのは、job 名を残したまま step を書き換えて常に成功させたとき。
# lint.yml・justfile は一覧に載せてあるが、その書き換えへの保証は「差分として人のレビューに見える」ところまで。
# 残存: ループの PR かどうかはブランチ名だけで決まる。ブランチ名はループの手順が
# 指定するが、エージェントが別の名前で PR を作れば判定されない。名前を指定する手順
# (harness-review の SKILL.md)は一覧に載せてあり、ループの PR からは書き換えられない。
set -euo pipefail

# ループの PR の識別規約の正本。ループが PR を作る手順(/harness-review の SKILL.md)が
# このブランチ名を指定する。人の PR はこの prefix を使わない。
LOOP_BRANCH_PREFIX='harness/review-'
PATHS_FILE='scripts/guarded-paths.txt'

branch="${1:-${GITHUB_HEAD_REF:-}}"
if [[ -z $branch ]]; then
    branch="$(git branch --show-current)"
fi

if [[ $branch != "$LOOP_BRANCH_PREFIX"* ]]; then
    echo "guarded-paths: ${branch:-(detached)} は自己改善ループの PR ではないので判定しない"
    exit 0
fi

base="${2:-}"
if [[ -z $base ]]; then
    if [[ -n ${GITHUB_HEAD_REF:-} ]]; then
        base='HEAD^1'
    else
        base="$(git merge-base origin/main HEAD)" || {
            echo "guarded-paths: origin/main との merge-base を求められない" >&2
            exit 2
        }
    fi
fi

if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
    echo "guarded-paths: base の revision を解決できない: $base" >&2
    exit 2
fi

# 一覧は base の版から読む。head の版を読むと、一覧から行を消すループの PR が
# 消した行の分だけ素通りする。
if ! paths="$(git show "${base}:${PATHS_FILE}" 2>/dev/null)"; then
    echo "guarded-paths: base ($base) に $PATHS_FILE が無いので判定できない" >&2
    exit 2
fi

# --no-renames: 移動を「元のパスの削除 + 新しいパスの追加」として出し、Evaluator の外への移動も捕まえる
# -z: NUL 区切りで、パスを引用符やエスケープ無しにそのまま出させる。改行区切りの出力は、
# 非 ASCII のパス(core.quotePath=false で抑えられる)に加えて `"`・`\`・制御文字を含むパスを
# 引用符付きで出すので、一覧と一致しない
changed_file="$(mktemp)"
trap 'rm -f "$changed_file"' EXIT
git diff --no-ext-diff --no-renames --name-status -z "$base" HEAD >"$changed_file" || {
    echo "guarded-paths: $base と HEAD の差分を取れない" >&2
    exit 2
}

# 一覧の行は、末尾が / ならディレクトリ配下すべて、それ以外は完全一致。+ で始まる行は、
# 追加(status A)だけを許す
touches_guarded_path() {
    local status=$1 file=$2 entry
    while IFS= read -r entry; do
        entry="${entry%$'\r'}"
        [[ -z $entry || $entry == \#* ]] && continue
        if [[ $entry == +* ]]; then
            entry=${entry#+}
            [[ $status != A && $file == "$entry"* ]] && return 0
            continue
        fi
        if [[ $entry == */ ]]; then
            [[ $file == "$entry"* ]] && return 0
        else
            [[ $file == "$entry" ]] && return 0
        fi
    done <<<"$paths"
    return 1
}

violations=()
# --name-status -z の出力は「status NUL パス NUL」の繰り返し(--no-renames なので移動元と移動先の 2 つを持つ行は無い)
while IFS= read -r -d '' status && IFS= read -r -d '' file; do
    [[ -z $file ]] && continue
    if touches_guarded_path "$status" "$file"; then
        violations+=("$file")
    fi
done <"$changed_file"

if ((${#violations[@]} > 0)); then
    echo "guarded-paths: 自己改善ループの PR ($branch) が Guarded Path に触れている:"
    printf '  %s\n' "${violations[@]}"
    echo "Guarded Path は人が別の PR で変える(ADR 0011)。一覧は ${PATHS_FILE}。"
    exit 1
fi

echo "guarded-paths: 自己改善ループの PR ($branch) は Guarded Path に触れていない"
