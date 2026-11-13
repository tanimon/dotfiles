# review-verify の起動前・起動後の確認(precheck.sh / postcheck.sh)。毎回使い捨ての git リポジトリを組み、
# gh はスタブにする。検査するのはスクリプトの CLI(引数・標準出力・終了コード・書き出したファイル)だけ。
bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/setup'
    SCRIPTS="$BATS_TEST_DIRNAME/../dot_claude/skills/review-verify/scripts"
    PRECHECK="$SCRIPTS/executable_precheck.sh"
    POSTCHECK="$SCRIPTS/executable_postcheck.sh"
    unset GH_REPO GH_HOST
    export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
    : >"$GIT_CONFIG_GLOBAL"
    git config --global user.name t
    git config --global user.email t@example.com
    git config --global commit.gpgsign false
    git config --global init.defaultBranch main

    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
"pr view"*) [[ -n "${GH_PR_JSON:-}" ]] || exit 1; printf '%s' "$GH_PR_JSON" ;;
"repo view --json nameWithOwner -q .nameWithOwner") printf 'tanimon/sample\n' ;;
*)
    echo "unexpected gh $*" >&2
    exit 1
    ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    mkdir -p "$BATS_TEST_TMPDIR/repo"
    REPO=$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)
    cd "$REPO" || return 1
    git init -q
    mkdir docs
    printf '# 要件\n' >docs/spec.md
    printf 'a\n' >a.txt
    git add -A
    git commit -qm init
    git switch -qc feature
    mkdir -p "$BATS_TEST_TMPDIR/out"
    DIR=$(cd "$BATS_TEST_TMPDIR/out" && pwd -P)
}

@test "precheck: 作業ブランチで通れば Workflow に渡す要件文書と起動前の SHA を返す" {
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md
    assert_success
    head=$(git rev-parse HEAD)
    assert_equal "$(jq -r .requirementsPath <<<"$output")" "$REPO/docs/spec.md"
    assert_equal "$(jq -r .preSha <<<"$output")" "$head"
    assert_equal "$(jq -r .preSha "$DIR/state.json")" "$head"
}

@test "precheck: 保護ブランチと detached HEAD では中止し、state.json を書かない" {
    for target in main master development; do
        git switch -qC "$target"
        run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md
        assert_failure 2
        assert_equal "$output" ''
        [[ "$stderr" == *"$target"* ]]
    done
    git switch -q --detach
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md
    assert_failure 2
    [[ "$stderr" == *detached* ]]
    [[ ! -e "$DIR/state.json" ]]
}

@test "precheck: 未コミットの変更があれば中止する" {
    printf 'b\n' >>a.txt
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md
    assert_failure 2
    [[ "$stderr" == *未コミット* ]]
    [[ ! -e "$DIR/state.json" ]]
}

@test "precheck: 要件文書が無ければ中止する" {
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/missing.md
    assert_failure 2
    [[ "$stderr" == *docs/missing.md* ]]
}

pr_json() { # <headRefName> <owner> <repo|null>
    if [[ "$3" == null ]]; then
        jq -n --arg h "$1" --arg o "$2" '{headRefName: $h, headRepository: null, headRepositoryOwner: {login: $o}, body: "PR の本文"}'
    else
        jq -n --arg h "$1" --arg o "$2" --arg r "$3" '{headRefName: $h, headRepository: {name: $r}, headRepositoryOwner: {login: $o}, body: "PR の本文"}'
    fi
}

@test "precheck: --pr があれば PR 本文を連結した要件文書を作り、その sha256 を控える" {
    export GH_PR_JSON
    GH_PR_JSON=$(pr_json feature tanimon sample)
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md --pr https://github.com/tanimon/sample/pull/7
    assert_success
    assert_equal "$(jq -r .requirementsPath <<<"$output")" "$DIR/requirements.md"
    run grep -c -e '^# 要件$' -e '^## 追補: PR 本文' -e '^PR の本文$' "$DIR/requirements.md"
    assert_output 3
    assert_equal "$(jq -r .requirementsSha256 "$DIR/state.json")" "$(shasum -a 256 "$DIR/requirements.md" | cut -d' ' -f1)"
    assert_equal "$(jq -r .requirementsPath "$DIR/state.json")" "$REPO/docs/spec.md"
    assert_equal "$(jq -r .workflowRequirementsPath "$DIR/state.json")" "$DIR/requirements.md"
}

