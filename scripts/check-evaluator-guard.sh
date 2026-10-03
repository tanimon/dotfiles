#!/usr/bin/env bash
# 自己改善ループが作った PR が Evaluator のパスに触れていたら失敗する(ADR 0011)。
# 人が出した PR は判定しない。Evaluator を変えるのは人の PR だけ、という決まりを強制する。
#
# 使い方: check-evaluator-guard.sh [<ブランチ名> [<base の revision>]]
#   ブランチ名の既定値は GITHUB_HEAD_REF(pull_request イベントで設定される)、
#   無ければ現在のブランチ名。
#   base の既定値は、GITHUB_HEAD_REF があれば HEAD^1(pull_request の checkout は
#   merge commit で、第 1 親が base。checkout に fetch-depth: 2 が要る)、
#   無ければ origin/main と HEAD の merge-base。
#
# 終了コード: 0 = 通過、1 = ループの PR が Evaluator に触れた、2 = 判定できない。
# ループの PR で判定できないときは通さない(fail-closed)。
#
# 残存: pull_request の CI は head 側のこのスクリプトを実行するので、ループの PR が
# このスクリプト自体を書き換えると、その PR では書き換え後の判定が走る。base 側の版を
# 実行する仕組みは持たず、このスクリプトを一覧に載せて、書き換えが人のレビューに
# 差分として見えることまでを保証とする。
# 残存: ループの PR かどうかはブランチ名だけで決まる。ブランチ名はループの手順が
# 指定するが、エージェントが別の名前で PR を作れば判定されない。
set -euo pipefail

# ループの PR の識別規約の正本。ループが PR を作る手順(/harness-review の SKILL.md)が
# このブランチ名を指定する。人の PR はこの prefix を使わない。
LOOP_BRANCH_PREFIX='harness/review-'
PATHS_FILE='scripts/evaluator-paths.txt'

branch="${1:-${GITHUB_HEAD_REF:-}}"
if [[ -z $branch ]]; then
    branch="$(git branch --show-current)"
fi

if [[ $branch != "$LOOP_BRANCH_PREFIX"* ]]; then
    echo "evaluator-guard: ${branch:-(detached)} は自己改善ループの PR ではないので判定しない"
    exit 0
fi

base="${2:-}"
if [[ -z $base ]]; then
    if [[ -n ${GITHUB_HEAD_REF:-} ]]; then
        base='HEAD^1'
    else
        base="$(git merge-base origin/main HEAD)" || {
            echo "evaluator-guard: origin/main との merge-base を求められない" >&2
            exit 2
        }
    fi
fi

if ! git rev-parse --verify --quiet "${base}^{commit}" >/dev/null; then
    echo "evaluator-guard: base の revision を解決できない: $base" >&2
    exit 2
fi

# 一覧は base の版から読む。head の版を読むと、一覧から行を消すループの PR が
# 消した行の分だけ素通りする。
if ! paths="$(git show "${base}:${PATHS_FILE}" 2>/dev/null)"; then
    echo "evaluator-guard: base ($base) に $PATHS_FILE が無いので判定できない" >&2
    exit 2
fi

# --no-renames: 移動を「元のパスの削除 + 新しいパスの追加」として出し、Evaluator の外への移動も捕まえる
# core.quotePath=false: 既定では非 ASCII のパスが引用符付きの 8 進表記で出て、一覧と一致しない
changed="$(git -c core.quotePath=false diff --no-ext-diff --no-renames --name-only "$base" HEAD)" || {
    echo "evaluator-guard: $base と HEAD の差分を取れない" >&2
    exit 2
}

# 一覧の行は、末尾が / ならディレクトリ配下すべて、それ以外は完全一致
touches_evaluator() {
    local file=$1 entry
    while IFS= read -r entry; do
        entry="${entry%$'\r'}"
        [[ -z $entry || $entry == \#* ]] && continue
        if [[ $entry == */ ]]; then
            [[ $file == "$entry"* ]] && return 0
        else
            [[ $file == "$entry" ]] && return 0
        fi
    done <<<"$paths"
    return 1
}

violations=()
while IFS= read -r file; do
    [[ -z $file ]] && continue
    if touches_evaluator "$file"; then
        violations+=("$file")
    fi
done <<<"$changed"

if ((${#violations[@]} > 0)); then
    echo "evaluator-guard: 自己改善ループの PR ($branch) が Evaluator のパスに触れている:"
    printf '  %s\n' "${violations[@]}"
    echo "Evaluator は人が別の PR で変える(ADR 0011)。一覧は ${PATHS_FILE}。"
    exit 1
fi

echo "evaluator-guard: 自己改善ループの PR ($branch) は Evaluator のパスに触れていない"
