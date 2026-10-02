# コメントのノイズ防止 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** コードコメントの書き方を定めるグローバルルールと、機械的に判定できるノイズを止める lint をこのリポジトリに入れる。

**Architecture:** ルールは `dot_claude/rules/common/code-comments.md` に置き、Codex の `AGENTS.md` にも連結する。lint は `scripts/check-comment-noise.sh` で、`git ls-files` の全ファイルから行頭コメントだけを取り出し、名前付きの 3 パターン(`plan-step` / `issue-origin` / `missing-path`)で判定する。例外は許可リストで与える。`just lint`・CI・prek に繋ぎ、既存の違反は同じブランチで直す。

**Tech Stack:** bash(3.2 互換)、grep -E、bats(bats-assert)、just、GitHub Actions、prek

**Spec:** `docs/superpowers/specs/2026-10-02-comment-noise-guard-design.md`

## Global Constraints

- ルールは日本語で書き、製品名・製品固有のツール名・このリポジトリ固有のパスを書かない。3 KB 以内に収める
- `~/.codex/AGENTS.md` は 32768 バイト未満を保つ(`test/global-instructions.bats` が強制)
- 正規表現は `grep -E` と bash の `=~` だけで書く。`grep -P` と `\b` は使わない(CI は Ubuntu の GNU、ローカルは macOS の BSD)
- スクリプトは bash 3.2 互換にする。連想配列と `mapfile` は使わない
- lint の対象外: `*.md`、`docs/` 配下、`*.json`、`pnpm-lock.yaml`
- コメント行とみなすのは、行頭(空白を除く)が `#` か `//` の行だけ。1 行目の `#!` は除く
- lint の失敗メッセージはルールファイルを指すだけにして、規約の本文を写さない
- `just` のレシピは、説明の 1 行を最後のコメント行に置く(`just --list` は最後の行だけを表示するため)
- 日本語の `@test` 名を持つ bats は `LC_ALL=C` を付けて実行する(justfile の既存レシピと同じ)
- この計画のファイル(新しく作るスクリプト・テスト・許可リスト)のコメント自体も lint に通る形で書く。コメントに `Task` や `Step` と数字の組、「#数字 で追加」などを書かない

## Review Focus

1. **許可リストの正規表現が不正**: bash の `=~` は不正な正規表現で 2 を返す。何もしないと「一致しない」と同じ扱いになり、例外が黙って効かなくなる。不正なら exit 2 で止める → Task 1 にテストあり
2. **CRLF の行**: 行末の `\r` がパスのトークンに付くと、実在するパスでも `missing-path` になる → Task 2 にテストあり
3. **空白を含むファイル名**: `git ls-files` を改行で区切ると壊れる。`-z` で読む → Task 1 にテストあり
4. **許可リストのファイルが無い**: 任意のファイルなので、無いときは例外なしとして動く → Task 1 にテストあり
5. **テンプレートやプレースホルダを含むパス**(`{{ .x }}/a`、`dot_claude/<name>/x`、`docs/{a,b}/`): 実在確認から外す → Task 2 にテストあり

---

### Task 1: lint 本体(コメント抽出・`plan-step`・`issue-origin`・許可リスト)

**Files:**
- Create: `scripts/check-comment-noise.sh`
- Create: `test/check-comment-noise.bats`

**Interfaces:**
- Produces: `bash scripts/check-comment-noise.sh`。引数は取らない。カレントディレクトリが属する git リポジトリのトップレベルを走査する
  - 環境変数 `COMMENT_NOISE_ALLOWLIST`: 許可リストのパス。既定は `scripts/comment-noise-allowlist.txt`(スクリプトと同じディレクトリ)
  - 標準出力: 違反 1 件につき `<file>:<line>: [<pattern 名>] <該当行>`
  - 終了コード: 違反なし 0 / 違反あり 1 / 許可リストの正規表現が不正 2
  - 違反ありのとき、最後に標準エラー出力へ `dot_claude/rules/common/code-comments.md` を案内する
