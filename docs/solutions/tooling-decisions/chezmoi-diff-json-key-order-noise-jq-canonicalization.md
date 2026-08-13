---
title: "chezmoi diffのJSONキー順序ノイズを diff.command + jq -S で抑制"
date: 2026-08-13
category: tooling-decisions
module: "chezmoi diff.command (~/.claude/settings.json の差分表示)"
problem_type: tooling_decision
component: tooling
severity: medium
applies_when:
  - "chezmoiが全面所有するJSON設定ファイルを、そのファイルを使う側のアプリ自身も実行時に書き戻す構成のとき"
  - "chezmoi diffの出力が、内容の変更ではなくキー順序の入れ替えだけの差分で埋まっているとき"
  - "diffのノイズが多すぎて、本当に見るべき変更(permissions/sandbox設定など)を見落とすリスクがあるとき"
symptoms:
  - "chezmoi diff ~/.claude/settings.json を実行するたびに、enabledPlugins・hooks・sandboxなど複数ブロックの位置が入れ替わっただけの+/-が大量に出る"
  - "同じキーと同じ値なのに、diff上は追加(+)と削除(-)の両方として表示される"
  - "本当の変更(新しいpluginの有効化など)がノイズに埋もれて見落としやすい"
root_cause: missing_tooling
resolution_type: tooling_addition
related_components: [development_workflow, documentation]
tags: [chezmoi, jq, diff, json, claude-code, settings-json, canonicalization]
---

# chezmoi diffのJSONキー順序ノイズを diff.command + jq -S で抑制

## Context

このリポジトリの `dot_claude/settings.json.tmpl` は `~/.claude/settings.json` を全面所有するchezmoiテンプレートである(`.claude/rules/chezmoi-patterns.md` の「File Type Selection」表が定義する`.tmpl`全面所有パターン)。しかし `~/.claude/settings.json` は Claude Code 自身も実行時に書き戻すファイルである — `/plugin` でのプラグイン有効化、`/model`・`/theme`・`/advisor` での設定変更などのたびに、Claude Code はファイル全体を読み込んで書き直す。

このとき Claude Code はオブジェクトのキー順序を安定させない。同じセッション内でも「どの操作でどのキーに触れたか」によって、トップレベルのキー(`enabledPlugins`・`hooks`・`sandbox` など)やネストしたキー(`network.allowUnixSockets`/`allowLocalBinding` など)の並び順がばらばらに変わる。一方 `settings.json.tmpl` は人間が書いた固定順序を持つ。この2つの順序が一致しないため、`chezmoi diff ~/.claude/settings.json` は実行するたびに数十〜100行を超える「キーが入れ替わっただけ」の +/- を表示していた。テンプレート側のキー順を都度その時点のライブファイルに合わせても、Claude Codeが次に書き戻せば再びズレるため、テンプレートの編集では解決しない。

## Guidance

`chezmoi diff` は `diff.command`(と`diff.args`)という設定フックを持ち、個々のファイルの差分表示を外部コマンドに委譲できる(`chezmoi diff --help` に説明あり。デフォルトの `diff.args` は `["{{ .Destination }}", "{{ .Target }}"]` で、コマンドは実際のdestinationパスとレンダリング済みtargetパスの2引数を受け取る)。この仕組みを使い、JSONファイルを比較する前に `jq -S`(オブジェクトキーを再帰的にソート)で正規化してからdiffするラッパースクリプトを `diff.command` に登録した。

- `dot_local/bin/executable_chezmoi-json-diff`(→ `~/.local/bin/chezmoi-json-diff` にデプロイ): 2引数(destination, target)を受け取り、両方とも `jq -S .` でパースできればソート済み一時ファイルに正規化してから `diff -u --label` で比較する。jqでパースできない(非JSON、またはdestinationが未作成)場合は従来通りverbatim diffにフォールバックする。
- `.chezmoi.toml.tmpl` (`[diff] command = ...`, `.chezmoi.toml.tmpl:14-15`): `diff.command` にこのスクリプトの絶対パスを設定。

`jq -S` は配列の要素順序には触れず、オブジェクトのキーだけを再帰的にソートする。そのため `excludedCommands` のようなリスト自体の並び順は変更が起きれば通常通り検出されつつ、`{"a":1,"b":2}` と `{"b":2,"a":1}` のようなオブジェクトキー入れ替えだけは差分から消える。

## Why This Matters

これは「Sourceが全面所有するTargetを、そのTargetを使うアプリ自身も実行時に書き戻す」という一般的な構成([CONCEPTS.md](../../../CONCEPTS.md) の Target の項が説明する構造)の一つの帰結である。Targetの項は主に「書き戻しが特定の設定値を静かに失わせるリスク」を扱っているが、今回の事象はそれとは別の帰結だった: 値は失われていない(内容は正しい)が、書き戻しがバイト列の構造(オブジェクトのキー順)までは保存しないため、バイト単位で比較するツールが本質的でない差分を報告し続ける、というものである。