@test "precheck: PR がこのブランチ・このリポジトリのものでなければ中止する" {
    export GH_PR_JSON
    for case in 'other tanimon sample' 'feature someone sample' 'feature tanimon null'; do
        read -r h o r <<<"$case"
        GH_PR_JSON=$(pr_json "$h" "$o" "$r")
        run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md --pr https://github.com/tanimon/sample/pull/7
        assert_failure 2
        [[ ! -e "$DIR/state.json" && ! -e "$DIR/requirements.md" ]]
    done
    unset GH_PR_JSON
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md --pr https://github.com/tanimon/sample/pull/7
    assert_failure 2
    [[ "$stderr" == *gh* ]]
}

@test "precheck: 元の要件文書が連結先と同じパスなら上書きせずに中止する" {
    export GH_PR_JSON
    GH_PR_JSON=$(pr_json feature tanimon sample)
    printf '元\n' >"$DIR/requirements.md"
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements "$DIR/requirements.md" --pr https://github.com/tanimon/sample/pull/7
    assert_failure 2
    assert_equal "$(cat "$DIR/requirements.md")" '元'
}

@test "precheck: stats-issue が Issue の URL の形でなければ中止する" {
    for value in 426 '#426' https://github.com/tanimon/sample/pull/426; do
        run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md --stats-issue "$value"
        assert_failure 2
    done
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md --stats-issue https://github.com/tanimon/sample/issues/426
    assert_success
}

@test "precheck: 通ったときだけ前回の結果のファイルを消す" {
    for f in report.md ledger.json stats.md; do printf 'old\n' >"$DIR/$f"; done
    git switch -q main
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md
    assert_failure 2
    [[ -e "$DIR/report.md" && -e "$DIR/ledger.json" && -e "$DIR/stats.md" ]]
    git switch -q feature
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md
    assert_success
    [[ ! -e "$DIR/report.md" && ! -e "$DIR/ledger.json" && ! -e "$DIR/stats.md" ]]
}

# postcheck のケースは、precheck を通した後に Workflow のエージェントがコミットした状態を組む。
start_run() {
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements docs/spec.md "$@"
    assert_success
    PRE_SHA=$(git rev-parse HEAD)
}

agent_commit() { # <file> <content>
    mkdir -p "$(dirname "$1")"
    printf '%s\n' "$2" >"$1"
    git add "$1"
    git commit -qm "change $1"
}

# Workflow の出力ファイル。返り値は .result の下にあり、ledger は JSON を文字列にした値。
output_file() { # <ledger の file の JSON 配列>
    jq -n --argjson files "$1" '{summary: "s", result: {
        report: "# 報告",
        ledger: ({checksChanges: [], fixChanges: [$files[] | {label: "F1", file: ., summary: "s"}], verifyFixChanges: []} | tojson),
        stats: "統計"}}' >"$BATS_TEST_TMPDIR/output.json"
    printf '%s' "$BATS_TEST_TMPDIR/output.json"
}

@test "postcheck: 何も知らせることが無ければ結果を書き出し、足したコミットの範囲だけを出す" {
    start_run
    agent_commit src/x.txt x
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '["src/x.txt"]')"
    assert_success
    assert_output "- Workflow が足したコミット: \`${PRE_SHA}..HEAD\`"
    assert_equal "$(cat "$DIR/report.md")" '# 報告'
    assert_equal "$(jq -r '.fixChanges[0].file' "$DIR/ledger.json")" src/x.txt
    assert_equal "$(cat "$DIR/stats.md")" '統計'
}

@test "postcheck: 起動前の SHA が HEAD の祖先でなければ履歴の書き換えを知らせ、範囲を示さない" {
    start_run
    git commit -q --amend -m rewritten
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_failure 1
    assert_line --partial "履歴が書き換えられた"
    assert_line --partial "$PRE_SHA"
    refute_line --partial 'Workflow が足したコミット'
}

@test "postcheck: 要件文書を書き換えたコミットを知らせ、記録の無い変更には数えない" {
    start_run
    agent_commit docs/spec.md 'rewritten'
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_failure 1
    assert_line --partial '要件文書が書き換えられた'
    assert_line --regexp "^  - [0-9a-f]+ change docs/spec.md$"
    refute_line --partial 'Unrecorded Change'
}

