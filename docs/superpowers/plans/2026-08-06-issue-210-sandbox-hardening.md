# issue #210 残存課題対応 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** GitHub issue #210 の残存課題のうち3項目（statuslineへのサンドボックス経路インジケータ追加、`check-templates`のJSON妥当性検証追加、nonoプロファイルの行動smoke test追加）を実装する。

**Architecture:** 3つの独立した小規模変更。①は`dot_claude/statusline-command.ts`への1行追加、③は`justfile`の`check-templates`レシピへの`jq empty`検証追加、④は`test/nono-profile.bats`への`nono why`ベースのテストケース追加。相互に依存関係はない。

**Tech Stack:** TypeScript (Node, `--experimental-strip-types`)、bash (`justfile`/`just`)、bats-core (`bats-support`/`bats-assert`)、`jq`、`nono` CLI。

## Global Constraints

- 新規ドキュメント・コードコメント・コミットメッセージは日本語で記載する（既存英語ファイルへの追記部分も日本語）。
- `docs/` 配下のファイルはリポジトリに追跡・コミットされる。PII/機微情報を含めない。
- `nono` 依存のテストは「ローカル専用（CI未インストール）」の既存パターンを踏襲し、`command -v nono` が無い場合は必ず `skip` する。
- コード修正後は対応する `just` レシピ（`oxlint`/`oxfmt`/`test-nono-profile`/`check-templates`）を実行し、グリーンを確認してからコミットする。
- 各タスクは独立してコミットする（バッチでまとめない）。

---

### Task 1: statusline に nono/native 経路インジケータを追加

**Files:**
- Modify: `dot_claude/statusline-command.ts:172-184`（`main()`内、line1組み立て部分）

**Interfaces:**
- Consumes: なし（既存の`process.env`のみ）
- Produces: なし（statuslineの表示行への追加のみ、他タスクから参照されない）

- [ ] **Step 1: line1に経路インジケータを追加する**

`dot_claude/statusline-command.ts`の`main()`内、以下の既存コード:

```typescript
    let line1 = `🤖 ${model}`;
    line1 += `${sep}📁 ${dirName}`;
    line1 += `${sep}${ctxColor}📊 ${contextPct}%${RESET}`;
    line1 += `${sep}✏️  +${added}/-${deleted}`;
    if (branch) {
      line1 += `${sep}🔀 ${branch}`;
    }
```

を、以下に置き換える（`branch`のif文の直後に経路インジケータを追加）:

```typescript
    let line1 = `🤖 ${model}`;
    line1 += `${sep}📁 ${dirName}`;
    line1 += `${sep}${ctxColor}📊 ${contextPct}%${RESET}`;
    line1 += `${sep}✏️  +${added}/-${deleted}`;
    if (branch) {
      line1 += `${sep}🔀 ${branch}`;
    }
    const sandboxLabel = process.env.INSIDE_NONO_SANDBOX ? "🔒 nono" : "🔓 native";
    line1 += `${sep}${sandboxLabel}`;
```

- [ ] **Step 2: 型チェック・lintを実行する**

Run: `pnpm exec oxlint dot_claude/statusline-command.ts && pnpm exec oxfmt --check dot_claude/statusline-command.ts`
Expected: どちらもエラーなしで終了

- [ ] **Step 3: 動作確認（手動）**

Run:
```sh
echo '{}' | node --experimental-strip-types dot_claude/statusline-command.ts
```
Expected: 1行目末尾に `🔓 native` が表示される（`INSIDE_NONO_SANDBOX`が未設定のシェルで実行した場合）。

続けて:
```sh
INSIDE_NONO_SANDBOX=1 sh -c 'echo "{}" | node --experimental-strip-types dot_claude/statusline-command.ts'
```
Expected: 1行目末尾に `🔒 nono` が表示される。

- [ ] **Step 4: Commit**

```bash
git add dot_claude/statusline-command.ts
git commit -m "feat(statusline): サンドボックス経路インジケータを追加

INSIDE_NONO_SANDBOX環境変数の有無でnono経由/native経由を表示する。
実際にサンドボックスが有効かの検証ではなく、どちらの経路で起動しているかの可視化に限定する。

Ref: issue #210"
```

---

### Task 2: `check-templates` にJSON妥当性検証を追加

**Files:**
- Modify: `justfile`（`check-templates`レシピ、現在122行目付近）

**Interfaces:**
- Consumes: なし
- Produces: なし（`just lint`から呼ばれる独立レシピ）

- [ ] **Step 1: 意図的に壊れたJSONで現状のFAILしない挙動を確認する（RED相当）**

まず現状の`check-templates`が構文的に壊れたJSONを検出しないことを確認する。