この区別は重要である。`chezmoi diff` はdiff.command経由の比較なので今回のフックで正規化できるが、`chezmoi status` と `chezmoi apply` はTargetの生バイトを比較するため、このフックの影響を受けない。つまり:

- `chezmoi diff` はキー順序だけの差分を表示しなくなる(このフックで解決した問題)。
- `chezmoi status` は今後もこのファイルを `M`(modified)として表示し続ける。`chezmoi apply` もテンプレートの固定順でファイルを書き戻し続け、Claude Codeが次に書き戻せばまた順序が変わる、というサイクル自体は残る。

後者は実害のあるバグではない(内容は毎回収束する)が、「diffは無音なのにstatusはM」という一見矛盾した状態として残ることは認識しておく必要がある。

検証は [CONCEPTS.md](../../../CONCEPTS.md) の Contrast Pair の手法で行った: 同一ファイル・同一時点に対して `diff.command` ありとなしの2通りで `chezmoi diff --source "$(pwd)" --config <test toml>` を実行し、なし側では元の投稿とほぼ同じ156行のノイズ入り差分が再現され、あり側では0行(実質差分なし)になることを確認した。加えて「キー順序のみ違う→差分なし」「実際に値が変わった→検出」「非JSON→verbatim fallback」「destination未作成→追加として表示」の4パターンを個別に確認済み。

## When to Apply

- chezmoiが全面所有するJSONファイルに対して、そのファイルを使うアプリ自身が実行時に書き戻す構成をこれから作る/レビューするとき。書き戻し側がキー順序を保存しない挙動を持つなら、diff.commandでの正規化を検討する。
- `chezmoi diff` の出力にキー入れ替えだけの差分が増えてきたと感じたとき。まず「本当に内容が変わったのか」を `jq -S` で手動正規化して確認してから対応する(テンプレート側のキー順を都度合わせる対応は次の書き戻しで再発するため根本解決にならない)。
- 同様の書き戻し構成を持つ他のJSON管理ファイル(将来増える場合)にも同じ `chezmoi-json-diff` を使い回せる。ファイル拡張子ではなく実際にjqでパースできるかどうかで判定するため、対象ファイルを限定する追加設定は不要。
- `chezmoi status`/`chezmoi apply` はこのフックの対象外である点を前提にすること。「diffは変更なしなのにstatusはM」という状態を見ても、今回の仕組みが壊れているわけではない。

## Examples

**`diff.command` なし(デフォルト)の `chezmoi diff` — 同一ファイル・同一時点**

```diff
diff --git a/.claude/settings.json b/.claude/settings.json
old mode 100600
new mode 100644
--- a/.claude/settings.json
+++ b/.claude/settings.json
@@ -227,7 +227,56 @@     "additionalDirectories": [
       "~/ghq/github.com/tanomu/**"
     ]
   },
+  "enabledPlugins": {
+    "nono@nolabs-ai": true,
...(156行、ほぼ全てキー順序入れ替えによるノイズ)
```

**`diff.command` あり(`dot_local/bin/executable_chezmoi-json-diff` を設定)— 同じ2ファイル**

```
(差分なし、終了コード0)
```

**スクリプト本体の要点(`dot_local/bin/executable_chezmoi-json-diff`)**

```bash
normalize() {
    local src="$1" dst="$2"
    if [[ ! -e "$src" ]]; then
        : >"$dst"
        return 0
    fi
    jq -S . "$src" >"$dst" 2>/dev/null || cp "$src" "$dst"
}
# ... normalize both sides into a work_dir, then:
diff -u --label "$destination" --label "$target" "$work_dir/destination" "$work_dir/target"
```

**`.chezmoi.toml.tmpl` への追加(`.chezmoi.toml.tmpl:14-15`)**

```toml
[diff]
  command = "~/.local/bin/chezmoi-json-diff"
```

## Related

- [CONCEPTS.md](../../../CONCEPTS.md) — Target(実行時書き戻しの一般的な帰結)と Contrast Pair(今回使った検証手法)の定義
- `.claude/rules/chezmoi-patterns.md` — `.tmpl`全面所有パターンの定義(File Type Selection表)

## 実装状況について

この対応(`dot_local/bin/executable_chezmoi-json-diff` の追加、`.chezmoi.toml.tmpl` への `[diff]` セクション追加)は、このリポジトリの機能ブランチ `fix-claude-settings-json` 上で実施済みだが、本ドキュメント作成時点ではまだコミットされていない作業ツリー上の変更である。またchezmoiの実ソースディレクトリ(`~/.local/share/chezmoi`)は `main` に固定されたワークツリーであるため、実際に有効化するには「このブランチをmainにマージ → `chezmoi init` で設定ファイルを再生成 → `chezmoi apply` でスクリプトを配置」という順序が必要になる。
