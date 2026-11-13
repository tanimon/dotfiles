#!/usr/bin/env bash
# review-verify の起動前の確認。Workflow は実行中に質問できず、エージェントの申告も信用しないので、
# 入力だけで結果が決まる検査はここで行い、起動後の確認(postcheck.sh)が使う値を --dir の state.json に残す。
#
# 使い方: precheck.sh --dir <書き出し先> --requirements <要件文書> [--pr <PR の URL>] [--stats-issue <Issue の URL>]
# 終了コード: 0 検査を通った(標準出力に {requirementsPath, preSha} の JSON) / 2 中止(理由は標準エラー出力)
#
# state.json と連結した requirements.md は同じ --dir に置くので、Workflow のエージェントが両方を書き換えると
# postcheck.sh の sha256 の照合を通ってしまう。この残存は受け入れている(控えた値を会話に置いていても守りは変わらない)。
set -euo pipefail

# shellcheck source=dot_claude/skills/review-verify/scripts/lib.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.bash"

dir=''
requirements=''
pr=''
stats_issue=''
while [[ $# -gt 0 ]]; do
    [[ $# -ge 2 ]] || review_verify_die "値がありません: $1"
    case "$1" in
    --dir) dir=$2 ;;
    --requirements) requirements=$2 ;;
    --pr) pr=$2 ;;
    --stats-issue) stats_issue=$2 ;;
    *) review_verify_die "不明な引数: $1" ;;
    esac
    shift 2
done
[[ -n "$dir" && -n "$requirements" ]] || review_verify_die '使い方: precheck.sh --dir <path> --requirements <path> [--pr <url>] [--stats-issue <url>]'
[[ -d "$dir" ]] || review_verify_die "書き出し先のディレクトリがありません: ${dir}"

# 番号だけ(426 や #426)だと、gh はカレントのリポジトリの同じ番号の Issue に投稿する。
if [[ -n "$stats_issue" && ! "$stats_issue" =~ ^https://github\.com/[^/]+/[^/]+/issues/[0-9]+$ ]]; then
    review_verify_die "stats-issue は https://github.com/<owner>/<repo>/issues/<番号> の形の URL で渡してください: ${stats_issue}"
fi

branch=$(git rev-parse --abbrev-ref HEAD) || review_verify_die 'git リポジトリの中で実行してください'
case "$branch" in
HEAD) review_verify_die 'detached HEAD では実行できません。作業ブランチに切り替えてください(worktree やブランチはこちらで作りません)' ;;
main | master | development) review_verify_die "保護ブランチ ${branch} の上では実行できません。作業ブランチに切り替えてください(worktree やブランチはこちらで作りません)" ;;
esac

# 未コミットの変更は修正エージェントのコミットに混ざる。
status=$(git status --porcelain) || review_verify_die 'git status に失敗しました'
[[ -z "$status" ]] || review_verify_die "未コミットの変更があります。コミットするか退避してから実行してください:
${status}"

[[ -f "$requirements" ]] || review_verify_die "要件文書がありません: ${requirements}"
pre_sha=$(git rev-parse HEAD)
# 物理パスにする。git に渡す絶対パスがシンボリックリンクを経由すると、リポジトリの外と判定される。
requirements_abs="$(cd "$(dirname "$requirements")" && pwd -P)/$(basename "$requirements")"
dir_abs=$(cd "$dir" && pwd -P)
workflow_requirements=$requirements_abs
sha256=''

if [[ -n "$pr" ]]; then
    workflow_requirements="$dir_abs/requirements.md"
    [[ "$requirements_abs" != "$workflow_requirements" ]] ||
        review_verify_die "元の要件文書が PR 本文の連結先と同じパスです。上書きで中身を失うので、別の場所の要件文書を渡してください: ${requirements_abs}"
    # PR 本文は、開発者が書いた要件文書からの意図した逸脱をレビューが「直して」しまわないために読む。
    # 別の PR の本文を正本にしないよう、ブランチ名に加えてリポジトリも照合する。ブランチ名だけでは、
    # 共有ライブラリと利用側のリポジトリに同じ名前のブランチを作るフローで別のリポジトリの PR を通してしまう。
    # フォークの clone で gh が上流を指すときもここで止まる。
    pr_json=$(gh pr view "$pr" --json headRefName,headRepository,headRepositoryOwner,body) ||
        review_verify_die "gh pr view に失敗しました: ${pr}"
    this_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner) ||
        review_verify_die 'gh repo view に失敗しました'
    head_ref=$(jq -r '.headRefName' <<<"$pr_json")
    head_repo=$(jq -r 'if .headRepository == null then "" else "\(.headRepositoryOwner.login)/\(.headRepository.name)" end' <<<"$pr_json")
    [[ "$head_ref" == "$branch" ]] ||
        review_verify_die "PR の head ブランチ ${head_ref} が今のブランチ ${branch} と一致しません: ${pr}"
    [[ "$head_repo" == "$this_repo" ]] ||
        review_verify_die "PR の head リポジトリ ${head_repo:-(不明)} がこのリポジトリ ${this_repo} と一致しません: ${pr}"
    body=$(jq -r '.body' <<<"$pr_json")
    original=$(cat "$requirements_abs") || review_verify_die "要件文書を読めません: ${requirements_abs}"
    printf '%s\n\n## 追補: PR 本文(要件文書からの意図した逸脱・既知の挙動と明示した記述に限り、要件文書より優先する)\n\n%s\n' \
        "$original" "$body" >"$workflow_requirements"
    # このファイルは git の外にあり、postcheck.sh の git による確認では書き換えが見えない。
    sha256=$(shasum -a 256 "$workflow_requirements" | cut -d' ' -f1)
fi

# 前回の実行の結果が残っていると、今回の Workflow が値を返さずに終わったときに今回の結果として読まれうる。
rm -f "$dir_abs/report.md" "$dir_abs/ledger.json" "$dir_abs/stats.md"

jq -n --arg preSha "$pre_sha" --arg requirementsPath "$requirements_abs" \
    --arg workflowRequirementsPath "$workflow_requirements" --arg requirementsSha256 "$sha256" \
    '{preSha: $preSha, requirementsPath: $requirementsPath, workflowRequirementsPath: $workflowRequirementsPath,
      requirementsSha256: (if $requirementsSha256 == "" then null else $requirementsSha256 end)}' \
    >"$(review_verify_state_path "$dir_abs")"
jq -n --arg requirementsPath "$workflow_requirements" --arg preSha "$pre_sha" \
    '{requirementsPath: $requirementsPath, preSha: $preSha}'
