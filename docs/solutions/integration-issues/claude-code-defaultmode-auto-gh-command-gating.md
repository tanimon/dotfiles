---
title: "gh の更新系コマンドが defaultMode auto で無条件自動承認される"
date: 2026-07-18
category: docs/solutions/integration-issues
module: dot_claude/settings.json.tmpl
problem_type: integration_issue
component: tooling
symptoms:
  - "gh pr merge / gh issue create / gh repo delete / gh secret set などの更新系 gh コマンドが承認プロンプトなしで実行される"
  - "allow に列挙されていない gh コマンドがゲートされていない（allow への非掲載 = ゲートではない）"
  - "gh は sandbox.excludedCommands 対象でサンドボックス外実行のため、承認ゲートが唯一の制御になっている"
root_cause: missing_permission
resolution_type: config_change
severity: medium
tags: [claude-code, permissions, defaultmode-auto, gh-cli, sandbox, bypasspermissions, ask, allow, deny]
---

# gh の更新系コマンドが defaultMode auto で無条件自動承認される

## Problem

Claude Code のセッションは `permissions.defaultMode: "auto"` で起動する（#207 で導入）。この
モードは「バックグラウンド安全チェック付きでツール呼び出しを自動承認」するため、`ask`/`deny`
に**明示列挙されていない** Bash コマンドはプロンプトなしで自動実行される。結果として、`allow`
に載っていない `gh` の更新系コマンド（`gh pr merge`、`gh issue create`、`gh repo delete`、
`gh secret set` など）はすべて承認ゲートなしで実 GitHub API に到達していた。

## Symptoms

- `allow` に `gh` は読み取り系 3 つ（`gh pr create`※・`gh pr reviews`・`gh pr view`）しか
  なく、それ以外の更新系 `gh` はすべて自動承認。※`gh pr create` は本来更新系。
- `allow` からの**非掲載はゲートを意味しない** — `defaultMode: auto` 下では未列挙 = 自動承認。
- `gh *` は `sandbox.excludedCommands` に含まれ**サンドボックス外**で実行される。つまり
  `gh` の変更系はサンドボックス境界も承認ゲートも持たない状態だった（権限ゲートが唯一の制御）。

## What Didn't Work

- **noun 単位のワイルドカードでまとめてゲート** (`Bash(gh pr:*)`): `gh` は同一 noun 配下に
  read/write を混在させる（`gh pr view` は read、`gh pr create` は write）。noun 単位で
  ゲートすると読み取り専用コマンドまで過剰にプロンプトが出るため不採用。verb 単位の列挙が必須。
- **`gh api` をプレフィックスでゲート**: `gh api` は read/write の別が固定プレフィックスでは
  なく `--method`/`-X` フラグに現れる（GET は read、POST/PATCH/PUT/DELETE は write）。
  `Bash(gh api:*)` では read/write を分離できず、read まで巻き込むか write を取りこぼす。
  プレフィックスマッチでは正しくゲートできない。
- **`allow` から外すだけで済ませる**: 前述のとおり `defaultMode: auto` では未列挙 = 自動承認
  なので、`allow` から外しても `ask`/`deny` に入れなければゲートされない。

## Solution

`dot_claude/settings.json.tmpl` の `permissions.ask` に更新系 `gh` サブコマンドを **verb 単位**で
明示列挙し、不可逆な操作は `deny` に置いた（PR #224）。

- **precedence**: `deny > ask > allow`。`ask` は `bypassPermissions` 下でも発火するため、
  `ask` への列挙でセッションモードによらずゲートを保証できる（git commit/push と同じ機構）。
- **verb 単位で列挙**: `Bash(gh pr merge:*)` / `Bash(gh issue create:*)` /
  `Bash(gh release create:*)` など更新系 verb を個別列挙（約 41 件）。
- **`gh pr create` を allow → ask へ移動**（リモート状態を変更するため）。読み取り専用の
  `gh pr view` / `gh pr reviews` は `allow` に据え置き。
- **不可逆な操作は deny**: `gh repo delete` / `gh repo archive` は `ask` ではなく `deny`。
  既存の publish/force-push 層と同等の扱いで、`ask` と違い click-through 承認できない
  ハードブロック。可逆な `gh repo` 系（create/edit/fork/rename/sync）は `ask`。
- **`gh api` は未列挙のまま**: 上記の理由でプレフィックスゲート不可。既知・許容の残留リスクと
  してコメントに明記し、arg パターンによる将来ゲートを issue #225 で追跡。
