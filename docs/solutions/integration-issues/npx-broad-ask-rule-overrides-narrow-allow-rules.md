---
title: "広い ask ルールは狭い allow ルールの例外を認めない — npx 個別許可が効かず承認疲れが起きた原因"
date: 2026-08-06
category: docs/solutions/integration-issues
module: dot_claude/settings.json.tmpl
problem_type: integration_issue
component: tooling
symptoms:
  - "permissions.allow に `Bash(npx eslint:*)` `Bash(npx playwright-cli:*)` `Bash(npx vitest:*)` `Bash(npx vue-tsc:*)` の4つの狭いnpxツール別allowルールを追加済みだったにもかかわらず、これらのコマンドを実行するたびに承認プロンプトが出て承認疲れが起きていた"
  - "同じ settings.json.tmpl の permissions.ask 配列に `Bash(npx:*)` という広いルールが同時に存在していた"
  - "diffを見てもallowルール自体は正しく追加されており、`allowが効いていない`という誤った結論に達してデバッグ時間を浪費しやすい"
root_cause: config_error
resolution_type: config_change
severity: medium
tags: [claude-code, permissions, settings-json, npx, ask-vs-allow, permission-prompts, approval-fatigue, chezmoi]
related_components: ["dot_claude/settings.json.tmpl", "PreToolUse hooks", "defaultMode: auto classifier"]
---

# 広い ask ルールは狭い allow ルールの例外を認めない — npx 個別許可が効かず承認疲れが起きた原因

## Problem