- Produces(Task 2 が使う): 関数 `report <file> <lineno> <pattern> <text>`、`is_allowed <file> <text>`、行ごとの判定関数 `check_line <file> <lineno> <text>`

- [ ] **Step 1: 失敗するテストを書く**

`test/check-comment-noise.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'helpers/setup'
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/check-comment-noise.sh"
    REPO="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$REPO"
    git -C "$REPO" init -q
    export COMMENT_NOISE_ALLOWLIST="$BATS_TEST_TMPDIR/allowlist.txt"
    : >"$COMMENT_NOISE_ALLOWLIST"
}

# 一時リポジトリに 1 ファイル置いて git に登録する
put() {
    mkdir -p "$REPO/$(dirname "$1")"
    printf '%s\n' "$2" >"$REPO/$1"
    git -C "$REPO" add -- "$1"
}

scan() {
    (cd "$REPO" && bash "$SCRIPT")
}

@test "違反が無ければ出力は空で exit 0" {
    put a.sh '# ふつうのコメント'
    run scan
    assert_success
    assert_output ''
}

@test "plan-step: 計画の内部番号を止め、ルールファイルを案内する" {
    put a.sh '# Task 2 で追加した分岐'
    run scan
    assert_failure 1
    assert_output --partial 'a.sh:1: [plan-step]'
    assert_output --partial 'dot_claude/rules/common/code-comments.md'
}

@test "plan-step: // コメントの Step も止める" {
    put a.js '  // Step 3 の後始末'
    run scan
    assert_failure 1
    assert_output --partial 'a.js:1: [plan-step]'
}

@test "plan-step: 単語の一部や数字の無い Task は止めない" {
    put a.sh $'# Taskfile を読む\n# MultiTask 3 は製品名\n# Task の数を数える'
    run scan
    assert_success
}

@test "issue-origin: 番号の後に経緯の動詞が続くものを止める" {
    put a.sh '# SC1091 が誤って出るため(#309 で発覚)。'
    run scan
    assert_failure 1
    assert_output --partial 'a.sh:1: [issue-origin]'
}

@test "issue-origin: 英語の fixed in #N を止める" {
    put a.js '// fixed in #12'
    run scan
    assert_failure 1
    assert_output --partial '[issue-origin]'
}

@test "issue-origin: 未解決 issue への参照は止めない" {
    put a.sh '# #382(未解決)が直るまでの暫定の手順'
    run scan
    assert_success
}

@test "コードの行と行末コメントは見ない" {
    put a.sh $'echo "Task 2"\nfoo # Task 2 で追加'
    run scan
    assert_success
}

@test "1 行目の shebang は見ない" {
    put a.sh $'#!/usr/bin/env bash Task 1\n: '
    run scan
    assert_success
}

@test "対象外のファイル(md / docs / json)は見ない" {
    put a.md '# Task 2'
    put docs/b.sh '# Task 2'
    put c.json '# Task 2'
    run scan
    assert_success
}

@test "git に登録されていないファイルは見ない" {
    printf '# Task 2\n' >"$REPO/untracked.sh"
    run scan
    assert_success
}

@test "空白を含むファイル名も読む" {
    put 'dir with space/a b.sh' '# Task 2'
    run scan
    assert_failure 1
    assert_output --partial 'dir with space/a b.sh:1: [plan-step]'
}

@test "許可リストに書いた違反は止まらず、外すと止まる" {
    put a.sh '# Task 2 は外部の手順書の番号'
    printf 'a.sh:外部の手順書\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_success
    : >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_failure 1
}

@test "許可リストの * は全ファイルに効き、別ファイルの suffix は効かない" {
    put a.sh '# Task 2 は外部の手順書の番号'
    printf 'b.sh:外部の手順書\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_failure 1
    printf '*:外部の手順書\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_success
}

@test "許可リストのファイルが無くても動く" {
    rm -f "$COMMENT_NOISE_ALLOWLIST"
    put a.sh '# Task 2'
    run scan
    assert_failure 1
}

@test "許可リストの正規表現が不正なら exit 2" {
    put a.sh '# Task 2'
    printf 'a.sh:([\n' >"$COMMENT_NOISE_ALLOWLIST"
    run scan
    assert_failure 2
    assert_output --partial 'invalid regex'
}
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `LC_ALL=C pnpm exec bats test/check-comment-noise.bats`
Expected: スクリプトが無いため、ほぼ全件 FAIL(`違反が無ければ…` も `bash: …check-comment-noise.sh: No such file` で FAIL)

- [ ] **Step 3: 実装する**

`scripts/check-comment-noise.sh`:

```bash
#!/usr/bin/env bash
# コードコメントのうち、機械的に判定できる種類のノイズを検出する。
# 規約の正本はルールファイル(RULE_FILE)で、ここには判定だけを置く。
set -euo pipefail
# トークン分割で glob 展開させない
set -f
# 判定をロケールに依存させない(マルチバイト文字はバイト列として扱う)
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST_FILE="${COMMENT_NOISE_ALLOWLIST:-${SCRIPT_DIR}/comment-noise-allowlist.txt}"
RULE_FILE="dot_claude/rules/common/code-comments.md"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

