# chezmoi 描画のテスト用 seam 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** bats の 4 suite がそれぞれ組み立てている `chezmoi execute-template` を 1 つの seam(`test/helpers/render.bash`)に集め、その seam の上で work profile 専用の設定の契約テストを足す。

**Architecture:** seam は読み込まれた時点で chezmoi の実体を絶対パスで解決し、無ければ読み込み自体を失敗させる(skip にしない)。interface は `render_template <profile> <template>`(stdout に描画結果)と、`chezmoi managed` / `source-path` など描画以外のコマンドに渡す fixture のパスを返す `render_config <profile>` の 2 つ。profile は省略不可。全 profile を描画するのは `.profile` で分岐するテンプレートだけで、その一覧を `test/gitconfig.bats` の検知テストが固定する。

**Tech Stack:** bash、bats-core(bats-support / bats-assert)、chezmoi、git、just

**Spec:** 独立した spec 文書は無い。下の「決定事項」がこの plan の要件である(architecture review と grilling の結論)。

## 決定事項

- seam は新規ファイル `test/helpers/render.bash`。`test/helpers/setup.bash`(bats の読み込みだけを担う)には足さない。
- `render_template <profile> <template>`: `test/fixtures/chezmoi-<profile>.toml` を `--config`、リポジトリルートを `--source` にして描画し、stdout に出す。profile を省略・未知の値にしたら失敗する(暗黙に personal にしない)。テンプレートを stdin から渡したいときは `/dev/stdin` を渡す。
- `render_config <profile>`: fixture のパスを返す(`chezmoi managed` / `chezmoi source-path` 用)。存在しない profile は失敗。
- 読み込み時に chezmoi を `command -v` で絶対パスに解決し、見つからなければ stderr に理由を出して `return 1`(読み込みが失敗し、`setup_file` なら suite の test は 1 件も走らず、`setup` なら全 test が失敗する)。各 suite の「chezmoi が使える」`@test` と、`setup_file` 内の `command -v chezmoi` 検査は削除する。
- seam は呼び出し側の環境を引き継ぐ。PATH を差し替えたい suite は `PATH=… render_template …` と包む。chezmoi は読み込み時に絶対パスで解決済みなので PATH を狭めても見失わない。
- 移行対象: `test/settings-hooks.bats`、`test/gitconfig.bats`、`test/global-instructions.bats`、`test/nono-packs-script.bats`。`nono-packs-script.bats` の darwin 以外での skip は chezmoi と無関係なので suite 側に残し、skip 判定の後で seam を読み込む。
- `just check-templates` は seam を使わない(bats の helper を justfile に持ち込まない。profile の一覧は今どおり fixture の glob が正本)。ただし chezmoi が無いときは WARNING で素通りせず失敗させる。
- `test/helpers/render.bash` は `scripts/evaluator-paths.txt` に**載せない**(一覧の基準は Evaluator とその依存で、描画を使う suite はどれも載っていない)。
- `test/gitconfig.bats` の既存 4 件(push 契約)は personal だけで回す。
- work 専用の契約テスト: 描画した work の `~/.gitconfig` 越しに `git remote get-url` で、`git@github.com:o/r.git` と `ssh://git@github.com/o/r.git` が `https://github.com/o/r.git` に書き換わることを確かめる。personal では書き換わらないことを対比で確かめる。さらに work の描画結果に逆向き(値が `https://` で始まる `insteadOf`)のルールが無いことを確かめる。credential helper(GCM)は検査しない(CI に無い)。
- 検知テスト: 追跡中の `*.tmpl` と `.chezmoitemplates/*` のうち `.profile` を参照するものの一覧が `dot_gitconfig.tmpl` だけであることを `test/gitconfig.bats` で確かめる。一致しなくなったら、新しいテンプレートの profile ごとの契約テストを書くかを人が判断する。
- 「全 profile を描画するのは分岐のあるテンプレートだけ」という判断は、seam と検知テストのコメントに現在形の事実として書く。ADR と CONTEXT.md は変えない。

## Global Constraints

- コメント・コミットメッセージは日本語。経緯ではなく今も成り立つ事実を書く(`dot_claude/rules/common/code-comments.md`)。
- シェルは bash。`shellcheck -x` と `shfmt -i 4` を通す(`just lint` で確かめる。手組みしない)。
- bats の suite は justfile のレシピ経由で実行する(`LC_ALL=C pnpm exec bats …`)。新しい suite は作らない(作ると justfile と lint.yml の両方に足す必要がある。ADR 0013)。
- chezmoi が無いときは skip せず失敗させる(skip は CI で全検査を空振りさせる)。
- ブランチ名は `harness/review-` で始めない(justfile が Evaluator のパスに載っているため)。