- **シークレット注意の文書化**: PostToolUse の secretlint フックは `Write` の `*.env`/`*secret*`
  ファイルのみ対象で、Bash の `gh` コマンド文字列は走査しない。`gh secret set NAME --body <value>`
  のように値を直書きすると検出されずシェル履歴/トランスクリプトに残る → `--body-file`/stdin 運用と
  プロンプト時レビューに依存。

`CLAUDE.md` の native Bash sandbox セクションに **gh write governance** の記述を追加し、既存の
git write governance の記述に対応させた。

レンダリング検証は `chezmoi execute-template` でレンダリングし、`jq` で `allow`/`ask`/`deny` の
分割（allow に残る gh は読み取り 2 件のみ、ask の gh は 41 件、deny に repo delete/archive、
`gh pr create` は ask のみ）をアサートした。

## Why This Works

`defaultMode: auto` の本質は「未列挙 = 自動承認」。したがってコマンドをゲートする唯一の方法は
`ask`（プロンプト）または `deny`（ハードブロック）に**明示列挙**すること。`allow` はプロンプトを
省くための列挙であり、そこからの除外はゲートにならない。`ask` は `allow` より優先され
`bypassPermissions` 下でも発火するため、`ask` 列挙はセッションモードに依存せずゲートを保証する。

`gh` の CLI 構造（同一 noun 配下に read/write が混在）ゆえ、read/write の分離は verb 単位でしか
できない。`gh api` はサブコマンドではなくフラグ（`--method`）に write 意図が宿るため、プレフィックス
ベースのマッチャでは原理的に分離不可 — だからこそ残留リスクとして明示・追跡する。

**サンドボックス除外 ≠ 権限ゲート**: `gh *` は `sandbox.excludedCommands` にあり Seatbelt の外で
走るが、これは権限承認レイヤーとは直交する。両者は同時に適用され得るが、サンドボックス除外は
承認プロンプトを免除しない。`gh` は「サンドボックス外」かつ「ask ゲート対象」という状態になる。

## Prevention

- **`defaultMode: auto` 下でコマンドをゲートしたいときは `allow` から外すだけでは不十分** —
  必ず `ask`（可逆）または `deny`（不可逆）に明示列挙する。
- **read/write を分離したい CLI は verb 単位で列挙する** — `<tool> <noun>:*` の noun 単位
  ワイルドカードは、noun 配下に read が混在する場合に過剰ゲートになる。
- **フラグに write 意図が宿るコマンド（`gh api --method`、`curl -X` 等）はプレフィックスで
  ゲートできない** — 残留リスクとして明示・追跡する（この件は #225）。
- **secretlint の PostToolUse フックは Write のファイルのみ対象で Bash コマンド文字列は走査しない**
  — シークレットをコマンドライン直書きしない（`--body-file`/stdin を使う）。
- **検証手順**: `make check-templates` でレンダリングを確認し、`chezmoi execute-template |
  jq` で `allow`/`ask`/`deny` の分割をアサートする。

## Related Issues

- `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md` —
  同じ `dot_claude/settings.json.tmpl` の同じ権限モデル（deny > ask > allow、ask は
  bypassPermissions 下でも発火）を **git** の更新系に適用した先行事例。本ドキュメントはその
  **gh 版アナログ**。同ドキュメントは `gh *` を `sandbox.excludedCommands` に置いており、
  サンドボックス除外と権限ゲートが直交して両立する点を本ドキュメントで明確化している。
- `docs/solutions/integration-issues/claude-code-review-workflow-tool-permissions-2026-03-29.md` —
  同じ Claude Code 権限システムだが鏡像のケース。GitHub Actions の `permissionMode: default`
  では逆に過剰**拒否**が問題になり `--allowedTools "Bash(gh *)"` で解消した。`defaultMode: auto`
  の過剰**承認**とは正反対の既定挙動。
- `docs/solutions/integration-issues/claude-code-internal-sandbox-nested-seatbelt-conflict.md` —
  `sandbox.enabled` / ネスト Seatbelt の挙動（settings.json の sandbox ブロックの文脈）。
- PR #224 — 本変更。
- Issue #225 — `gh api` の書き込みメソッド（POST/PATCH/PUT/DELETE）を arg パターンでゲートする
  フォローアップ。
- Issue #210 — ネイティブサンドボックス移行の残リスク・テストギャップ（隣接する追跡課題）。
