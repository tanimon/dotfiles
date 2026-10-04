# ticket スキル Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 個人リポジトリで issue / PR を作るときに、関連 issue のメンション、native relationship、`Closes #N`、AC 対応表を漏らさないようにする。マージ後に残った漏れは手動で洗い出して直せるようにする。

**Architecture:** 手順の正本はグローバルスキル `ticket` に置き、作成モードと照合モードを持たせる。PreToolUse フック `ticket-guard.sh` は、範囲内のリポジトリでの `gh issue create` / `gh pr create` のうち、本文にマーカー `<!-- ticket-skill -->` が無いものを deny する。範囲(origin の owner の許可リスト)は `lib/ticket-scope.bash` で判定し、ガードと deliver が共有する。照合モードの検出は `audit.sh` が決定的に行う。

**Tech Stack:** bash(3.2 互換)、jq、gh CLI、bats(bats-assert)、Node の `node:test`(deliver.js)、chezmoi テンプレート

**Spec:** `docs/superpowers/specs/2026-10-04-ticket-skill-design.md`

## Global Constraints

- マーカーの文字列は `<!-- ticket-skill -->` で固定する(ガード・スキル・deliver.js で同じ文字列を使う)
- owner の許可リストの既定値は `tanimon`。環境変数 `TICKET_GUARD_OWNERS`(空白区切り)で上書きできる。空文字に設定すると、どのリポジトリも範囲外になる
- ガードが返すのは `deny` か無出力だけ。`allow` / `ask` は返さない
- `dot_claude/scripts/CLAUDE.md` には書き足さない(サイズ上限に余白が 3 バイトしかない。#449)
- 仕事 org 名とローカルのアカウント名をファイルに書かない(`just scan-sensitive` が検査する)
- シェルスクリプトは bash 3.2 で動くこと(`${var,,}` や連想配列を使わない)
- `gh api` のコマンドは、エンドポイントを最初の引数に書く(`gh api repos/... -X POST ...`)
- 検証は手組みのコマンドではなく `just` のレシピで行う(`just test-scripts` / `just test-settings-hooks` / `just test-deliver` / `just lint`)
- コメント・ドキュメント・コミットメッセージは日本語で書く

## Review Focus

1. コミットメッセージの heredoc の中に `gh pr create` で始まる行がある → ガードは何もしない(Task 2 にテストあり)
2. `--body "$(cat <<'EOF' … <!-- ticket-skill --> … EOF)"` の形で本文をインラインに渡す(Claude がよく使う形) → 通る(Task 2 にテストあり)
3. 仕事リポジトリ、または origin が無いディレクトリで `gh pr create` を実行する → ガードは何もしない(Task 1・2 にテストあり)
4. AC の見出しが `## 完了条件(案)` のような揺れた形 → 照合で検出する(Task 4 にテストあり)
5. マージ済み PR の `closingIssuesReferences` に別リポジトリの issue が入っている → 照合の対象にしない(Task 4 にテストあり)

---

### Task 1: 適用範囲の判定ライブラリ

**Files:**
- Create: `dot_claude/scripts/lib/ticket-scope.bash`
- Test: `test/ticket-scope.bats`
- Modify: `justfile`(`test-scripts` レシピに `test/ticket-scope.bats` を足す)

**Interfaces:**
- Produces: `ticket_scope_in_scope <dir> [<repo>]`。範囲内なら 0、範囲外・判定不能なら 1 を返す。`<repo>` は `owner/name`、`github.com/owner/name`、`https://github.com/owner/name` のいずれか。空なら `<dir>` の origin を見る。ファイルを直接実行した場合(`bash ticket-scope.bash <dir> [<repo>]`)は、同じ判定を終了コードで返す。

- [ ] **Step 1: 失敗するテストを書く**

`test/ticket-scope.bats`:

```bash
# ticket スキルとガードの適用範囲(origin の owner の許可リスト)の判定。
setup() {
    load 'helpers/setup'
    LIB="$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/ticket-scope.bash"
    unset TICKET_GUARD_OWNERS
    REPO_DIR="$BATS_TEST_TMPDIR/repo"
    git init -q "$REPO_DIR"
}

set_origin() {
    git -C "$REPO_DIR" remote add origin "$1"
}

@test "許可リストの owner の https origin は範囲内" {
    set_origin https://github.com/tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "許可リストの owner の ssh origin は範囲内" {
    set_origin git@github.com:tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "owner の大文字小文字は区別しない" {
    set_origin https://github.com/Tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "許可リストに無い owner は範囲外" {
    set_origin https://github.com/someone-else/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "origin が無いリポジトリは範囲外" {
    run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "GitHub 以外の origin は範囲外" {
    set_origin https://gitlab.com/tanimon/sample.git
    run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "git リポジトリでないディレクトリは範囲外" {
    run bash "$LIB" "$BATS_TEST_TMPDIR"
    assert_failure
}

@test "repo 引数があれば origin より優先する(範囲外の指定)" {
    set_origin https://github.com/tanimon/sample.git
    run bash "$LIB" "$REPO_DIR" someone-else/sample
    assert_failure
}

@test "repo 引数があれば origin より優先する(範囲内の指定)" {
    set_origin https://github.com/someone-else/sample.git
    run bash "$LIB" "$REPO_DIR" https://github.com/tanimon/sample
    assert_success
}

@test "TICKET_GUARD_OWNERS で許可リストを上書きできる" {
    set_origin https://github.com/someone-else/sample.git
    TICKET_GUARD_OWNERS="other someone-else" run bash "$LIB" "$REPO_DIR"
    assert_success
}

@test "TICKET_GUARD_OWNERS を空にするとすべて範囲外" {
    set_origin https://github.com/tanimon/sample.git
    TICKET_GUARD_OWNERS="" run bash "$LIB" "$REPO_DIR"
    assert_failure
}

@test "source して関数として呼べる" {
    set_origin https://github.com/tanimon/sample.git
    run bash -c 'source "$1" && ticket_scope_in_scope "$2"' _ "$LIB" "$REPO_DIR"
    assert_success
}
```

`justfile` の `test-scripts` レシピの bats の引数の末尾に `test/ticket-scope.bats` を足す。

- [ ] **Step 2: 失敗を確かめる**

Run: `LC_ALL=C pnpm exec bats test/ticket-scope.bats`
Expected: すべて FAIL(`ticket-scope.bash` が無い)

- [ ] **Step 3: 実装する**

`dot_claude/scripts/lib/ticket-scope.bash`:

```bash
#!/usr/bin/env bash
# ticket スキルとガードの適用範囲を判定する。範囲は origin の owner の許可リストで決める。
# source して ticket_scope_in_scope を呼ぶか、直接実行して終了コードを見る
# (bash ticket-scope.bash <dir> [<repo>])。
#
# 許可リストは TICKET_GUARD_OWNERS(空白区切り)。既定値に書くのは公開済みの個人アカウント名だけ。
# 仕事 org の除外リストにしないのは、org 名を public リポジトリに書けないうえ、OSS への PR まで
# 範囲に入ってしまうため。

# ticket_scope_in_scope <dir> [<repo>]: 範囲内なら 0、範囲外・判定不能なら 1。
# <repo> は owner/name・github.com/owner/name・https://github.com/owner/name。空なら <dir> の origin を見る。
ticket_scope_in_scope() {
    local dir=${1:-.} repo=${2:-} url owner allowed
    if [[ -z "$repo" ]]; then
        url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
        case "$url" in
        https://github.com/*) repo=${url#https://github.com/} ;;
        git@github.com:*) repo=${url#git@github.com:} ;;
        ssh://git@github.com/*) repo=${url#ssh://git@github.com/} ;;
        *) return 1 ;;
        esac
    else
        repo=${repo#https://}
        repo=${repo#github.com/}
    fi
    owner=${repo%%/*}
    [[ -n "$owner" && "$owner" != "$repo" ]] || return 1
    owner=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
    for allowed in ${TICKET_GUARD_OWNERS-tanimon}; do
        allowed=$(printf '%s' "$allowed" | tr '[:upper:]' '[:lower:]')
        [[ "$owner" == "$allowed" ]] && return 0
    done
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    ticket_scope_in_scope "${1:-.}" "${2:-}"
    exit $?
fi
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `LC_ALL=C pnpm exec bats test/ticket-scope.bats`
Expected: 12 tests, 0 failures

- [ ] **Step 5: lint を通してコミットする**

Run: `just shellcheck && just shfmt`
Expected: どちらも成功

```bash
git add dot_claude/scripts/lib/ticket-scope.bash test/ticket-scope.bats justfile
git commit -m "feat(ticket): 適用範囲を origin の owner の許可リストで判定するライブラリを追加する"
```

---

### Task 2: 作成時ガード `ticket-guard.sh`

**Files:**
- Create: `dot_claude/scripts/executable_ticket-guard.sh`
- Test: `test/ticket-guard.bats`
- Modify: `justfile`(`test-scripts` に `test/ticket-guard.bats` を足す)

**Interfaces:**
- Consumes: `ticket_scope_in_scope <dir> [<repo>]`(Task 1)、`dot_claude/scripts/lib/shell-reader.bash` の `shell_reader_read` / `shell_reader_each_segment` と各 `SHELL_READER_*` の global(各関数の直前のコメントに定義がある)
- Produces: PreToolUse の stdin(`{tool_name, tool_input:{command}, cwd}`)を読み、deny の JSON を出すか無出力で終わる。理由文は `ticket-guard:` で始まる。

- [ ] **Step 1: 失敗するテストを書く**

`test/ticket-guard.bats`:

```bash
# ticket-guard: 範囲内のリポジトリで、マーカーの無い gh issue/pr create を deny する。
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/scripts/executable_ticket-guard.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset TICKET_GUARD_OWNERS
    REPO_DIR="$BATS_TEST_TMPDIR/repo"
    git init -q "$REPO_DIR"
    git -C "$REPO_DIR" remote add origin https://github.com/tanimon/sample.git
    BODY_DIR="$BATS_TEST_TMPDIR/body"
    mkdir -p "$BODY_DIR"
    MARKER='<!-- ticket-skill -->'
}