## Review Focus

- **chezmoi が PATH に無い環境:** seam を読み込んだ suite が skip ではなく失敗し、理由(chezmoi が必要)が出力に出ること。Task 1 の Step 1 で `PATH` から chezmoi を外した実行を確かめる。
- **存在しない profile:** `render_template staging …` が空文字の描画結果で成功せず、失敗すること(空の描画結果で後続の grep が空振りするのを防ぐ)。Task 1 のテストで固定する。
- **PATH を差し替えた描画:** `PATH="$FAKE_BIN:/usr/bin:/bin" render_template …` で chezmoi を見失わないこと。Task 4 の nono-packs の既存テストが通ることで確かめる。
- **stdin からのテンプレート:** `printf '{{ template "…" }}' | render_template personal /dev/stdin` が描画されること。Task 3 の global-instructions の既存テストで確かめる。
- **work の描画結果に personal 用の設定が混ざっても push 契約は personal でしか見ない:** 既存 4 件の結果が変わらないこと。Task 2 で確かめる。

---

### Task 1: seam(`test/helpers/render.bash`)を作り、gitconfig.bats を移行して work の契約テストと検知テストを足す

**Files:**
- Create: `test/helpers/render.bash`
- Modify: `test/gitconfig.bats`

**Interfaces:**
- Produces: `render_template <profile> <template-path>`(stdout に描画結果。失敗時は非 0)、`render_config <profile>`(fixture の絶対パスを stdout)、変数 `RENDER_REPO`(リポジトリルートの絶対パス)、`RENDER_CHEZMOI`(chezmoi の絶対パス)。

- [ ] **Step 1: seam を書く**

```bash
# test/helpers/render.bash
# chezmoi テンプレートを Machine Profile の fixture で描画する、テスト用の唯一の seam。
#
# 読み込んだ時点で chezmoi を絶対パスに解決し、無ければ読み込みごと失敗する。
# skip にしないのは、CI で描画を使う検査が全部素通りして緑になるため。
# setup_file で読み込めば suite の test は 1 件も走らず、setup で読み込めば全 test が失敗する。
#
# 呼び出し側の環境をそのまま引き継ぐ。PATH を差し替えて描画したい suite は
# `PATH=… render_template …` と包む。chezmoi は絶対パスで呼ぶので PATH を狭めても見失わない。
#
# profile の一覧は test/fixtures/chezmoi-<profile>.toml の実ファイルが正本。
# profile ごとに描画して契約を見るのは .profile で分岐するテンプレートだけで、
# その一覧は test/gitconfig.bats の検知テストが固定している。

RENDER_REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
RENDER_CHEZMOI="$(command -v chezmoi)" || {
    echo "chezmoi が必要(描画を使う suite は skip しない)" >&2
    return 1
}
export RENDER_REPO RENDER_CHEZMOI

# render_config PROFILE: その profile の fixture の絶対パスを出す
render_config() {
    local config="$RENDER_REPO/test/fixtures/chezmoi-$1.toml"
    [ -n "$1" ] && [ -f "$config" ] || {
        echo "render: profile '$1' の fixture がありません: $config" >&2
        return 1
    }
    printf '%s\n' "$config"
}

# render_template PROFILE TEMPLATE: TEMPLATE を PROFILE の fixture で描画して stdout に出す。
# テンプレートを stdin から渡すときは TEMPLATE に /dev/stdin を渡す
render_template() {
    local config
    config=$(render_config "$1") || return 1
    "$RENDER_CHEZMOI" execute-template --config "$config" --source "$RENDER_REPO" <"$2"
}
```

注意: `$BATS_TEST_DIRNAME` はこのリポジトリの全 suite で `test/` を指す(`test/helpers/setup.bash` の冒頭コメントと同じ前提)。

- [ ] **Step 2: gitconfig.bats の setup_file を seam に置き換え、personal と work の両方を描画する**

`setup_file` の `command -v chezmoi` 検査と `execute-template` の組み立てを削除し、次にする。ファイル冒頭コメントの「chezmoi が無い場合は skip せず fail する」の行は、seam が担うことに書き換える。

```bash
setup_file() {
    load 'helpers/render'
    export GITCONFIG_PERSONAL="$BATS_FILE_TMPDIR/gitconfig-personal"
    export GITCONFIG_WORK="$BATS_FILE_TMPDIR/gitconfig-work"
    render_template personal "$RENDER_REPO/dot_gitconfig.tmpl" >"$GITCONFIG_PERSONAL"
    render_template work "$RENDER_REPO/dot_gitconfig.tmpl" >"$GITCONFIG_WORK"
}
```