PLAN_STEP_RE='(^|[^A-Za-z])(Task|Step) [0-9]+'
# 番号と動詞の間は 24 バイトまで(LC_ALL=C なので日本語は 1 文字 3 バイト)
ISSUE_ORIGIN_JA_RE='#[0-9]+[^#]{0,24}(で発覚|で追加|で導入|で修正|で判明)'
ISSUE_ORIGIN_EN_RE='(added|introduced|found|fixed) in #[0-9]+'

# Markdown・docs は経緯の記録が正当な場合が多く、JSON はコメントを持たない
is_excluded() {
    case $1 in
    *.md | docs/* | *.json | pnpm-lock.yaml) return 0 ;;
    esac
    return 1
}

# 許可リストの、コメント行と空行を除いた行を出す。ファイルが無ければ何も出さない
read_allowlist() {
    local line
    [[ -f $ALLOWLIST_FILE ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*# ]] && continue
        [[ -z ${line//[[:space:]]/} ]] && continue
        printf '%s\n' "$line"
    done <"$ALLOWLIST_FILE"
}
ALLOW_ENTRIES="$(read_allowlist)"

# 許可リストの各行は <path-suffix or *>:<regex>
is_allowed() {
    local file=$1 text=$2 entry suffix regex status
    [[ -n $ALLOW_ENTRIES ]] || return 1
    while IFS= read -r entry; do
        suffix=${entry%%:*}
        regex=${entry#*:}
        [[ $suffix == '*' || $file == *"$suffix" ]] || continue
        status=0
        [[ $text =~ $regex ]] || status=$?
        if ((status == 0)); then
            return 0
        elif ((status == 2)); then
            printf 'error: invalid regex in %s: %s\n' "$ALLOWLIST_FILE" "$entry" >&2
            exit 2
        fi
    done <<<"$ALLOW_ENTRIES"
    return 1
}

violations=0

report() {
    local file=$1 lineno=$2 pattern=$3 text=$4
    is_allowed "$file" "$text" && return 0
    printf '%s:%s: [%s] %s\n' "$file" "$lineno" "$pattern" "$text"
    violations=$((violations + 1))
}

check_line() {
    local file=$1 lineno=$2 text=$3
    if [[ $text =~ $PLAN_STEP_RE ]]; then
        report "$file" "$lineno" plan-step "$text"
    fi
    if [[ $text =~ $ISSUE_ORIGIN_JA_RE || $text =~ $ISSUE_ORIGIN_EN_RE ]]; then
        report "$file" "$lineno" issue-origin "$text"
    fi
}

while IFS= read -r -d '' file; do
    is_excluded "$file" && continue
    [[ -f $file ]] || continue
    while IFS= read -r hit; do
        lineno=${hit%%:*}
        text=${hit#*:}
        [[ $lineno == 1 && $text == '#!'* ]] && continue
        check_line "$file" "$lineno" "$text"
    done < <(grep -InE '^[[:space:]]*(#|//)' -- "$file" || true)
done < <(git ls-files -z)

if ((violations > 0)); then
    printf '\n%d 件のコメントが規約に反しています。規約: %s\n' "$violations" "$RULE_FILE" >&2
    printf '残すべきものは %s に <path-suffix or *>:<regex> で追加してください。\n' "$ALLOWLIST_FILE" >&2
    exit 1
fi
```

注意: `report` から呼ぶ `is_allowed` の `exit 2` はサブシェルではなく本体で実行されるので、そのままスクリプトが止まる(`check_line` はパイプの中で呼んでいない)。`assert_output` は bats の `run` が標準出力と標準エラー出力を合わせて捕まえるので、案内文も検査できる。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `LC_ALL=C pnpm exec bats test/check-comment-noise.bats`
Expected: 全件 PASS

対比の確認: `PLAN_STEP_RE` の `(^|[^A-Za-z])` を一時的に外して `MultiTask 3` のテストが FAIL することを確かめ、元に戻す。

- [ ] **Step 5: shellcheck / shfmt を通す**

Run: `just shellcheck && just shfmt`
Expected: 新しい 2 ファイルを含めて通る

- [ ] **Step 6: コミット**

```bash
git add scripts/check-comment-noise.sh test/check-comment-noise.bats
git commit -m "feat(scripts): 計画番号と経緯の番号を含むコメントを検出する lint を追加する"
```

---

### Task 2: `missing-path`(存在しないパスの参照)

**Files:**
- Modify: `scripts/check-comment-noise.sh`(`check_line` に判定を足し、トップレベルのディレクトリ一覧を作る)
- Modify: `test/check-comment-noise.bats`(末尾にテストを足す)

**Interfaces:**
- Consumes: Task 1 の `report`、`check_line`
- Produces: パターン名 `missing-path`

- [ ] **Step 1: 失敗するテストを書く**

`test/check-comment-noise.bats` の末尾に足す:

```bash
@test "missing-path: 存在しないパスを止める" {
    put docs/real.md 'x'
    put a.sh '# 詳細: docs/missing.md を参照'
    run scan
    assert_failure 1
    assert_output --partial 'a.sh:1: [missing-path]'
    assert_output --partial 'docs/missing.md'
}

@test "missing-path: 実在するパスは句読点・行番号・アンカー付きでも通す" {
    put docs/real.md 'x'
    put a.sh $'# docs/real.md を参照。\n# (docs/real.md:12)\n# `docs/real.md#節`、\n# docs/ 配下'
    run scan
    assert_success
}

@test "missing-path: トップレベルのディレクトリで始まらないトークンは見ない" {
    put docs/real.md 'x'
    put a.sh $'# ~/docs/x と ~/.claude/x\n# lib/shell-reader.bash\n# https://example.com/docs/x\n# ../docs/x'
    run scan
    assert_success
}

@test "missing-path: プレースホルダ・テンプレート・glob・変数を含むパスは見ない" {
    put docs/real.md 'x'
    put a.sh $'# docs/<name>/x\n# docs/{a,b}/\n# docs/*.md\n# docs/$X/y\n# {{ .x }}/docs/y'
    run scan
    assert_success
}

@test "missing-path: CRLF の行でも実在するパスは通す" {
    put docs/real.md 'x'
    printf '# docs/real.md\r\n' >"$REPO/a.sh"
    git -C "$REPO" add a.sh
    run scan
    assert_success
}

@test "missing-path: ディレクトリへの参照も実在で判定する" {
    put docs/sub/real.md 'x'
    put a.sh $'# docs/sub/\n# docs/nosuch/'
    run scan
    assert_failure 1
    assert_output --partial 'a.sh:2: [missing-path]'
    refute_output --partial 'a.sh:1:'
}
```

- [ ] **Step 2: テストが失敗することを確かめる**

Run: `LC_ALL=C pnpm exec bats test/check-comment-noise.bats`
Expected: `missing-path: 存在しないパスを止める` と `ディレクトリへの参照も…` が FAIL(判定が無いので exit 0)。他の missing-path テストは判定が無くても通る(対比はStep 4 で取る)

- [ ] **Step 3: 実装する**

`scripts/check-comment-noise.sh` の `violations=0` の直前に足す:

```bash
# git 管理下のトップレベルのディレクトリ。先頭の要素がこれと一致するトークンだけを
# リポジトリ内のパスとみなす(~/ で始まる配置先のパスや、ファイルからの相対パスを避ける)
TOP_DIRS="$(git ls-files | grep / | cut -d/ -f1 | sort -u || true)"

is_top_dir() {
    case $'\n'"$TOP_DIRS"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    return 1
}

check_paths() {
    local file=$1 lineno=$2 text=$3 tokens token
    # パスに使う文字以外を区切りにする。:行番号・#アンカー・括弧・句読点・CR はここで落ちる
    tokens=$(printf '%s' "$text" | sed 's#[^A-Za-z0-9_./~{}<>*$-]# #g')
    for token in $tokens; do
        while [[ $token == *. ]]; do token=${token%.}; done
        [[ $token == */* ]] || continue
        case $token in *'{'* | *'}'* | *'<'* | *'>'* | *'*'* | *'$'*) continue ;; esac
        is_top_dir "${token%%/*}" || continue
        [[ -e $token ]] || report "$file" "$lineno" missing-path "$text"
    done
}
```

`check_line` の末尾(`issue-origin` の `fi` の後)に足す:

```bash
    check_paths "$file" "$lineno" "$text"