# Claude Code と同じく、判定のすべてを stdin の PreToolUse payload から得る。
hook() {
    jq -n --arg c "$1" --arg d "${2:-$REPO_DIR}" \
        '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' | bash "$SCRIPT"
}

decision() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'
}

reason() {
    printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'
}

# --- 対: マーカーの有無 ---

@test "body-file にマーカーがある pr create は通す" {
    printf 'body\n\n%s\n' "$MARKER" >"$BODY_DIR/pr.md"
    run hook "gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    assert_output ''
}

@test "body-file にマーカーが無い pr create は deny" {
    printf 'body\n' >"$BODY_DIR/pr.md"
    run hook "gh pr create --title t --body-file $BODY_DIR/pr.md"
    assert_success
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == ticket-guard:* ]]
}

@test "--body にマーカーがある issue create は通す" {
    run hook "gh issue create --title t --body 'x $MARKER'"
    assert_success
    assert_output ''
}

@test "--body にマーカーが無い issue create は deny" {
    run hook "gh issue create --title t --body 'x'"
    assert_success
    [ "$(decision "$output")" = deny ]
}

@test "-F 短縮形と --body-file= 形も読む" {
    printf '%s\n' "$MARKER" >"$BODY_DIR/i.md"
    run hook "gh issue create -t t -F $BODY_DIR/i.md"
    assert_output ''
    run hook "gh issue create -t t --body-file=$BODY_DIR/i.md"
    assert_output ''
}

@test "heredoc で本文を渡してもマーカーがあれば通す" {
    run hook "gh pr create --title t --body \"\$(cat <<'EOF'
本文
$MARKER
EOF
)\""
    assert_success
    assert_output ''
}

@test "--fill はマーカーが無いので deny" {
    run hook "gh pr create --fill"
    [ "$(decision "$output")" = deny ]
}

# --- 対: 範囲 ---

@test "許可リスト外の origin では何もしない" {
    git -C "$REPO_DIR" remote set-url origin https://github.com/someone-else/sample.git
    run hook "gh pr create --title t --body x"
    assert_success
    assert_output ''
}

@test "-R で範囲外のリポジトリを指せば何もしない" {
    run hook "gh pr create -R someone-else/sample --title t --body x"
    assert_output ''
}

@test "-R で範囲内のリポジトリを指せば cwd が範囲外でも判定する" {
    git -C "$REPO_DIR" remote set-url origin https://github.com/someone-else/sample.git
    run hook "gh pr create --repo tanimon/sample --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "git リポジトリでない cwd では何もしない" {
    run hook "gh pr create --title t --body x" "$BATS_TEST_TMPDIR"
    assert_output ''
}

# --- 読めない body-file ---

@test "body-file が相対パスなら理由付きで deny" {
    run hook "gh pr create --title t --body-file pr.md"
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *絶対パス* ]]
}

@test "body-file が変数を含むなら理由付きで deny" {
    run hook 'gh pr create --title t --body-file "$TMPDIR/pr.md"'
    [ "$(decision "$output")" = deny ]
    [[ "$(reason "$output")" == *変数* ]]
}

@test "body-file が標準入力なら deny" {
    run hook "gh pr create --title t --body-file -"
    [ "$(decision "$output")" = deny ]
}