`setup` の `cp "$GITCONFIG_RENDERED" "$HOME/.gitconfig"` を `cp "$GITCONFIG_PERSONAL" "$HOME/.gitconfig"` にする。既存 4 件の `@test` 本体は変えない。`setup` 内の `REPO` 変数(テスト用の git リポジトリ)はそのまま。

- [ ] **Step 3: 既存 4 件が通ることを確かめる**

Run: `just test-gitconfig`
Expected: 4 tests, 0 failures

chezmoi が無いときに skip ではなく失敗することを一度だけ確かめる: chezmoi を含まない PATH(例: `env PATH="$(dirname "$(command -v bats || echo /usr/bin/bats)"):/usr/bin:/bin"`。pnpm 経由の bats が動く最小の PATH を作る)で `pnpm exec bats test/gitconfig.bats` を実行し、出力に「chezmoi が必要」が出て非 0 で終わること、`skip` の行が出ないことを見る。最小の PATH を作れない場合は、`test/helpers/render.bash` の `command -v chezmoi` を一時的に `command -v chezmoi-not-installed` に変えて同じことを見てから元に戻す(コミットしない)。

- [ ] **Step 4: work の契約テストと対比を足す(先に書いて、Step 5 で通ることを見る)**

`setup` で `GIT_CONFIG_GLOBAL` は `claude-code.inc`(`~/.gitconfig` を include する)を指しているので、`~/.gitconfig` を work の描画結果に差し替えれば Claude Code の git と同じ経路で検査できる。

```bash
# work では SSH 形式の GitHub remote を HTTPS に寄せる(dot_gitconfig.tmpl の work 分岐のコメントに理由)。
# 書き換えは git remote get-url の出力に現れるので、ネットワークなしで確かめられる
@test "work: scp 形式と ssh:// 形式の GitHub remote が https に書き換わる" {
    cp "$GITCONFIG_WORK" "$HOME/.gitconfig"
    git -C "$REPO" remote add scp git@github.com:o/r.git
    git -C "$REPO" remote add sshurl ssh://git@github.com/o/r.git

    run git -C "$REPO" remote get-url scp
    assert_success
    assert_output 'https://github.com/o/r.git'

    run git -C "$REPO" remote get-url sshurl
    assert_success
    assert_output 'https://github.com/o/r.git'
}

@test "対比: personal では GitHub の SSH remote は書き換わらない" {
    git -C "$REPO" remote add scp git@github.com:o/r.git

    run git -C "$REPO" remote get-url scp
    assert_success
    assert_output 'git@github.com:o/r.git'
}

# https→ssh の逆向きルールと共存させると ssh→https が効かなくなる(dot_gitconfig.tmpl の work 分岐のコメント)
@test "work: https から書き換える逆向きの insteadOf が無い" {
    run git config --file "$GITCONFIG_WORK" --get-regexp '^url\..*\.insteadof$'
    assert_success
    refute_line --regexp ' https://'
}
```

`git config --file` は `includeIf` を辿らないが、検査対象は描画した `~/.gitconfig` 本体なのでそれでよい。

- [ ] **Step 5: work の契約テストが通ることを確かめる**

Run: `just test-gitconfig`
Expected: 7 tests, 0 failures

逆向きルールの検査が実際に失敗を捕まえることを一度だけ確かめる(コミットしない): `printf '[url "git@github.com:"]\n  insteadOf = https://github.com/\n' >>` を `setup_file` の work 描画の直後に一時的に足して `just test-gitconfig` を実行し、「逆向きの insteadOf が無い」と「https に書き換わる」の少なくとも 1 件が失敗するのを見てから元に戻す。

- [ ] **Step 6: `.profile` 分岐の検知テストを足す**

```bash
# profile ごとに描画して契約を見るのは .profile で分岐するテンプレートだけ(test/helpers/render.bash)。
# 分岐するテンプレートが増えたらこのテストが落ちる。そのテンプレートの profile ごとの
# 契約テストを書くかを判断してから、一覧を更新すること
@test ".profile で分岐するテンプレートは既知の一覧と一致する" {
    run bash -c 'cd "$1" && git ls-files -z -- "*.tmpl" ".chezmoitemplates/*" | xargs -0 grep -lwF ".profile" | LC_ALL=C sort' _ "$RENDER_REPO"
    assert_success
    assert_output 'dot_gitconfig.tmpl'
}
```