Run:
```sh
cp dot_claude/settings.json.tmpl /tmp/settings.json.tmpl.orig
# "language" キーの後にカンマを1つ余分に追加して壊す
sed -i '' 's/"language": "japanese",/"language": "japanese",,/' dot_claude/settings.json.tmpl
just check-templates
```
Expected: 現状の実装では `PASS: all templates valid` と表示されてしまう（レンダリングは成功するがJSONとしては壊れているため、これがissue #210が指摘する既存の欠陥）。

Run（必ず元に戻す）:
```sh
cp /tmp/settings.json.tmpl.orig dot_claude/settings.json.tmpl
rm /tmp/settings.json.tmpl.orig
```

- [ ] **Step 2: `check-templates`レシピにJSON検証を追加する**

`justfile`の`check-templates`レシピ:

```make
check-templates:
    #!/usr/bin/env bash
    if command -v chezmoi >/dev/null 2>&1; then
        echo "Validating chezmoi templates..."
        tmpconfig=$(mktemp "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml") || { echo "FAIL: mktemp failed"; exit 1; }
        printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
        fail=0
        for file in {{tmpl_files}}; do
            chezmoi execute-template \
                --config "$tmpconfig" \
                --source "$(pwd)" \
                < "$file" > /dev/null || { echo "FAIL: $file"; fail=1; }
        done
        rm -f "$tmpconfig"
        if [ "$fail" -eq 1 ]; then exit 1; fi
        echo "PASS: all templates valid"
```

を、以下に置き換える:

```make
check-templates:
    #!/usr/bin/env bash
    if command -v chezmoi >/dev/null 2>&1; then
        echo "Validating chezmoi templates..."
        tmpconfig=$(mktemp "${TMPDIR:-/tmp}/chezmoi-test-XXXXXX.toml") || { echo "FAIL: mktemp failed"; exit 1; }
        printf '[data]\n  profile = "personal"\n  ghOrg = "test-org"\n' > "$tmpconfig"
        fail=0
        for file in {{tmpl_files}}; do
            rendered=$(chezmoi execute-template \
                --config "$tmpconfig" \
                --source "$(pwd)" \
                < "$file") || { echo "FAIL: $file (render)"; fail=1; continue; }
            case "$file" in
                *.json.tmpl)
                    echo "$rendered" | jq empty 2>/dev/null || { echo "FAIL: $file (invalid JSON)"; fail=1; }
                    ;;
            esac
        done
        rm -f "$tmpconfig"
        if [ "$fail" -eq 1 ]; then exit 1; fi
        echo "PASS: all templates valid"
```

- [ ] **Step 3: 壊れたJSONで新実装がFAILすることを確認する（GREEN相当その1）**

Run:
```sh
cp dot_claude/settings.json.tmpl /tmp/settings.json.tmpl.orig
sed -i '' 's/"language": "japanese",/"language": "japanese",,/' dot_claude/settings.json.tmpl
just check-templates
echo "exit: $?"
cp /tmp/settings.json.tmpl.orig dot_claude/settings.json.tmpl
rm /tmp/settings.json.tmpl.orig
```
Expected: `FAIL: ./dot_claude/settings.json.tmpl (invalid JSON)` が出力され、`exit: 1`。

- [ ] **Step 4: 正常な状態でPASSすることを確認する（GREEN相当その2）**

Run: `just check-templates`
Expected: `PASS: all templates valid` が出力され、exit 0。

- [ ] **Step 5: Commit**

```bash
git add justfile
git commit -m "fix(lint): check-templatesにJSON妥当性検証を追加

*.json.tmplのレンダリング結果をjq emptyでパース検証する。
従来はレンダリング成功のみをチェックしており、構文的に壊れたJSON
(カンマの過不足等)を検出できなかった。

Ref: issue #210, docs/solutions/integration-issues/check-templates-render-only-no-json-validation.md"
```

---

### Task 3: nono プロファイルの行動smoke testを追加

**Files:**
- Modify: `test/nono-profile.bats`

**Interfaces:**
- Consumes: なし
- Produces: なし

- [ ] **Step 1: 失敗する（存在しない）テストを書く**

`test/nono-profile.bats`の末尾に以下を追加する（既存の`validates against the nono profile schema`テストの後）:

```bash

@test "claude-seal profile denies read on SSH private key" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    run nono why --path "$HOME/.ssh/id_rsa" --op read --profile claude-seal
    assert_success
    assert_output --partial "DENIED"
}

@test "claude-seal profile allows read on \$HOME/ghq (contrast pair)" {
    if ! command -v nono >/dev/null 2>&1; then
        skip "nono not installed"
    fi
    run nono why --path "$HOME/ghq" --op read --profile claude-seal
    assert_success
    assert_output --partial "ALLOWED"
}
```

