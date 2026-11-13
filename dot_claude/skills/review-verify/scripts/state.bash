#!/usr/bin/env bash
# precheck.sh が書き、postcheck.sh が読む起動前の値(<dir>/state.json)。キー名はこのファイルにだけ書く。
# source 専用で、set は呼び出し側に従う。

review_verify_state_write() { # <dir> <起動前の SHA> <元の要件文書> <Workflow に渡す要件文書> <その sha256。pr= が無ければ空>
    jq -n --arg preSha "$2" --arg original "$3" --arg workflow "$4" --arg sha256 "$5" \
        '{preSha: $preSha, originalRequirementsPath: $original, workflowRequirementsPath: $workflow,
          workflowRequirementsSha256: (if $sha256 == "" then null else $sha256 end)}' >"$1/state.json"
}

# 読めたら次の変数に入れて 0 を返し、無いか読めなければ 1 を返す。
#   REVIEW_VERIFY_PRE_SHA / REVIEW_VERIFY_ORIGINAL_REQUIREMENTS / REVIEW_VERIFY_WORKFLOW_REQUIREMENTS /
#   REVIEW_VERIFY_WORKFLOW_REQUIREMENTS_SHA256(pr= が無かったときは空)
# shellcheck disable=SC2034 # 変数は source した側が読む
review_verify_state_read() { # <dir>
    local state="$1/state.json"
    REVIEW_VERIFY_PRE_SHA=$(jq -er '.preSha' "$state" 2>/dev/null) || return 1
    REVIEW_VERIFY_ORIGINAL_REQUIREMENTS=$(jq -er '.originalRequirementsPath' "$state") || return 1
    REVIEW_VERIFY_WORKFLOW_REQUIREMENTS=$(jq -er '.workflowRequirementsPath' "$state") || return 1
    REVIEW_VERIFY_WORKFLOW_REQUIREMENTS_SHA256=$(jq -r '.workflowRequirementsSha256 // empty' "$state") || return 1
}