`RENDER_REPO` は `setup_file` で export 済みなので test から読める。`setup_file` で `load` した関数は test のプロセスに引き継がれないので、test 内で `render_template` を呼ぶ suite は `setup` でも `load 'helpers/render'` すること(このテストは関数を使わない)。

- [ ] **Step 7: 検知テストが通り、増えたら落ちることを確かめる**

Run: `just test-gitconfig`
Expected: 8 tests, 0 failures

一時的に任意の `.tmpl` に `{{/* .profile */}}` を足して `git add` し、検知テストが失敗することを見てから元に戻す(コミットしない。`git restore --staged` と `git restore` で戻す)。

- [ ] **Step 8: lint を通してコミット**

Run: `just shellcheck shfmt`
Expected: エラーなし

```bash
git add test/helpers/render.bash test/gitconfig.bats
git commit -m "test(chezmoi): 描画のテスト用 seam を作り、work profile の gitconfig 契約を検査する"
```

---

### Task 2: settings-hooks.bats を seam に移行する

**Files:**
- Modify: `test/settings-hooks.bats`(冒頭コメント :8-16、`setup_file` :18-32、`chezmoi source-path` の呼び出し :100)

**Interfaces:**
- Consumes: `render_template`、`render_config`、`RENDER_REPO`、`RENDER_CHEZMOI`(Task 1)

- [ ] **Step 1: setup_file を書き換える**

`command -v chezmoi` 検査と `execute-template` の組み立てを削除する。`CONFIG` は `chezmoi source-path` が使うので `render_config` から得る。

```bash
setup_file() {
    load 'helpers/render'
    export REPO="$RENDER_REPO"
    export TMPDIR="$BATS_FILE_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    CONFIG=$(render_config personal)
    export CONFIG
    export DEST="$BATS_FILE_TMPDIR/home"
    mkdir -p "$DEST"
    export SETTINGS="$BATS_FILE_TMPDIR/settings.json"
    render_template personal "$REPO/dot_claude/settings.json.tmpl" >"$SETTINGS"
}
```

:100 の `chezmoi source-path` は `"$RENDER_CHEZMOI" source-path` にする(PATH に依存しない呼び方をそろえる)。冒頭コメントの「seam は 1 つだけ: `chezmoi execute-template …`」は「描画は test/helpers/render.bash を通す」に、「chezmoi が無い場合は skip せず fail する」「chezmoi の有無は…ここで見る」は seam が担う旨の 1 行に書き換える。

- [ ] **Step 2: テストが通ることを確かめる**

Run: `just test-settings-hooks`
Expected: 移行前と同じ件数、0 failures(移行前の件数を先に `just test-settings-hooks` で控えておく)

- [ ] **Step 3: コミット**

```bash
git add test/settings-hooks.bats
git commit -m "test(settings): settings.json の描画を render seam に寄せる"
```

---

### Task 3: global-instructions.bats を seam に移行する

**Files:**
- Modify: `test/global-instructions.bats`(冒頭コメント :4-9、`setup` :10-18、`render` :20-23、`@test "chezmoi が使える…"` :33-37、:59、:89、:92、:207/:214/:224 の `chezmoi managed`)

**Interfaces:**
- Consumes: `render_template`、`render_config`、`RENDER_REPO`、`RENDER_CHEZMOI`(Task 1)

- [ ] **Step 1: 移行前の件数を控える**

Run: `just test-global-instructions`
Expected: 全件 PASS。件数を控える(移行後は「chezmoi が使える」1 件だけ減る)

- [ ] **Step 2: setup と render を書き換える**

```bash
setup() {
    load 'helpers/setup'
    load 'helpers/render'
    REPO="$RENDER_REPO"
    export TMPDIR="$BATS_TEST_TMPDIR/tmp"
    mkdir -p "$TMPDIR"
    CONFIG=$(render_config personal)
    SHARED="$REPO/.chezmoitemplates/agent-instructions-common"
    RULES_DIR="$REPO/dot_claude/rules/common"
}

render_claude() {
    render_template personal "$REPO/dot_claude/CLAUDE.md.tmpl"
}

render_codex() {
    render_template personal "$REPO/dot_codex/AGENTS.md.tmpl"
}
```

suite 内の `render` 関数は削除し、`render "<path>"` を呼んでいる箇所があれば `render_template personal "<path>"` にする。`@test "chezmoi が使える(この suite は skip しない)"` は削除する。

- [ ] **Step 3: 直接 chezmoi を呼んでいる箇所を置き換える**

