---
title: "issue #210 残存課題への対応 — サンドボックス可視化・テンプレート検証・nono行動テスト"
date: 2026-08-06
status: approved
related_issue: "https://github.com/tanimon/dotfiles/issues/210"
---

# 背景

issue #210 は PR #209（ネイティブ Bash サンドボックス有効化）レビューで検出した残リスク・テストギャップの追跡issue。現状確認の結果、4項目中2項目（①`failIfUnavailable`の無音フォールバック、③`check-templates`のJSON検証欠如）は未対応、1項目（④サンドボックスsmoke test）は部分対応（スキーマ検証のみ）、1項目（②safehouse撤去時のパリティ再監査）はPR #241でのnono移行により実質解消済みと判明した。本ドキュメントは残る①③④への対応を設計する。②はissue側にコメントを残しクローズ候補とする（本設計のスコープ外）。

## 調査で判明した制約

- Claude Codeの`sandbox`設定スキーマは`enabled`/`failIfUnavailable`/`network.*`/`filesystem.*`/`excludedCommands`のみで、「現在サンドボックスが実際に有効か」を示すライブAPIは存在しない（`docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md:150`）。statuslineのようなセッション外プロセスから、無音でfail-openした状態をリアルタイム検出することは技術的に不可能。
- `INSIDE_NONO_SANDBOX=1`は`dot_config/nono/profiles/claude-seal.json`の`environment.set_vars`で注入される決定的シグナルで、「nonoラップ経路(`claude`)か raw経路(`command claude`)か」は判別可能。
- ネイティブBashサンドボックス（Seatbelt/bubblewrap）は単体CLIとして呼び出す手段がなく、行動検証には実際のBashツール呼び出し（`claude -p`ヘッドレス実行）が必要で、API費用・非決定性の問題がある。
- nonoは`nono why --path <path> --op <read|write> --profile <name>`という静的ポリシー解決CLIを持ち、対象パスの実在に依存せず`ALLOWED`/`DENIED`を決定論的に返す。行動検証はnono側でのみ、費用なしで実現できる。

# 設計

## ① statusline: nono / raw経路インジケータ

**対象ファイル:** `dot_claude/statusline-command.ts`

`main()`内、`line1`組み立て箇所に1項目追加する。

```typescript
const sandboxLabel = process.env.INSIDE_NONO_SANDBOX ? "🔒 nono" : "🔓 native";
line1 += `${sep}${sandboxLabel}`;
```

- 判定は`INSIDE_NONO_SANDBOX`環境変数の有無のみ。真偽の実効性（サンドボックスが本当に効いているか）までは主張しない — 「どちらの経路で起動しているか」の可視化に限定する。
- statuslineプロセスはClaude Codeの子プロセスとして起動されるため、nono経由セッションでは`INSIDE_NONO_SANDBOX`を継承する。
- 新規依存なし。既存の`StatusLineInput`型やエラーハンドリング（try/catchでフォールバック表示）に影響しない、独立した1行追加。

## ③ `check-templates` のJSON妥当性検証

**対象ファイル:** `justfile`（`check-templates`レシピ）

現状、各`.tmpl`ファイルをレンダリングして`/dev/null`に流し、exit codeのみ見ている。JSON形式のテンプレート（現状`dot_claude/settings.json.tmpl`のみ、将来増える可能性を考慮し拡張子で判定）は、レンダリング成功後に`jq empty`へパイプし、パース可否を追加検証する。

```sh
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
```

- `jq`は既に他レシピ（`scan-sensitive`等）で前提とされている依存のため新規追加なし。
- レンダリング失敗（既存チェック）とJSON妥当性失敗（新規チェック）を両方とも`fail=1`に集約し、最終的に`exit 1`する既存の集約ロジックを踏襲する。
- コンテンツ検証（特定キーの値が正しいか等）はスコープ外 — `docs/solutions/integration-issues/check-templates-render-only-no-json-validation.md`が言う「構文妥当性のみ」の範囲に留める。

## ④ nono プロファイルの実動作smoke test

**対象ファイル:** `test/nono-profile.bats`

既存の`nono profile validate`（スキーマ検証）はそのまま維持し、`nono why`を使った行動検証テストを追加する。

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

- `nono why`はポリシー解決のみを行う静的診断コマンドで、対象パスの実在に依存しない（`cat`等での検証だと「ファイルが存在しないための失敗」と「サンドボックスによる拒否」が区別できず、issue #210自体が懸念する「無音の境界消失」と同じ穴になる）。
- 2件目（allow側）は、`docs/solutions/workflow-issues/verification-through-the-wrong-resolution-path.md`が指摘する「対比なしの単独passは何も証明しない」を踏まえた対比ペア。`filesystem.allow`に明記されている`$HOME/ghq`を使う。
- ネイティブBashサンドボックスの`excludedCommands`行動検証は、`claude -p`ヘッドレス実行が必要でAPI費用・非決定性の問題があるため今回は対応せず、既知の限界としてissue #210側にコメントで記録する。
- `just test-nono-profile`（既存レシピ、ローカル専用）でそのまま実行される。CI側の変更は不要。

# テスト方針

- ①: 手動確認（statuslineは対話セッションでの視認が前提。自動テストは既存の`StatusLineInput`パース周りのテストが存在しないため追加しない — スコープ外の新規テスト基盤構築は避ける）。
- ③: `just check-templates`を実行し、意図的に`dot_claude/settings.json.tmpl`のJSON構文を壊した一時コピーで検証（FAILすることを確認）、その後正常な状態でPASSすることを確認。
- ④: `just test-nono-profile`で新規テストがpass、かつ意図的に`claude-seal.json`から`$HOME/ghq`の`allow`エントリを一時的に外して同テストがfailに転じることを確認（対比検証）。

# issue #210 側の扱い

- ②は対応不要（PR #241で実質解消）である旨をissueにコメントし、文言更新の上クローズを提案する。
- ④のネイティブサンドボックス行動検証（`excludedCommands`等）は既知の限界としてissueに記録し、将来のクローズ候補から切り離す（本設計では対応しない）。