```

注意: 1 行に存在しないパスが 2 つあると 2 件報告される。どのパスかを出すため、`report` の text に該当行をそのまま渡し、トークン自体は出さない(行に含まれるので読める)。テストの `assert_output --partial 'docs/missing.md'` は該当行に含まれることで満たす。

- [ ] **Step 4: テストが通ることを確かめ、対比を取る**

Run: `LC_ALL=C pnpm exec bats test/check-comment-noise.bats`
Expected: 全件 PASS

対比の確認: `case $token in *'{'* …) continue` の行を一時的に消すと「プレースホルダ…」のテストが FAIL し、`is_top_dir … || continue` を消すと「トップレベルの…」のテストが FAIL することを確かめ、元に戻す。

- [ ] **Step 5: shellcheck / shfmt を通す**

Run: `just shellcheck && just shfmt`
Expected: 通る

- [ ] **Step 6: コミット**

```bash
git add scripts/check-comment-noise.sh test/check-comment-noise.bats
git commit -m "feat(scripts): コメント中の存在しないパスを検出する"
```

---

### Task 3: グローバルルール `code-comments.md` と Codex への連結

**Files:**
- Create: `dot_claude/rules/common/code-comments.md`
- Modify: `dot_codex/AGENTS.md.tmpl`(`{{ include "dot_claude/rules/common/shell-scripting.md" }}` の行の後)

**Interfaces:**
- Produces: `dot_claude/rules/common/code-comments.md`。Task 1 の lint の失敗メッセージがこのパスを指す。Task 4 の全体走査で、lint 自身のコメントの `RULE_FILE` 参照がこのファイルの実在に依存する

- [ ] **Step 1: ルールファイルを書く**

`dot_claude/rules/common/code-comments.md`:

```markdown
# コードコメント