@test "body-file が存在しなければ deny" {
    run hook "gh pr create --title t --body-file $BODY_DIR/missing.md"
    [ "$(decision "$output")" = deny ]
}

# --- 作成コマンドではないもの ---

@test "連結された作成コマンドも判定する" {
    run hook "cd $REPO_DIR && git push && gh pr create --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "VAR=value の前置があっても判定する" {
    run hook "GH_PROMPT_DISABLED=1 gh issue create --title t --body x"
    [ "$(decision "$output")" = deny ]
}

@test "gh pr edit は対象外" {
    run hook "gh pr edit 1 --body x"
    assert_output ''
}

@test "引用符の中の gh pr create は対象外" {
    run hook 'git commit -m "gh pr create を直す"'
    assert_output ''
}

@test "heredoc の本文の行にある gh pr create は対象外" {
    run hook "git commit -F - <<'EOF'
gh pr create --title t
EOF"
    assert_output ''
}

@test "gh を含まないコマンドは無出力" {
    run hook "ls -la"
    assert_output ''
}

@test "引用符が閉じないコマンドは判定せず通す" {
    run hook "gh pr create --title 't"
    assert_output ''
}
```

`justfile` の `test-scripts` レシピの bats の引数の末尾に `test/ticket-guard.bats` を足す。

- [ ] **Step 2: 失敗を確かめる**

Run: `LC_ALL=C pnpm exec bats test/ticket-guard.bats`
Expected: FAIL(スクリプトが無い)。無出力を期待するテストも、`bash` がファイルを開けずに出力を出して失敗する

- [ ] **Step 3: 実装する**

`dot_claude/scripts/executable_ticket-guard.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse hook: 個人リポジトリでの `gh issue create` / `gh pr create` を、ticket スキルの作成モードを
# 経た本文(マーカー `<!-- ticket-skill -->` を含む)でなければ deny する。
# 設計: chezmoi リポジトリの docs/superpowers/specs/2026-10-04-ticket-skill-design.md
#
# 目的はスキルの起動忘れを防ぐことで、迂回を防ぐことではない(マーカーは手で書ける)。
# そのため reader が読み切れない入力(長すぎる・引用符が閉じない・番兵の byte を含む)は判定せずに通す。
# git-push-guard とは逆の向きで、読めないことを理由に deny すると無関係なコマンドを止める損の方が大きい。
#
# Decision contract:
#   deny        — 範囲内のリポジトリの作成コマンドで、本文にマーカーを確認できないとき
#   (no output) — それ以外。allow / ask は返さない
#
# 範囲は lib/ticket-scope.bash が判定する(-R / --repo があればそれ、無ければフックの cwd の origin)。
# 残存: `cd <dir> && gh …` の cd 先は見ない。heredoc 演算子より後ろの segment は本文の行でありうるので判定しない
# (heredoc の後ろに実際に書かれた作成コマンドも素通りする)。`bash -c` の内側、`gh api` での作成、
# launchd から直接 gh を呼ぶスクリプトには効かない。フックが無い・落ちたときは判定なしで通る。
# check_segment は shell_reader_each_segment が名前で間接的に呼ぶ。
# shellcheck disable=SC2317,SC2329
set -uo pipefail

LOG_DIR="${HOME:-}/.claude/logs"
LOG_FILE="$LOG_DIR/ticket-guard-errors.log"
if [[ -n "${HOME:-}" ]] && mkdir -p "$LOG_DIR" 2>/dev/null &&
    (: >>"$LOG_FILE") 2>/dev/null; then
    exec 2>>"$LOG_FILE"
fi

MARKER='<!-- ticket-skill -->'

STDIN_JSON=$(cat) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
COMMAND=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
CWD=$(printf '%s' "$STDIN_JSON" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
case "$COMMAND" in
*gh*create*) ;;
*) exit 0 ;;
esac

script_dir=$(dirname "${BASH_SOURCE[0]}")
for library in "$script_dir/lib/shell-reader.bash" "$script_dir/lib/ticket-scope.bash"; do
    [[ -r "$library" ]] && "$BASH" -n "$library" 2>/dev/null || exit 0
    # shellcheck source=/dev/null
    source "$library" || exit 0
done
declare -F shell_reader_read shell_reader_each_segment ticket_scope_in_scope >/dev/null || exit 0

shell_reader_read "$COMMAND"
if [[ $SHELL_READER_TOO_LONG -eq 1 || $SHELL_READER_SEP_IN_INPUT -eq 1 ||
    $SHELL_READER_UNCLOSED_QUOTE -eq 1 ]]; then
    exit 0
fi