- :59 の `printf '{{ template "agent-instructions-common" }}' | chezmoi execute-template --config "$CONFIG" --source "$REPO"` → `printf '{{ template "agent-instructions-common" }}' | render_template personal /dev/stdin`
- :89 と :92 の `run bash -c '… chezmoi execute-template … | grep …'` は、関数が `bash -c` の中に見えないので、描画をシェル変数に取ってから grep する形にする。

```bash
    local claude codex
    claude=$(render_claude)
    codex=$(render_codex)
    run grep -c AskUserQuestion <<<"$claude"
    # (元の assert をそのまま続ける)
    run grep -n AskUserQuestion <<<"$codex"
    # (元の assert をそのまま続ける)
```

`set -o pipefail` で守っていた「描画の失敗を grep の結果で隠さない」は、`claude=$(render_claude)` が失敗すれば bats が test を失敗させることで保たれる。元の assert(件数や出力の期待値)は変えない。

- :207/:214/:224 の `chezmoi managed` は `"$RENDER_CHEZMOI" managed` にする(`--config "$CONFIG"` はそのまま)。
- 冒頭コメントの「seam は 1 つだけ: `chezmoi execute-template …`」を「描画は test/helpers/render.bash を通す」に、chezmoi 必須の段落は seam が担う旨と CI の job 名(lint.yml の global-instructions job が chezmoi を入れる)だけを残す形に書き換える。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `just test-global-instructions`
Expected: Step 1 の件数 − 1、0 failures

- [ ] **Step 5: コミット**

```bash
git add test/global-instructions.bats
git commit -m "test(instructions): グローバル指示の描画を render seam に寄せる"
```

---

### Task 4: nono-packs-script.bats を seam に移行する

**Files:**
- Modify: `test/nono-packs-script.bats`(`setup` :11-24、`render` :37-41、`@test "chezmoi が使える"` :43-46)

**Interfaces:**
- Consumes: `render_template`(Task 1)

- [ ] **Step 1: setup と render を書き換える**

darwin 以外の skip を先に判定し、その後で seam を読み込む(ubuntu の CI で chezmoi の有無と無関係に skip させるため)。

```bash
setup() {
    load 'helpers/setup'
    if [ "$(uname -s)" != "Darwin" ]; then
        skip "template is darwin-only"
    fi
    load 'helpers/render'
    TMPL="${RENDER_REPO}/.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl"
    FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "${FAKE_BIN}"
    CALLS="${BATS_TEST_TMPDIR}/calls"
    export CALLS
}

# 偽 nono だけが見える PATH でテンプレートを描画する
render() {
    PATH="${FAKE_BIN}:/usr/bin:/bin" render_template personal "${TMPL}"
}
```

`REPO` / `CONFIG` / `CHEZMOI` 変数が suite の他の箇所で使われていないことを `grep -n 'REPO\|CONFIG\|CHEZMOI' test/nono-packs-script.bats` で確かめ、使われていれば `RENDER_REPO` などに置き換える。`@test "chezmoi が使える"` は削除する。

- [ ] **Step 2: テストが通ることを確かめる**

Run: `just test-nono-packs`
Expected: 移行前の件数 − 1、0 failures(darwin で実行する。移行前の件数を先に控える)

- [ ] **Step 3: コミット**

```bash
git add test/nono-packs-script.bats
git commit -m "test(nono): nono packs スクリプトの描画を render seam に寄せる"
```

---

### Task 5: check-templates を chezmoi 必須にする

**Files:**
- Modify: `justfile`(`check-templates` レシピの `else` 節、:157-159 付近)

- [ ] **Step 1: else 節を失敗に変える**

```just
    else
        # 描画を伴う検査は chezmoi が無ければ素通りせず失敗させる(test/helpers/render.bash と同じ方針)
        echo "FAIL: chezmoi not found (check-templates は skip しない)"
        exit 1
    fi
```

- [ ] **Step 2: chezmoi がある状態で通り、無い状態で落ちることを確かめる**

Run: `just check-templates`
Expected: `PASS: all templates valid (profiles: personal work)`

Run: `env PATH=/usr/bin:/bin "$(command -v just)" check-templates`
Expected: `FAIL: chezmoi not found …` と exit 1(`/usr/bin:/bin` に chezmoi が無いことが前提。あれば別の空ディレクトリを PATH にする)

- [ ] **Step 3: 全体の lint を通してコミット**

Run: `just lint`
Expected: 全レシピ PASS

```bash
git add justfile
git commit -m "chore(just): check-templates は chezmoi が無ければ失敗させる"
```