コメントの読み手は、書いたときの会話も作業の経緯も持たずにファイルを開くエージェントと人間である。書き手の文脈を共有していない読み手を前提に書く。

## コードから読めない、今も成り立つことだけを書く

書くのは、理由・制約・前提・不採用にした案のうち、コードから読み取れないもの。コードが何をしているかの言い換えは書かない。

**理由:** 言い換えはコードとの二重管理になり、片方だけ直されて食い違う。食い違ったコメントは、コメントが無いよりも読み手を誤らせる。

## 経緯ではなく現在の事実を書く

「以前は〜」「〜で発覚」「〜に変更した」、日付つきの更新履歴、計画やタスクの内部番号(Task N)、コミット SHA は書かない。経緯はコミットメッセージ・PR・ADR に書く。

不採用にした案は残す。ただし現在形の事実として書く。

- 悪い例: 以前は `.zshrc` 経由の export で抑制しようとしたが、一度も効いていなかった
- 良い例: `.zshrc` での export では抑制できない。コマンドは非対話シェルで実行され `.zshrc` を読まないため

**理由:** 経緯の記述は書いた時点の文脈に依存し、読み手はそれが今も正しいかを判断できない。番号や日付は、参照先を持たない読み手には意味がない。一方で不採用案の記録が消えると、同じ案がまた試される。