# 最初の heredoc 演算子の token index。無ければ -1。
HEREDOC_INDEX=${SHELL_READER_HEREDOC_INDEXES:- }
HEREDOC_INDEX=${HEREDOC_INDEX# }
HEREDOC_INDEX=${HEREDOC_INDEX%% *}
[[ -z "$HEREDOC_INDEX" ]] && HEREDOC_INDEX=-1

DENY_DETAIL=''

# segment が範囲内の作成コマンドで、本文にマーカーを確認できなければ DENY_DETAIL を設定して 1 を返す。
check_segment() {
    local -a tokens=("$@")
    local i=0 count=$#
    while [[ $i -lt $count && "${tokens[$i]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
        i=$((i + 1))
    done
    [[ $i -lt $count ]] || return 0
    [[ "${tokens[$i]}" == gh || "${tokens[$i]}" == */gh ]] || return 0
    [[ "${tokens[$((i + 1))]:-}" == issue || "${tokens[$((i + 1))]:-}" == pr ]] || return 0
    [[ "${tokens[$((i + 2))]:-}" == create ]] || return 0
    if [[ $HEREDOC_INDEX -ge 0 && $SHELL_READER_SEGMENT_START -gt $HEREDOC_INDEX ]]; then
        return 0
    fi

    local repo='' body_file='' has_body_file=0 argument
    local j=$((i + 3))
    while [[ $j -lt $count ]]; do
        argument=${tokens[$j]}
        case "$argument" in
        -R | --repo)
            repo=${tokens[$((j + 1))]:-}
            j=$((j + 1))
            ;;
        --repo=*) repo=${argument#--repo=} ;;
        -F | --body-file)
            has_body_file=1
            body_file=${tokens[$((j + 1))]:-}
            j=$((j + 1))
            ;;
        --body-file=*)
            has_body_file=1
            body_file=${argument#--body-file=}
            ;;
        esac
        j=$((j + 1))
    done

    ticket_scope_in_scope "${CWD:-.}" "$repo" || return 0
    case "$COMMAND" in *"$MARKER"*) return 0 ;; esac

    if [[ $has_body_file -eq 1 ]]; then
        case "$body_file" in
        '' | -) DENY_DETAIL='--body-file に標準入力は使えない(フックが本文を読めない)。' ;;
        *'$'* | *'`'*) DENY_DETAIL='--body-file のパスに変数やコマンド置換がある(フックは展開前の文字列しか受け取れない)。' ;;
        /*)
            if [[ -r "$body_file" ]] && grep -qF -- "$MARKER" "$body_file"; then
                return 0
            fi
            DENY_DETAIL="本文ファイル $body_file が読めないか、マーカーが無い。"
            ;;
        *) DENY_DETAIL='--body-file は絶対パスで渡す(cd が前に連結されているとフックから解決できない)。' ;;
        esac
    else
        DENY_DETAIL='本文にマーカーが無い。'
    fi
    return 1
}

shell_reader_each_segment check_segment && exit 0

jq -n --arg detail "$DENY_DETAIL" '{hookSpecificOutput: {hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("ticket-guard: " + $detail
        + " ticket スキル(~/.claude/skills/ticket/SKILL.md)の作成モードで本文を作り"
        + "(関連 issue のメンション、relationship、PR なら Closes と AC 対応表)、末尾に <!-- ticket-skill --> を付ける。"
        + "本文ファイルは git rev-parse --absolute-git-dir の出力の下の ticket/ に置き、--body-file <絶対パス> で再実行する。")}}'
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `LC_ALL=C pnpm exec bats test/ticket-guard.bats`
Expected: 22 tests, 0 failures

テストが落ちたら、まず reader が token をどう作ったかを確かめる。`bash -c 'source dot_claude/scripts/lib/shell-reader.bash; shell_reader_read "$1"; printf "[%s]\n" "${SHELL_READER_TOKENS[@]}"' _ '<コマンド>'` で token 列が見られる。特に、変数を含むパスの token が `$TMPDIR/pr.md` のまま残っているか(残っていなければ、`SHELL_READER_EXPANSION` の flag と、`*'$'*` の判定の組み合わせを見直す)を確かめる。

- [ ] **Step 5: lint を通してコミットする**

Run: `just shellcheck && just shfmt`
Expected: どちらも成功

```bash
git add dot_claude/scripts/executable_ticket-guard.sh test/ticket-guard.bats justfile
git commit -m "feat(ticket): マーカーの無い gh issue/pr create を deny する作成時ガードを追加する"
```

---

### Task 3: ガードを settings に配線する

**Files:**
- Modify: `dot_claude/settings.json.tmpl`(PreToolUse の curl-localhost-guard のエントリの直後)
- Modify: `test/settings-hooks.bats`

**Interfaces:**
- Consumes: `~/.claude/scripts/ticket-guard.sh`(Task 2 のスクリプトの配置先)

- [ ] **Step 1: 失敗するテストを書く**

`test/settings-hooks.bats` の `curl-localhost-guard が PreToolUse の Bash に直接配線されている` のテストの直後に、次を足す。

```bash
@test "ticket-guard が PreToolUse の Bash に直接配線されている" {
    assert_guard_wired ticket-guard
}
```

同じファイルの `hook が呼ぶ script はすべて chezmoi が実行可能として配置する` のテストで、`assert_line curl-localhost-guard.sh` の次の行に `assert_line ticket-guard.sh` を足す。

- [ ] **Step 2: 失敗を確かめる**

Run: `just test-settings-hooks`
Expected: 足した 2 か所が FAIL

- [ ] **Step 3: 配線する**

`dot_claude/settings.json.tmpl` で、`"command": "\"$HOME/.claude/scripts/curl-localhost-guard.sh\""` を含むエントリの閉じ `},` の直後(`"matcher": "*"` のエントリの前)に、次を挿入する。

```
      {{/* 個人リポジトリ(lib/ticket-scope.bash の owner の許可リスト)での gh issue create / gh pr create を、ticket スキルの作成モードを経た本文(<!-- ticket-skill --> を含む)でなければ deny するフック。課題は relationship・Closes・AC 対応表・関連 issue のメンションの「やり忘れ」で、スキルはモデルが使うと判断したときにしか起動しないため、作成の瞬間に決定的に止める。目的は起動忘れの防止で迂回の防止ではないので、読み切れない入力は通す(git-push-guard と逆の向き)。allow は返さない。設計は docs/superpowers/specs/2026-10-04-ticket-skill-design.md。 */ -}}
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.claude/scripts/ticket-guard.sh\"",
            "timeout": 5
          }
        ]
      },
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `just test-settings-hooks && just check-templates`
Expected: どちらも成功

- [ ] **Step 5: コミットする**

```bash
git add dot_claude/settings.json.tmpl test/settings-hooks.bats
git commit -m "feat(ticket): ticket-guard を PreToolUse に配線する"
```

---

### Task 4: 照合スクリプト `audit.sh`

**Files:**
- Create: `dot_claude/skills/ticket/scripts/executable_audit.sh`
- Test: `test/ticket-audit.bats`
- Modify: `justfile`(`test-scripts` に `test/ticket-audit.bats` を足す)

**Interfaces:**
- Produces: `audit.sh` を引数なしで実行すると、カレントのリポジトリを調べ、1 行 1 件のタブ区切り `<kind>\t<issue 番号>\t<根拠>` を stdout に出す。`kind` は次の 4 つ。件数の上限は `TICKET_AUDIT_LIMIT`(既定 100)で変えられる。
  - `parent-missing` 根拠 `#<親>`
  - `blocked-by-missing` 根拠 `#<blocker>`
  - `open-after-merge` 根拠 `PR #<n>`
  - `ac-unchecked` 根拠 `PR #<n>: <項目の文>`
- 呼ぶ gh コマンド(テストのスタブが受けるもの。`--jq` は使わず、jq に渡す):
  - `gh repo view --json nameWithOwner`
  - `gh issue list --state open --limit <N> --json number,body`
  - `gh issue list --state closed --limit <N> --json number,body,closedByPullRequestsReferences`
  - `gh pr list --state merged --limit <N> --json number,closingIssuesReferences`
  - `gh api repos/<o>/<r>/issues/<n>`
  - `gh api repos/<o>/<r>/issues/<n>/dependencies/blocked_by`

- [ ] **Step 1: 失敗するテストを書く**

`test/ticket-audit.bats`:

```bash
# ticket スキルの照合スクリプト。gh をスタブにして、検出する場合としない場合を対で確かめる。
setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../dot_claude/skills/ticket/scripts/executable_audit.sh"
    export GH_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
    mkdir -p "$GH_FIXTURES" "$BATS_TEST_TMPDIR/bin"
    for name in open closed merged; do printf '[]' >"$GH_FIXTURES/$name.json"; done
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
"repo view --json nameWithOwner") printf '{"nameWithOwner":"tanimon/sample"}' ;;
"issue list --state open"*) cat "$GH_FIXTURES/open.json" ;;
"issue list --state closed"*) cat "$GH_FIXTURES/closed.json" ;;
"pr list --state merged"*) cat "$GH_FIXTURES/merged.json" ;;
"api repos/tanimon/sample/issues/"*/dependencies/blocked_by)
    n=${2#repos/tanimon/sample/issues/}
    n=${n%%/*}
    cat "$GH_FIXTURES/blocked_by-$n.json" 2>/dev/null || printf '[]'
    ;;
"api repos/tanimon/sample/issues/"*)
    n=${2##*/}
    cat "$GH_FIXTURES/issue-$n.json" 2>/dev/null || printf '{}'
    ;;
*)
    echo "unexpected gh $*" >&2
    exit 1
    ;;
esac
STUB
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# open issue を 1 件置く。$1 = 番号、$2 = 本文
open_issue() {
    jq -n --argjson n "$1" --arg b "$2" '[{number:$n, body:$b}]' >"$GH_FIXTURES/open.json"
}

# --- blocked-by(#450 の形) ---

@test "本文に Blocked by があり API に無ければ blocked-by-missing" {
    open_issue 450 $'## Parent\n\n#397\n\n## Blocked by\n\n#401\n'
    printf '{"parent_issue_url":"https://api.github.com/repos/tanimon/sample/issues/397"}' >"$GH_FIXTURES/issue-450.json"
    run bash "$SCRIPT"
    assert_success
    assert_output $'blocked-by-missing\t450\t#401'
}

@test "本文の Blocked by が API にもあれば何も出さない" {
    open_issue 450 $'## Parent\n\n#397\n\n## Blocked by\n\n#401\n'
    printf '{"parent_issue_url":"https://api.github.com/repos/tanimon/sample/issues/397"}' >"$GH_FIXTURES/issue-450.json"
    printf '[{"number":401}]' >"$GH_FIXTURES/blocked_by-450.json"
    run bash "$SCRIPT"
    assert_success
    assert_output ''
}

# --- parent ---

@test "本文に Parent があり API の parent が無ければ parent-missing" {
    open_issue 12 $'## Parent\n\n#3\n'
    run bash "$SCRIPT"
    assert_output $'parent-missing\t12\t#3'
}

@test "Parent 節の外の #N は relationship として扱わない" {
    open_issue 12 $'## 関連\n\n#3 を参照\n'
    run bash "$SCRIPT"
    assert_output ''
}

# --- open-after-merge ---

@test "マージ済み PR が close するはずの issue が open なら open-after-merge" {
    open_issue 5 'body'
    printf '[{"number":10,"closingIssuesReferences":[{"number":5,"url":"https://github.com/tanimon/sample/issues/5"}]}]' >"$GH_FIXTURES/merged.json"
    run bash "$SCRIPT"
    assert_output $'open-after-merge\t5\tPR #10'
}

@test "close するはずの issue が close 済みなら何も出さない" {
    printf '[{"number":10,"closingIssuesReferences":[{"number":5,"url":"https://github.com/tanimon/sample/issues/5"}]}]' >"$GH_FIXTURES/merged.json"
    run bash "$SCRIPT"
    assert_output ''
}

@test "別リポジトリの issue への参照は対象にしない" {
    open_issue 5 'body'
    printf '[{"number":10,"closingIssuesReferences":[{"number":5,"url":"https://github.com/other/repo/issues/5"}]}]' >"$GH_FIXTURES/merged.json"
    run bash "$SCRIPT"
    assert_output ''
}

# --- ac-unchecked ---

@test "PR で close された issue の AC に [ ] が残れば ac-unchecked" {
    jq -n '[{number:7, body:"## Acceptance criteria\n\n- [x] a\n- [ ] b を満たす\n", closedByPullRequestsReferences:[{number:20}]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output $'ac-unchecked\t7\tPR #20: b を満たす'
}

@test "AC がすべて [x] なら何も出さない" {
    jq -n '[{number:7, body:"## Acceptance criteria\n\n- [x] a\n- [x] b\n", closedByPullRequestsReferences:[{number:20}]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output ''
}

@test "PR を経ずに close された issue の AC は対象にしない" {
    jq -n '[{number:7, body:"## Acceptance criteria\n\n- [ ] b\n", closedByPullRequestsReferences:[]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output ''
}

@test "完了条件(案) の見出しも AC として扱う" {
    jq -n '[{number:8, body:"## 完了条件(案)\n\n- [ ] c\n\n## メモ\n\n- [ ] AC ではない\n", closedByPullRequestsReferences:[{number:21}]}]' >"$GH_FIXTURES/closed.json"
    run bash "$SCRIPT"
    assert_output $'ac-unchecked\t8\tPR #21: c'
}

@test "gh が失敗したら非 0 で終わる" {
    printf 'not json' >"$GH_FIXTURES/open.json"
    run bash "$SCRIPT"
    assert_failure
}
```

`justfile` の `test-scripts` レシピの bats の引数の末尾に `test/ticket-audit.bats` を足す。

- [ ] **Step 2: 失敗を確かめる**

Run: `LC_ALL=C pnpm exec bats test/ticket-audit.bats`
Expected: FAIL(スクリプトが無い)

- [ ] **Step 3: 実装する**

`dot_claude/skills/ticket/scripts/executable_audit.sh`:

```bash
#!/usr/bin/env bash
# ticket スキルの照合モードの検出部分。カレントのリポジトリの issue と PR の食い違いを、
# 1 行 1 件のタブ区切り「<kind> <issue 番号> <根拠>」で出す。書き込みはしない。
#   parent-missing      本文の Parent 節にある親が、API の parent と違う
#   blocked-by-missing  本文の Blocked by 節にある blocker が、API の dependencies に無い
#   open-after-merge    マージ済み PR の closingIssuesReferences にある issue が open のまま
#   ac-unchecked        PR で close された issue の AC 節に [ ] が残る(1 項目 1 行)
# 件数の上限は TICKET_AUDIT_LIMIT(既定 100)。gh の --jq は使わず jq に渡す(テストで gh をスタブにするため)。
set -euo pipefail
export LC_ALL=C

LIMIT=${TICKET_AUDIT_LIMIT:-100}

# 見出しが正規表現 $1(小文字にした行と比べる)に一致する節の中の #N を、1 行 1 番号で出す。
section_refs() {
    awk -v pattern="$1" '
        /^#+[ \t]/ { in_section = (tolower($0) ~ pattern); next }
        in_section {
            line = $0
            while (match(line, /#[0-9]+/)) {
                print substr(line, RSTART + 1, RLENGTH - 1)
                line = substr(line, RSTART + RLENGTH)
            }
        }'
}

# 見出しが正規表現 $1 に一致する節の中の未チェック項目の文を、1 行 1 項目で出す。
unchecked_items() {
    awk -v pattern="$1" '
        /^#+[ \t]/ { in_section = (tolower($0) ~ pattern); next }
        in_section && /^[ \t]*[-*] \[ \] / { sub(/^[ \t]*[-*] \[ \] /, ""); print }'
}

repo=$(gh repo view --json nameWithOwner | jq -r .nameWithOwner)
open_json=$(gh issue list --state open --limit "$LIMIT" --json number,body)
open_numbers=$(printf '%s' "$open_json" | jq -r '.[].number')

# relationship
items=$(printf '%s' "$open_json" | jq -c '.[]')
while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    number=$(printf '%s' "$item" | jq -r .number)
    body=$(printf '%s' "$item" | jq -r '.body // ""')
    parents=$(printf '%s\n' "$body" | section_refs '^#+[ \t]+parent')
    blockers=$(printf '%s\n' "$body" | section_refs '^#+[ \t]+blocked by')
    if [[ -n "$parents" ]]; then
        actual=$(gh api "repos/$repo/issues/$number" | jq -r '.parent_issue_url // ""')
        actual=${actual##*/}
        for parent in $parents; do
            if [[ "$parent" != "$actual" ]]; then
                printf 'parent-missing\t%s\t#%s\n' "$number" "$parent"
            fi
        done
    fi
    if [[ -n "$blockers" ]]; then
        actual=$(gh api "repos/$repo/issues/$number/dependencies/blocked_by" | jq -r '.[].number')
        for blocker in $blockers; do
            if ! printf '%s\n' "$actual" | grep -qx "$blocker"; then
                printf 'blocked-by-missing\t%s\t#%s\n' "$number" "$blocker"
            fi
        done
    fi
done <<<"$items"

# open-after-merge
references=$(gh pr list --state merged --limit "$LIMIT" --json number,closingIssuesReferences |
    jq -r --arg repo "$repo" '.[] | .number as $pr | .closingIssuesReferences[]
        | select((.url | split("/")[3:5] | join("/")) == $repo)
        | "\(.number)\t\($pr)"')
while IFS=$'\t' read -r issue pr; do
    [[ -n "$issue" ]] || continue
    if printf '%s\n' "$open_numbers" | grep -qx "$issue"; then
        printf 'open-after-merge\t%s\tPR #%s\n' "$issue" "$pr"
    fi
done <<<"$references"

# ac-unchecked
closed=$(gh issue list --state closed --limit "$LIMIT" --json number,body,closedByPullRequestsReferences |
    jq -c '.[] | select((.closedByPullRequestsReferences | length) > 0)
        | {number, body: (.body // ""), pr: .closedByPullRequestsReferences[0].number}')
while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    number=$(printf '%s' "$item" | jq -r .number)
    pr=$(printf '%s' "$item" | jq -r .pr)
    printf '%s' "$item" | jq -r .body |
        unchecked_items '^#+[ \t]+(acceptance criteria|完了条件)' |
        while IFS= read -r text; do
            printf 'ac-unchecked\t%s\tPR #%s: %s\n' "$number" "$pr" "$text"
        done
done <<<"$closed"
```

- [ ] **Step 4: テストが通ることを確かめる**

Run: `LC_ALL=C pnpm exec bats test/ticket-audit.bats`
Expected: 12 tests, 0 failures

- [ ] **Step 5: 実リポジトリで 1 度実行して、#450 が出ることを確かめる**

