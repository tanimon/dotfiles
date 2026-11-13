#!/usr/bin/env bash
# review-verify の起動後の確認。Workflow の返り値を書き出し、Workflow が git に残したものを、エージェントの申告
# (報告の変更の節)ではなく git から確かめる。Workflow は git を見られないので、申告と食い違う変更はここでしか見つからない。
#
# 使い方: postcheck.sh --dir <precheck.sh と同じ書き出し先> [--output-file <Workflow の出力ファイル>]
#   --output-file は Workflow ツールがエラーを返して出力ファイルが無いときは省く。
# 終了コード: 0 知らせることが無い / 1 知らせることがある / 2 確認を最後まで実行できなかった(理由は標準エラー出力)
#   どの終了コードでも、標準出力はそれまでに分かったことを書いた Markdown で、報告の先頭にそのまま置く。
set -Eeuo pipefail

# shellcheck source=dot_claude/skills/review-verify/scripts/state.bash
source "$(dirname "${BASH_SOURCE[0]}")/state.bash"

notices=''
range=''
notice() {
    notices+="- $1"$'\n'
}
flush() {
    printf '%s' "$notices"
    [[ -z "$range" ]] || printf '%s\n' "$range"
}
die() {
    flush
    printf '%s\n' "$1" >&2
    exit 2
}
# set -e のままだと予期しない失敗(読めないファイルなど)が終了コード 1 になり、「知らせることがある」と区別できない。
trap 'die "予期しない失敗で確認を中断しました(postcheck.sh の ${LINENO} 行目)"' ERR

dir=''
output_file=''
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || die "値がありません: $1"
    case "$1" in
    --dir) dir=$2 ;;
    --output-file) output_file=$2 ;;
    *) die "不明な引数: $1" ;;
    esac
    shift 2
done
[[ -n "$dir" ]] || die '使い方: postcheck.sh --dir <path> [--output-file <path>]'
[[ -d "$dir" ]] || die "書き出し先のディレクトリがありません: ${dir}"
git rev-parse --git-dir >/dev/null 2>&1 || die 'git リポジトリの中で実行してください'

# 完了通知の <result> は ledger が入るとほぼ毎回切れるので、値は常に出力ファイルから取り出す。
# 出力ファイルは {summary, result, logs, ...} で包まれ、返り値は .result の下にある。.report を直接読むと null になり、
# jq -r はそれをエラーにしないので、先に jq -e で値があることを確かめる。ledger は JSON を文字列にした値なので -r で書き出す。
# 返り値が無くても、途中までのコミットや未コミットの変更が残りうるので、git による確認は続ける。
ledger_written=false
if [[ -z "$output_file" ]] || ! jq -e '.result.ledger' "$output_file" >/dev/null 2>&1; then
    notice '**Workflow の返り値が無い**: 報告と ledger を書き出していない。ledger との突き合わせはできなかった'
else
    jq -r '.result.ledger' "$output_file" >"$dir/ledger.json"
    ledger_written=true
    if jq -e '.result.report' "$output_file" >/dev/null 2>&1; then
        jq -r '.result.report' "$output_file" >"$dir/report.md"
    else
        notice '**Workflow の報告が無い**: 返り値に report が無いので、report.md を書き出していない'
    fi
    # stats は stats-issue= を指定したときだけ投稿する。投稿するかどうかは呼び出し側が決める。
    if jq -e '.result.stats' "$output_file" >/dev/null 2>&1; then
        jq -r '.result.stats' "$output_file" >"$dir/stats.md"
    fi
fi

# 起動前の値が無ければ、それを使う確認はどれも黙って通ってしまうので、確かめられなかったと書く。
if ! review_verify_state_read "$dir"; then
    notice "**確かめられなかった**: 起動前の値(\`${dir}/state.json\`)を読めないので、履歴の書き換え・要件文書の書き換え(pr= のときの sha256 の照合を含む)・Unrecorded Change を確かめられない"
    REVIEW_VERIFY_PRE_SHA=''
    REVIEW_VERIFY_WORKFLOW_REQUIREMENTS_SHA256=''
fi
pre_sha=$REVIEW_VERIFY_PRE_SHA

# <起動前の SHA>..HEAD でそのパスを変えたコミットを、notice に続く入れ子の行にする。
commits_touching() { # <path> <indent>
    git log --format="${2}- %h %s" "$pre_sha..HEAD" -- "$1"
}

if [[ -z "$pre_sha" ]]; then
    :
elif ! git merge-base --is-ancestor "$pre_sha" HEAD 2>/dev/null; then
    # 祖先でなければ、エージェントが amend / rebase / reset で人間のコミットを書き換えたので、
    # <起動前の SHA>..HEAD を Workflow が足したコミットとして示さない。
    notice "**履歴が書き換えられた**: 起動前の SHA \`${pre_sha}\` が HEAD の祖先ではない。エージェントが amend / rebase / reset で人間のコミットを書き換えた。push 済みのブランチなら、戻すのに force push が要る"