## 正本を 1 つにする

他の文書(設計書・README・別ファイルのコメント)に書いてある内容を写さない。写す代わりに参照先を書く。

**理由:** 写しは正本の更新に追従せず、食い違ったときにどちらが正しいか読み手に分からない。

## 位置ではなく名前で参照する

「上の〜」「下の〜」「N 行目」のような位置での参照をしない。関数名・変数名・節の見出し・ファイルパスで参照する。

**理由:** 位置はコードの移動で黙ってずれ、向きが逆になっても誰も気づかない。名前は変わればリネームや grep で追える。

## コードを変えたら、関係するコメントも読み直す

変更した範囲のコメントと、変更したものを名前で参照しているコメントが、まだ正しいかを確かめる。

**理由:** コメントはテストされないので、コードの変更に置いていかれても何も失敗しない。
```

- [ ] **Step 2: 大きさを確かめる**

Run: `wc -c dot_claude/rules/common/code-comments.md`
Expected: 3072 バイト以下。超えたら「理由」の文を削って収める

- [ ] **Step 3: Codex の AGENTS.md に連結する**

`dot_codex/AGENTS.md.tmpl` の `{{ include "dot_claude/rules/common/shell-scripting.md" }}` の次の行に足す:

```
{{ include "dot_claude/rules/common/code-comments.md" }}
```

- [ ] **Step 4: グローバル指示のテストを通す**

Run: `just test-global-instructions`
Expected: 全件 PASS(rules の全件連結と 32 KiB 未満を含む)

対比の確認: Step 3 の行を一時的に消して `just test-global-instructions` が FAIL する(rules が全件入っていない)ことを確かめ、元に戻す。FAIL しない場合は、テストが rules を列挙する方法を読み、報告に書く。

- [ ] **Step 5: コミット**

```bash
git add dot_claude/rules/common/code-comments.md dot_codex/AGENTS.md.tmpl
git commit -m "feat(claude): コードコメントの書き方のルールを追加し、Codex にも連結する"
```

---

### Task 4: lint の組み込みと既存の違反の解消

**Files:**
- Create: `scripts/comment-noise-allowlist.txt`
- Modify: `justfile`(`test-sensitive` レシピの後に 2 レシピ、`lint` の依存に 2 つ)
- Modify: `.github/workflows/lint.yml`(`test-sensitive` ジョブの後に 2 ジョブ)
- Modify: `.pre-commit-config.yaml`(`scan-sensitive` フックの後に 1 フック)
- Modify: 走査で見つかった違反のあるファイル(少なくとも `.pre-commit-config.yaml` の shellcheck のコメント)

**Interfaces:**
- Consumes: Task 1・2 の `scripts/check-comment-noise.sh`、Task 3 のルールファイル
- Produces: `just check-comment-noise`、`just test-comment-noise`

- [ ] **Step 1: 許可リストを作る**

`scripts/comment-noise-allowlist.txt`:

```
# check-comment-noise.sh の例外。各行は <path-suffix or *>:<regex>。
# 例外にする理由を、その行の直前のコメントに書く。
```

- [ ] **Step 2: just のレシピを足す**

`justfile` の `test-sensitive` レシピの後に足す:

```make
# No file list is passed: the script walks `git ls-files` itself.
# Flag noise in code comments (plan step numbers, issue-origin notes, missing paths)
@check-comment-noise:
    bash scripts/check-comment-noise.sh