`dot_claude/settings.json.tmpl`(Claude Codeの`~/.claude/settings.json`を全面所有するchezmoiテンプレート)の`permissions.allow`には、すでに以下4つの狭いnpxツール別allowエントリが存在していた(PR #252で追加)。

```json
"Bash(npx eslint:*)",
"Bash(npx playwright-cli:*)",
"Bash(npx vitest:*)",
"Bash(npx vue-tsc:*)",
```

にもかかわらず、これらのコマンドを実行するたびにパーミッションプロンプトが出て承認疲れ(approval fatigue)が発生していた。原因は同じ`permissions.ask`配列に`"Bash(npx:*)"`という広いルールが同時に存在していたこと(PR #241でパッケージ/モジュールインストール系コマンドの一括ask化の一部として追加され、後からnpx allowエントリが追加された際にもこの衝突は修正されずに残っていた)。

## Symptoms

- `permissions.allow` に4つの狭いnpxツール別ルールを追加済みなのに、実行するたびに承認プロンプトが出て承認疲れが起きていた
- 同じ設定ファイルの `permissions.ask` に `Bash(npx:*)` という広いルールが同時に存在していた
- diff上ではallowルールが正しく追加されているように見えるため、「allowが効いていない」という誤った結論に達しやすい

## What Didn't Work

この設定ファイルには、npm/pnpmについて既に「狭いaskエントリ(`Bash(npm add:*)`等)が広いallowエントリ(`Bash(npm:*)`)より優先して勝つ」という設計が意図的に使われていた(コメントで明記済み)。

```json
// permissions.allow
"Bash(npm:*)",
"Bash(pnpm:*)",

// permissions.ask
"Bash(npm add:*)",
"Bash(npm ci:*)",
"Bash(npm i:*)",
"Bash(npm install:*)",
"Bash(npm update:*)",
"Bash(pnpm add:*)",
"Bash(pnpm dlx:*)",
"Bash(pnpm install:*)",
"Bash(pnpm update:*)",
```

npxについては、これと**逆方向**の設計(広い`Bash(npx:*)`をaskの既定にして、既知の安全なツールだけをallowの狭いルールで「例外」にする)を試みていたが、この組み合わせはClaude Codeのルール評価モデルの下では機能しない。

```json
// permissions.allow
"Bash(npx eslint:*)",
"Bash(npx playwright-cli:*)",
"Bash(npx vitest:*)",
"Bash(npx vue-tsc:*)",

// permissions.ask
"Bash(npx:*)",   // ← これがある限り上記4エントリは一致すら評価されずaskが勝つ
```

Claude Code公式ドキュメント(https://code.claude.com/docs/en/permissions)で確認したところ、パーミッションルールは以下の順序で評価される:

> Rules are evaluated in order: deny, then ask, then allow. The first match in that order determines the outcome, and rule specificity doesn't change the order.
>
> A broad deny rule like `Bash(aws *)` blocks every matching call, including calls that also match a narrower allow rule like `Bash(aws s3 ls)`, so a deny rule can't carry allowlist exceptions. The same precedence applies between ask and allow: a matching ask rule prompts even when a more specific allow rule also matches the same call.

つまり、allowに書いたルールがどれだけ狭くても、同じコマンドに広くマッチする`ask`ルールが存在すれば必ずaskが勝つ。「allowで例外を作る」というアプローチは、askの中に包含関係にある広いルールが存在する限り機能しない。

PreToolUseフックによる上書きも試みる価値がないことを同ドキュメントで確認済み:

> Hook decisions don't bypass permission rules. Claude Code evaluates deny and ask rules regardless of what a PreToolUse hook returns: a matching deny rule blocks the call, and a matching ask rule still prompts even when the hook returned "allow" or "ask".

## Solution

`permissions.ask`から`"Bash(npx:*)"`の行を削除し、既存の4つのnpx allowエントリをそのまま有効化した。修正後の`dot_claude/settings.json.tmpl`は次の状態になっている。

`permissions.allow`(修正前後で該当4行は変化なし。直前に設計判断を説明するコメントを追加):
```json
"Bash(npm:*)",
{{/* npx はここに列挙した既知の devDependencies 実行に限り allow。permissions.ask に Bash(npx:*) の
ような広いエントリを置くと、ルール評価は deny > ask > allow の配列順で決まり具体性は無視されるため
(公式ドキュメント: "rule specificity doesn't change the order")、ここでどれだけ狭い allow を書いても
ask が先に一致して常にプロンプトが出る — npm/pnpm の「狭い ask が広い allow に勝つ」設計とは逆方向で、
broad ask + narrow allow exception は構造的に成立しない。そのため npx は個別コマンドの allow 列挙のみ
とし、ask には入れていない(未知の npx パッケージ実行は defaultMode: auto のクラシファイア判定に委ねる)。 */ -}}
"Bash(npx eslint:*)",
"Bash(npx playwright-cli:*)",
"Bash(npx vitest:*)",
"Bash(npx vue-tsc:*)",
"Bash(pnpm:*)",
```

`permissions.ask`(`"Bash(npx:*)"`は存在しない。`Bash(npm update:*)`の次は`Bash(pip install:*)`):
```json
"Bash(npm add:*)",
"Bash(npm ci:*)",
"Bash(npm i:*)",
"Bash(npm install:*)",
"Bash(npm update:*)",
"Bash(pip install:*)",
"Bash(pip3 install:*)",
```

副作用として、この4ツール以外の未知のnpxパッケージ実行(`npx create-*`等)は、確定的なaskゲートを外れ、`defaultMode: "auto"`のクラシファイア判定に委ねられることになる。これは無防備というわけではないが、決定的な人間承認ではなくなる、という明示的なトレードオフである(npm/pnpm/yarn/bun等の他のインストール系askルールは変更なし)。ユーザーにはこのトレードオフを含む3つの改善案(①`Bash(npx:*)`をaskから削除/②npx呼び出しを`pnpm exec`に置き換え/③askのnpxパターンを絞り込む)を提示し、①を選択してもらった。

修正後、以下を実行しすべてPASSしたことを確認した:
- `make check-templates`(chezmoiテンプレート妥当性検証)
- `chezmoi execute-template`でレンダリングし、Pythonのjsonモジュールで`permissions.ask`に`Bash(npx:*)`が存在しないこと、`permissions.allow`に4つのnpxエントリが残っていることを確認
- `make lint`(shellcheck, oxfmt, actionlint, zizmor, bats各種テスト, sensitive-info scan, nono profile validation)

## Why This Works

この現象は「allow/ask/denyの優先順位を知らなかった」という単純な話ではない。むしろ**同じ「askが常にallowに勝つ」という一つの評価規則が、ルールの列挙方向次第で意図通りに機能するか、完全に無効化されるかが分かれる**という、直感に反する構造を持っている。

- npmでは: リスクが「サブコマンド」という**列挙可能な有限集合**(add/ci/install/update等)に局在していたため、危険な部分だけをaskの狭いルールとして列挙し、それ以外をallowの広いルールに委ねることができた。狭いaskは広いallowと衝突しないので機能する。
- npxでは: リスクが「未知のパッケージ名を指定して実行する」という**列挙不可能な無限集合**(安全なツールの列挙はできるが、危険なツールの列挙はできない)にあった。この非対称性のため、「広いaskをデフォルトにして安全なものだけを例外にする」という発想そのものがこの評価モデルでは表現できない。broad askが存在する限り、そこに包含されるいかなるnarrow allowも評価されずに終わる。

## Prevention

- Bashパーミッションルールで「一部だけ例外にしたい」という要求が来たら、まず**リスクが列挙可能な安全側(narrow ask化)か、列挙可能な危険側(narrow allow化)か**を見極める。
  - リスクが**サブコマンド/引数という有限集合**に局在している(危険な部分を列挙できる) → 危険な部分をnarrow askとして列挙し、それ以外をbroad allowに委ねる(npmパターン)。
  - リスクが**ツール自体の性質**にあり危険な対象を列挙できない(安全なものだけ列挙可能) → broad askは置かず、安全な既知ツールだけをnarrow allowとして列挙し、それ以外は`defaultMode`のクラシファイア判定(またはbroad ask、慎重さを優先する場合)に委ねる(npxパターン)。
- 新しいBashパーミッションルールを追加した際は、`ask`配列に重なる広いルールが既に存在しないかを確認する。`ask`側に`Bash(<tool>:*)`のような広いプレフィックスルールがあると、以後そのツールに対して追加するどんな狭いallowルールも無効化される。
- PreToolUseフックで許可判定を上書きしようとしない — hookの判定はdeny/askルールを上書きできない。
- 設定ファイルへの変更後は、`chezmoi execute-template`でレンダリングしJSONパースで実際の配列の内容を確認する(コメント追加だけで満足せず、レンダリング結果を機械的に検証する)。

## Related Issues

- [ask から allow への移動は deny のプレフィックスが捕らえる範囲を超えて広がる](./git-push-ask-to-allow-defeats-force-push-deny-prefix.md) — 同じ「deny > ask > allow は具体性を見ない」公式仕様の逆方向の適用(狭いdenyは広いaskの代替にならない、の対)
- [ディレクトリ単位で ask 権限を緩めることはできない](./claude-code-ask-rule-cannot-be-relaxed-per-directory-2026-07-25.md) — askが「床」であり具体性や下位スコープから緩められないという同系の教訓
- [gh の更新系コマンドが defaultMode auto で無条件自動承認される](./claude-code-defaultmode-auto-gh-command-gating.md) — 同じsettings.json.tmplのpermissionsモデルを扱う先行事例(逆方向: 未列挙コマンドの自動承認)