else
    # レビューや巻き戻しの範囲を人間が辿れるように示す。
    range="- Workflow が足したコミット: \`${pre_sha}..HEAD\`"
    original=$REVIEW_VERIFY_ORIGINAL_REQUIREMENTS

    # Workflow は要件文書の書き換えをプロンプトで禁じているだけで、コードでは止められない。
    # git に追跡されていない要件文書(リポジトリの外、gitignore 済み、未追跡)は書き換えても差分に出ないので、
    # 確かめられなかったことを知らせる。黙って通すと、確かめた結果と区別できない。
    if ! git ls-files --error-unmatch -- "$original" >/dev/null 2>&1; then
        notice "**確かめられなかった**: 要件文書 \`${original}\` が git に追跡されていないので、エージェントが書き換えたかを git で確かめられない"
    else
        changed=$(git diff --name-only "$pre_sha..HEAD" -- "$original")
        if [[ -n "$changed" ]]; then
            commits=$(commits_touching "$original" '  ')
            notice "**要件文書が書き換えられた**: \`${original}\` をエージェントが変えた。変えたコミット:"$'\n'"$commits"
        fi
    fi

    # 報告の変更の節はどれもエージェントの申告なので、申告漏れは git の差分との突き合わせでしか見つからない。
    # 要件文書を突き合わせから外すのは、記録に載っていても書き換えてよい理由にはならないため(別に知らせている)。
    toplevel=$(git rev-parse --show-toplevel)
    original_rel=${original#"$toplevel"/}
    # Workflow はルートからの相対パスで書くよう指示しているが、スキーマは string なので ./x や絶対パスも来うる。
    # 表記のずれを Unrecorded Change と誤報すると、人間がこの節を読まなくなる。ルートの外を指すパスはそのまま比べる。
    if ! "$ledger_written"; then
        :
    elif ! recorded=$(jq -r --arg top "$toplevel/" '
        (.checksChanges[], .fixChanges[], .verifyFixChanges[]) | .file
        | sub("^(\\./)+"; "")
        | if startswith($top) then .[($top | length):] else . end' "$dir/ledger.json" 2>/dev/null); then
        notice "**確かめられなかった**: \`${dir}/ledger.json\` を読めないので、ledger との突き合わせはできなかった"
    else
        # core.quotePath=false で日本語などのファイル名を引用符に包ませない(包むと ledger の記録と一致しない)。
        # 改行や引用符を含むファイル名は、この設定でも包まれて一致しない。
        diff_files=$(git -c core.quotePath=false diff --name-only "$pre_sha..HEAD")
        unrecorded=''
        while IFS= read -r file; do
            [[ -n "$file" && "$file" != "$original_rel" ]] || continue
            grep -Fxq -- "$file" <<<"$recorded" && continue
            commits=$(commits_touching "$file" '    ')
            unrecorded+="  - \`${file}\`"$'\n'"${commits}"$'\n'
        done <<<"$diff_files"
        [[ -z "$unrecorded" ]] ||
            notice "**Unrecorded Change**: 差分にあって報告のどの変更の節にも載っていない変更"$'\n'"${unrecorded%$'\n'}"
    fi
fi

# pr= のとき Workflow に渡した要件文書は git の外にあり、git による確認では書き換えが見えない。
# 祖先かどうかに関わらず、precheck.sh が控えた sha256 と照合する。
expected_sha256=$REVIEW_VERIFY_WORKFLOW_REQUIREMENTS_SHA256
if [[ -n "$expected_sha256" ]]; then
    workflow_requirements=$REVIEW_VERIFY_WORKFLOW_REQUIREMENTS
    actual_sha256=''
    if [[ -f "$workflow_requirements" ]]; then
        actual_sha256=$(shasum -a 256 "$workflow_requirements")
        actual_sha256=${actual_sha256%% *}
    fi
    [[ "$actual_sha256" == "$expected_sha256" ]] ||
        notice "**Workflow に渡した要件文書が書き換えられた**: \`${workflow_requirements}\` の sha256 が起動前と違う(ファイルが無い場合も含む)"
fi

# 未コミットの変更は <起動前の SHA>..HEAD の範囲に入らないので、黙っていると人間が見落とす。
# テスト/lint や動作確認の修正を途中で諦めた場合に残る。消したりコミットしたりはせず、扱いは人間に委ねる。
status=$(git status --porcelain)
if [[ -n "$status" ]]; then
    files=''
    while IFS= read -r line; do
        files+=$'\n'"  - \`${line}\`"
    done <<<"$status"
    notice "**未コミットの変更**: Workflow のエージェントが未コミットの変更を残した。<起動前の SHA>..HEAD には入らない${files}"
fi

flush
[[ -z "$notices" ]] || exit 1