# LC_ALL=C for the bats-core locale bug: this suite's @test names are in Japanese.
# Smoke test check-comment-noise.sh
@test-comment-noise:
    LC_ALL=C pnpm exec bats test/check-comment-noise.bats
```

`lint:` 行の依存の `test-sensitive` の直後に ` check-comment-noise test-comment-noise` を足す。

- [ ] **Step 3: 走査して違反を洗い出す**

Run: `just check-comment-noise`
Expected: exit 1。少なくとも `.pre-commit-config.yaml:14: [issue-origin]`(`#309 Task 2 で発覚`。`plan-step` でも出る)

- [ ] **Step 4: 違反を 1 件ずつ直す**

各違反について、ルールファイル(`dot_claude/rules/common/code-comments.md`)に従い次のどちらかにする。

- 書き直す: 経緯の番号・計画の番号を消し、現在の事実として書く。存在しないパスは、今の正本のパスに直すか、参照ごと消す(参照先が消えた理由は `git log --follow -- <path>` で確かめる)
- 残す: 外部の文書の番号を指していて書き直すと意味が変わるもの、配置先のパスで誤検知しているもの(たとえば `.claude/` で始まる配置先のパスがリポジトリの `.claude/` と一致してしまう場合)は、許可リストに理由のコメントを添えて足す

既知の 1 件は次のように直す。`.pre-commit-config.yaml` の shellcheck のコメントの最終行を:

```yaml
        # されないと SC1091(info)が誤って出るため。
```

直したら再実行する。

Run: `just check-comment-noise`
Expected: 出力なしで exit 0

- [ ] **Step 5: CI のジョブを足す**

`.github/workflows/lint.yml` の `test-sensitive` ジョブの後に足す(action の SHA は同じファイルの既存ジョブと同じものを使う):

```yaml
  check-comment-noise:
    name: Check comment noise
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just check-comment-noise

  test-comment-noise:
    name: comment noise smoke tests
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: pnpm/action-setup@ea17c68df8912ef543352723c149a84f56e3d413 # v6.1.0
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with:
          node-version-file: '.node-version'
          cache: pnpm
      - run: pnpm install --frozen-lockfile
      - name: Install just
        run: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --tag 1.58.0 --to /usr/local/bin
      - run: just test-comment-noise
```

`test-comment-noise` の bats は一時ディレクトリで `git init` する。runner の git に user 設定が無くても `git add` だけなので動く。

- [ ] **Step 6: prek のフックを足す**

`.pre-commit-config.yaml` の `scan-sensitive` フックの後に足す:

```yaml
      # リポジトリ全体を走査するのでファイル名は渡さない
      - id: check-comment-noise
        name: check-comment-noise
        entry: bash scripts/check-comment-noise.sh
        language: system
        pass_filenames: false
        types: [text]
```

- [ ] **Step 7: 全体の lint を通す**

Run: `just lint`
Expected: 全レシピ成功(`check-comment-noise` と `test-comment-noise` を含む)

- [ ] **Step 8: コミット**

```bash
git add justfile .github/workflows/lint.yml .pre-commit-config.yaml scripts/comment-noise-allowlist.txt <Step 4 で直したファイル>
git commit -m "feat(ci): コメントのノイズ検出を just lint・CI・prek に組み込み、既存の違反を直す"
```

コミット時に prek の `check-comment-noise` フックが走り、通ることを確かめる。