Run: `bash dot_claude/skills/ticket/scripts/executable_audit.sh | grep -F blocked-by-missing`
Expected: `blocked-by-missing	450	#401` の行が出る(#401 の native 依存関係が未設定のままなら)。出なければ、`gh api repos/tanimon/dotfiles/issues/450/dependencies/blocked_by` の実際の応答の形を確かめ、jq の式を合わせる

- [ ] **Step 6: lint を通してコミットする**

Run: `just shellcheck && just shfmt`
Expected: どちらも成功

```bash
git add dot_claude/skills/ticket/scripts/executable_audit.sh test/ticket-audit.bats justfile
git commit -m "feat(ticket): 照合モードの食い違いを決定的に列挙する audit.sh を追加する"
```

---

### Task 5: スキル本体と issue-tracker.md

**Files:**
- Create: `dot_claude/skills/ticket/SKILL.md`
- Modify: `docs/agents/issue-tracker.md`(Wayfinding operations の Child ticket と Blocking の項、末尾に節を追加)

**Interfaces:**
- Consumes: `~/.claude/scripts/lib/ticket-scope.bash`(Task 1)、`~/.claude/skills/ticket/scripts/audit.sh` の出力形式(Task 4)、ガードの理由文が指す手順(Task 2)

- [ ] **Step 1: SKILL.md を書く**

`dot_claude/skills/ticket/SKILL.md`:

````markdown
---
name: ticket
description: GitHub Issues でチケットを管理する個人リポジトリで、issue / PR を作るとき(作成モード)と、マージ後の関係づけの漏れを洗い出して直すとき(照合モード)に使う。「issue を作って」「PR を作って」「issue を整理して」「close し忘れの issue を探して」「AC のチェック漏れを直して」「/ticket」など。ticket-guard フックが gh issue create / gh pr create を deny したときも使う。仕事リポジトリ(チケットは Notion)には使わない。
argument-hint: "[audit]"
---

# ticket

issue と PR の関係づけ(関連 issue のメンション、parent / blocked-by、`Closes #N`、Acceptance criteria)を漏らさないための手順。設計は chezmoi リポジトリの `docs/superpowers/specs/2026-10-04-ticket-skill-design.md`。

最初に `bash ~/.claude/scripts/lib/ticket-scope.bash "$(pwd)"` を実行する。終了コードが 0 以外なら範囲外なので、このスキルは使わずにユーザーへそう伝える。引数が `audit` なら照合モード、それ以外は作成モード。

## 作成モード

issue や PR を作る前に、本文ファイルを次の手順で作る。

1. **置き場所を決める。** `git rev-parse --absolute-git-dir` を単独で実行し、出力に `/ticket` を足したディレクトリを使う(以降 `<dir>`)。本文は Write ツールで `<dir>/issue-body.md` か `<dir>/pr-body.md` に書く。コマンドには `$(…)` や `$TMPDIR` を含めず、展開済みの絶対パスを書く(ticket-guard は展開前の文字列しか読めない)。
2. **関連 issue を探してメンションする。** タイトルの主要な語を 2〜3 通り変えて `gh issue list --state all --search "<語>" --limit 20 --json number,title,state` を実行する。関連するものを `## 関連` 節に `- #N <なぜ関連するかを 1 行>` で書く。見つからなければ「関連 issue なし(検索語: …)」と書く。
3. **issue なら relationship を書いて張る。** 親は `## Parent`、先に片付ける必要がある issue は `## Blocked by` の節に `#N` で書く。作成後に native にも設定する。
   - database id: `gh api repos/<owner>/<repo>/issues/<n> --jq .id`(`#number` や `node_id` ではない)
   - 親子: `gh api repos/<owner>/<repo>/issues/<親>/sub_issues -X POST -F sub_issue_id=<子の database id>`
   - 依存: `gh api repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by -X POST -F issue_id=<blocker の database id>`
   - 確認: `gh api repos/<owner>/<repo>/issues/<n> --jq '{parent: .parent_issue_url, deps: .issue_dependencies_summary}'`
4. **PR なら Closes と AC 対応表を書く。** 解決する issue ごとに `Closes #N` を 1 行ずつ書く(`Closes #1, #2` は 2 件目が効かない)。部分的にしか解決しない issue は `Refs #N` にする。各 issue の AC(`gh issue view <N> --json body`)について、`## Acceptance criteria の対応` 節に表 `| issue | 項目 | 対応 |` を書く。「対応」には満たした変更(ファイルやテスト)を書き、満たさない項目にはその理由を書く。`Closes` による自動 close は既定ブランチへのマージでしか効かない。
5. **末尾にマーカーを付ける。** 本文の最後の行を `<!-- ticket-skill -->` にする。
6. **作る。** `gh issue create --title "<title>" --body-file <dir>/issue-body.md`、または `gh pr create --head <branch> --title "<title>" --body-file <dir>/pr-body.md`。issue の場合はその後に手順3の native 設定を行う。

## 照合モード

1. `bash ~/.claude/skills/ticket/scripts/audit.sh` を実行する。出力は 1 行 1 件のタブ区切り `<kind> <issue> <根拠>`。
2. kind ごとに修正案を作る。
   - `parent-missing` / `blocked-by-missing`: 作成モードの手順3のコマンドで native に張る。
   - `open-after-merge`: `gh issue close <issue> --reason completed --comment "PR #<n> のマージで解決済み(Closes による自動 close が効かなかった)"`。
   - `ac-unchecked`: 根拠の PR の本文(`gh pr view <n> --json body`)の AC 対応表で、その項目を満たしたと書いてあるものだけを `[x]` にする候補にする。対応表に無い項目や、理由を書いて意図的に `[ ]` のまま残した項目は触らず、報告に載せる。
3. 修正案を表(kind・issue・操作・根拠)で示し、`AskUserQuestion` で「全部適用 / 種類ごとに選ぶ / やめる」を選んでもらう。承認なしに書き込まない。
4. 適用する。AC は `gh issue view <issue> --json body --jq .body` を `<dir>/issue-<issue>.md` に保存し、該当行の `- [ ]` だけを `- [x]` に直して `gh issue edit <issue> --body-file <dir>/issue-<issue>.md` で戻す。
5. もう一度 `audit.sh` を実行し、適用した分が出なくなったことを確かめてから、残った件数と理由を報告する。
````

- [ ] **Step 2: issue-tracker.md を書き換える**

`docs/agents/issue-tracker.md` の Wayfinding operations 節で、次の 2 か所を置き換える。

- Child ticket の項の「map の GitHub sub-issue としてリンクした issue（sub-issues エンドポイントを `gh api` で叩く）。」を「map の GitHub sub-issue としてリンクした issue（API の手順は `ticket` スキルの作成モードの手順3）。」にする。
- Blocking の項の「`gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`。`<blocker-db-id>` は blocker の数値 **database id**（`gh api repos/<owner>/<repo>/issues/<n> --jq .id` で取得。`#number` や `node_id` ではない）。」を「API の手順は `ticket` スキルの作成モードの手順3（blocker の database id を使う）。」にする。

ファイルの末尾に次の節を足す。

```markdown
## issue / PR を作るとき

`ticket` スキル(`~/.claude/skills/ticket/SKILL.md`)の作成モードに従う。関連 issue のメンション、parent / blocked-by の native 設定、PR の `Closes #N` と AC 対応表の手順の正本はそちらにある。本文にマーカー `<!-- ticket-skill -->` が無い `gh issue create` / `gh pr create` は、ticket-guard フックが deny する。マージ後に残った漏れは `/ticket audit` で洗い出す。
```

- [ ] **Step 3: lint を通す**

Run: `just scan-sensitive && just check-comment-noise && just check-instruction-size`
Expected: すべて成功(SKILL.md は既定の上限 200 行 / 32768 バイトに収まる)

- [ ] **Step 4: コミットする**

```bash
git add dot_claude/skills/ticket/SKILL.md docs/agents/issue-tracker.md
git commit -m "feat(ticket): 作成モードと照合モードを持つ ticket スキルを追加する"
```

---

### Task 6: deliver に組み込む

**Files:**
- Modify: `dot_claude/workflows/deliver.js`(定数、`validateArgs`、公開処理、返り値)
- Modify: `test/deliver-workflow.test.mjs`
- Modify: `dot_claude/skills/deliver/SKILL.md`(手順7・8)

**Interfaces:**
- Consumes: `~/.claude/scripts/lib/ticket-scope.bash`(Task 1)、`~/.claude/skills/ticket/SKILL.md` の作成モード手順2・4(Task 5)
- Produces: Workflow の引数 `ticket`(省略可、真偽値)。返り値の `prBody`(公開に使った、または使うはずだった本文。`ticket` が偽なら `report` と同じ)

- [ ] **Step 1: 失敗するテストを書く**

`test/deliver-workflow.test.mjs` の末尾に足す。

```js
const TICKET_MARKER = "<!-- ticket-skill -->";
const withTicket = (ticketResponse, base = scenario()) => (label, calls) =>
  label === "ticket" ? ticketResponse : base(label, calls);
const publishedBody = (calls) =>
  between(calls.find((c) => c.label === "publish-write:1").prompt, "REPORT");

test("ticket が真なら公開の前にチケット節を作り、本文の末尾にマーカーを付ける", async () => {
  const { result, labels, calls } = await runWorkflow({
    args: { ticket: true },
    respond: withTicket({ section: "## チケット\n\nCloses #5" }),
  });
  assert.deepEqual(labels.slice(-3), ["ticket", "publish-write:1", "publish"]);
  const body = publishedBody(calls);
  assert.match(body, /## チケット\n\nCloses #5/);
  assert.ok(body.trimEnd().endsWith(TICKET_MARKER));
  assert.equal(result.prBody, body);
  assert.equal(result.published, true);
});

test("ticket を省略したらチケット節もマーカーも付けない", async () => {
  const { result, labels, calls } = await runWorkflow();
  assert.ok(!labels.includes("ticket"));
  assert.ok(!publishedBody(calls).includes(TICKET_MARKER));
  assert.equal(result.prBody, result.report);
});

test("チケット節を作れなくても公開し、作れなかったことを本文に残す", async () => {
  const { result, calls } = await runWorkflow({
    args: { ticket: true },
    respond: withTicket(null),
  });
  const body = publishedBody(calls);
  assert.match(body, /チケット節を作れなかった/);
  assert.ok(body.trimEnd().endsWith(TICKET_MARKER));
  assert.equal(result.published, true);
});

test("review-verify では ticket が真でもチケット節を作らない", async () => {
  const { labels } = await runWorkflow({
    args: { mode: "review-verify", ticket: true },
    respond: withTicket({ section: "## チケット" }),
  });
  assert.ok(!labels.includes("ticket"));
});

test("ticket が真偽値でなければ拒否する", async () => {
  await assert.rejects(runWorkflow({ args: { ticket: "yes" } }), /ticket は真偽値/);
});
```

- [ ] **Step 2: 失敗を確かめる**

Run: `just test-deliver`
Expected: 足した 5 件のうち、ticket を省略するテスト以外の 4 件が FAIL。省略のテストも `result.prBody` が `undefined` なので FAIL

- [ ] **Step 3: 実装する**

`dot_claude/workflows/deliver.js` の `PUBLISH_SCHEMA` の定義の直後に足す。

```js
const TICKET_SCHEMA = {
  type: "object",
  properties: { section: { type: "string" } },
  required: ["section"],
};
// ticket-guard フックが PR 作成時に探すマーカー。~/.claude/skills/ticket/SKILL.md と同じ文字列。
const TICKET_MARKER = "<!-- ticket-skill -->";
```

`validateArgs` の `if (!Object.keys(MODES).includes(a.mode)) { … }` の直後に足す。

```js
  if (a.ticket !== undefined && typeof a.ticket !== "boolean") {
    throw new Error(`deliver: ticket は真偽値: ${a.ticket}`);
  }
```

`publishPrompt` 関数の直後に足す。

```js
function ticketPrompt(config) {
  return `PR 本文に足す「チケット」節を作れ。issue や PR の作成・編集はしない。
1. ~/.claude/skills/ticket/SKILL.md を Read ツールで読み、作成モードの手順2(関連 issue のメンション)と手順4(Closes と AC 対応表)に従う。
2. 対象の変更は「git diff ${config.baseRef}...HEAD」、要件文書は ${config.requirementsPath}。
3. 節は「## チケット」で始まる Markdown にして section で返す。マーカーは付けない(呼び出し側が付ける)。`;
}

// 節を作れなくても公開は止めない(止めると PR ごと失う)。作れなかったことは本文に残し、マージ前に人が補う。
async function withTicketSection(state, report) {
  let section = null;
  try {
    const result = await agent(ticketPrompt(state.config), {
      label: "ticket",
      phase: "Publish",
      schema: TICKET_SCHEMA,
    });
    if (result && typeof result.section === "string" && result.section.trim() !== "")
      section = result.section.trim();
  } catch (error) {
    log(`チケット節を作れなかった: ${String(error && error.message ? error.message : error)}`);
  }
  const body =
    section ?? "## チケット\n\nチケット節を作れなかった。マージ前に ticket スキルの作成モードで補うこと。";
  return `${report}\n\n${body}\n\n${TICKET_MARKER}\n`;
}
```

トップレベルの公開処理を書き換える。変更前:

```js
let published = null;
try {
  if (config.features.publish) published = await publish(state, report, ledger);
} catch (error) {
```

変更後:

```js
let published = null;
let prBody = report;
try {
  if (config.features.publish) {
    if (config.ticket === true) prBody = await withTicketSection(state, report);
    published = await publish(state, prBody, ledger);
  }
} catch (error) {
```

返り値のオブジェクトの `report,` の次の行に `prBody,` を足し、その直前にコメント `// 公開に使った PR 本文。公開できなかったとき、入口 skill はこれを pr-body.md に書き出す。` を置く。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `just test-deliver && just oxlint && just oxfmt`
Expected: すべて成功(既存のテストも含む)

- [ ] **Step 5: deliver の SKILL.md を直す**

`dot_claude/skills/deliver/SKILL.md` の手順7のコードブロック中、`maxReviewRounds: <手順6。指定があるときだけ>` の次の行に次を足す。

```
       ticket: <bash ~/.claude/scripts/lib/ticket-scope.bash "$(pwd)" の終了コードが 0 なら true、それ以外は false>
```

手順7の本文の末尾(コードブロックの後)に、次の1文を足す。

```
   `ticket` が true のとき、Workflow は ticket スキルの作成モードで「## チケット」節を作り、PR 本文の末尾にマーカーを付ける(ticket-guard フックがマーカーの無い PR 作成を deny するため)。
```

手順8の「返り値の `report` と `ledger` をそれぞれ `$(git rev-parse --absolute-git-dir)/deliver/pr-body.md` / `ledger.json` に」を「返り値の `prBody` と `ledger` をそれぞれ `$(git rev-parse --absolute-git-dir)/deliver/pr-body.md` / `ledger.json` に」に変える。

- [ ] **Step 6: コミットする**

```bash
git add dot_claude/workflows/deliver.js test/deliver-workflow.test.mjs dot_claude/skills/deliver/SKILL.md
git commit -m "feat(deliver): 範囲内のリポジトリでは PR 本文にチケット節とマーカーを付ける"
```

---

### Task 7: 全体の検証

**Files:** なし(検証のみ。失敗したら、該当する Task のファイルを直す)

- [ ] **Step 1: 全 lint を通す**

Run: `just lint`
Expected: 成功。CI の対応は `just test-ci-parity` が検査する(新しいレシピは足していないので、`lint.yml` の変更は要らない)

- [ ] **Step 2: chezmoi が配置するファイルを確かめる**

Run: `chezmoi managed --source "$(pwd)" | grep -E 'ticket'`
Expected: `.claude/scripts/ticket-guard.sh`、`.claude/scripts/lib/ticket-scope.bash`、`.claude/skills/ticket/SKILL.md`、`.claude/skills/ticket/scripts/audit.sh` の 4 件が出る

- [ ] **Step 3: 統合の方法を決める**

push と PR の作成は superpowers:finishing-a-development-branch で決める。このブランチの PR 自体が ticket-guard の対象になるので、PR 本文は ticket スキルの作成モードで作る(関連 issue として #443・#440・#449・#450 を挙げる)。PR を作ったら CI の結果を確かめてから完了を報告する。ローカルで通って CI で落ちた場合は、BSD と GNU の違い(awk の `tolower`、`grep -x`)を疑う