- [ ] **Step 2: テストを実行して両方PASSすることを確認する**

Run: `pnpm exec bats test/nono-profile.bats`
Expected: 3件とも `ok`（既存のスキーマ検証テスト + 新規2件）。

nonoがローカルにインストール済みであることを前提とする。未インストール環境では2件とも `skip` になる。

- [ ] **Step 3: 対比検証 — allow側テストが実際にプロファイル設定を見ているか確認する**

一時的に`dot_config/nono/profiles/claude-seal.json`の`filesystem.allow`から`"$HOME/ghq"`を削除し、Step 2のallow側テストが`ALLOWED`ではなくなる（failする)ことを確認してから元に戻す。

Run:
```sh
cp dot_config/nono/profiles/claude-seal.json /tmp/claude-seal.json.orig
# "$HOME/ghq" のエントリを削除
jq 'del(.filesystem.allow[] | select(. == "$HOME/ghq"))' /tmp/claude-seal.json.orig > dot_config/nono/profiles/claude-seal.json
pnpm exec bats test/nono-profile.bats
echo "exit: $?"
cp /tmp/claude-seal.json.orig dot_config/nono/profiles/claude-seal.json
rm /tmp/claude-seal.json.orig
```
Expected: `claude-seal profile allows read on $HOME/ghq (contrast pair)` が `not ok` になる（`$HOME/ghq`の`allow`エントリが実体として効いていることの確認）。

- [ ] **Step 4: 元に戻した状態で再度PASSすることを確認する**

Run: `pnpm exec bats test/nono-profile.bats`
Expected: 3件とも `ok`。

- [ ] **Step 5: Commit**

```bash
git add test/nono-profile.bats
git commit -m "test(nono): denyRead/allowパスの行動検証テストを追加

nono why --path --op --profile による静的ポリシー解決を使い、
認証情報パス(~/.ssh/id_rsa)がDENIEDになること、対比として
filesystem.allowに明記された$HOME/ghqがALLOWEDになることを検証する。
nono why はファイルの実在に依存しないため、cat等での検証にありがちな
「ファイル不在による失敗」と「サンドボックス拒否」の混同を避けられる。

Ref: issue #210"
```

---

### Task 4: issue #210 へのコメント・状況更新

**Files:**
- なし（GitHub issue操作のみ）

**Interfaces:**
- Consumes: Task 1-3のコミットハッシュ
- Produces: なし

- [ ] **Step 1: issue #210 に対応状況をコメントする**

Run:
```sh
gh issue comment 210 --repo tanimon/dotfiles --body "$(cat <<'EOF'
## 対応状況の更新

- ① `failIfUnavailable` の可視化: statuslineに `🔒 nono` / `🔓 native` の経路インジケータを追加した（対応コミット参照）。ライブなサンドボックス有効性API自体がClaude Codeに存在しないため、「無音のfail-openを検知する」ことはできない — あくまで起動経路（nonoラップ / `command claude` raw）の可視化に限定している。
- ② safehouse撤去時のパリティ再監査: PR #241でsafehouseをnonoへ移行済みで、gstack/Playwrightキャッシュ等の既知パスはnonoプロファイルに移植済み。本issueが前提としていた「native sandboxを唯一の経路にする」シナリオ自体が発生しなかったため、この項目は対応不要と判断。クローズ候補とする。
- ③ `check-templates` のJSON検証: `justfile`の`check-templates`レシピに`jq empty`によるJSON妥当性検証を追加した。
- ④ サンドボックスのsmoke test: nono側は`nono why`を使った行動検証テスト（denyRead/allowの対比ペア）を`test/nono-profile.bats`に追加した。ネイティブBashサンドボックス（Seatbelt/bubblewrap）側の行動検証は、単体CLIとして呼び出す手段がなく`claude -p`ヘッドレス実行が必要（API費用・非決定性の問題）なため、今回は対応せず既知の限界として記録する。

残タスクは④のネイティブサンドボックス側行動検証のみ。対応するかは別途判断。
EOF
)"
```
Expected: コメントが投稿される。

- [ ] **Step 2: ②の解消を踏まえてissueをクローズするか確認する**

このステップは実装者ではなく人間の判断が必要 — Task 4 Step 1のコメント投稿後、issueをクローズするかどうかをユーザーに確認する（③④が完全housed事項ではなく、④のネイティブ側が未解決のまま残るため、クローズせず開いたままにするのがデフォルト判断)。

Run: (判断待ち、コマンドなし)

---

# 完了条件

- Task 1-3の実装がそれぞれ独立してコミットされている
- `just lint` がすべてグリーン（`oxlint`/`oxfmt`/`check-templates`/`test-nono-profile`含む）
- issue #210 に対応状況のコメントが投稿されている