@test "postcheck: 要件文書が git に追跡されていなければ、確かめられなかったことを知らせる" {
    printf '# 外の要件\n' >"$BATS_TEST_TMPDIR/outside.md"
    run --separate-stderr bash "$PRECHECK" --dir "$DIR" --requirements "$BATS_TEST_TMPDIR/outside.md"
    assert_success
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_failure 1
    assert_line --partial '確かめられなかった'
    assert_line --partial 'outside.md'
}

@test "postcheck: ledger に記録の無い変更を、変えたコミットとともに Unrecorded Change として知らせる" {
    start_run
    agent_commit src/recorded.txt r
    agent_commit src/unrecorded.txt u
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '["src/recorded.txt"]')"
    assert_failure 1
    assert_line --partial 'Unrecorded Change'
    assert_line '  - `src/unrecorded.txt`'
    assert_line --regexp '^    - [0-9a-f]+ change src/unrecorded.txt$'
    refute_line --partial 'src/recorded.txt'
}

@test "postcheck: ledger の file の ./ と、リポジトリの中を指す絶対パスは記録として認める" {
    start_run
    agent_commit src/a.txt a
    agent_commit src/b.txt b
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file "[\"./src/a.txt\", \"$REPO/src/b.txt\"]")"
    assert_success
    refute_line --partial 'Unrecorded Change'
}

@test "postcheck: pr= のとき、連結した要件文書の sha256 が控えた値と違えば(無くなっていても)知らせる" {
    export GH_PR_JSON
    GH_PR_JSON=$(pr_json feature tanimon sample)
    start_run --pr https://github.com/tanimon/sample/pull/7
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_success
    printf 'agent\n' >>"$DIR/requirements.md"
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_failure 1
    assert_line --partial 'Workflow に渡した要件文書が書き換えられた'
    rm "$DIR/requirements.md"
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_failure 1
    assert_line --partial 'Workflow に渡した要件文書が書き換えられた'
}

@test "postcheck: 未コミットの変更を、変更のあるファイルとともに知らせる" {
    start_run
    printf 'half\n' >>a.txt
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_failure 1
    assert_line --partial '未コミットの変更'
    assert_line '  - ` M a.txt`'
}

@test "postcheck: --output-file が無ければ書き出しと突き合わせを飛ばし、git の確認だけを行う" {
    start_run
    agent_commit src/x.txt x
    printf 'half\n' >>a.txt
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR"
    assert_failure 1
    assert_line --partial 'Workflow の返り値が無い'
    assert_line --partial 'ledger との突き合わせはできなかった'
    assert_line --partial '未コミットの変更'
    assert_line "- Workflow が足したコミット: \`${PRE_SHA}..HEAD\`"
    refute_line --partial 'Unrecorded Change'
    [[ ! -e "$DIR/report.md" && ! -e "$DIR/ledger.json" ]]
}

@test "postcheck: 出力ファイルに ledger が無ければ、返り値が無いものとして扱う" {
    start_run
    jq -n '{summary: "s", result: null}' >"$BATS_TEST_TMPDIR/output.json"
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$BATS_TEST_TMPDIR/output.json"
    assert_failure 1
    assert_line --partial 'Workflow の返り値が無い'
    [[ ! -e "$DIR/ledger.json" ]]
}

@test "postcheck: stats が無ければ stats.md を書かない" {
    start_run
    jq -n '{result: {report: "# 報告", ledger: ({checksChanges: [], fixChanges: [], verifyFixChanges: []} | tojson), stats: null}}' >"$BATS_TEST_TMPDIR/output.json"
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$BATS_TEST_TMPDIR/output.json"
    assert_success
    [[ -e "$DIR/report.md" && ! -e "$DIR/stats.md" ]]
}

@test "postcheck: state.json が無ければ、起動前の値を使う確認ができなかったことを知らせる" {
    printf 'half\n' >>a.txt
    run --separate-stderr bash "$POSTCHECK" --dir "$DIR" --output-file "$(output_file '[]')"
    assert_failure 1
    assert_line --partial '起動前の値'
    assert_line --partial '未コミットの変更'
    refute_line --partial 'Workflow が足したコミット'
}

@test "postcheck: 引数が足りなければ検査を実行せずに終了コード 2 を返す" {
    run --separate-stderr bash "$POSTCHECK"
    assert_failure 2
    run --separate-stderr bash "$POSTCHECK" --dir "$BATS_TEST_TMPDIR/missing"
    assert_failure 2
}
