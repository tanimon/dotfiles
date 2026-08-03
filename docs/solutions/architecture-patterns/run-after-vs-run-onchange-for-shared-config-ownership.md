---
title: chezmoiテンプレート管理ファイルを外部ツールが書き換える場合はrun_after_を使い、run_onchange_は使わない
date: 2026-08-03
category: architecture-patterns
module: chezmoi automation scripts (dot_apm / settings.json.tmpl)
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "2つの独立した仕組みが同じ管理対象ファイルの一部または全体に書き込む場合(例: chezmoiのテンプレートがファイルを完全所有しつつ、外部CLIのインストール処理が同じファイルの一部キーに書き込む場合)"
  - "その外部プロセスの再実行をchezmoiのスクリプトでトリガーしたいが、トリガー条件を『何らかの入力ファイルのハッシュ変化』にしてしまいそうになったとき"
  - "『初回applyでは動いた』という確認だけでスクリプトの正しさを判断しようとしているとき"
tags:
  - chezmoi
  - run-after
  - run-onchange
  - shared-config-ownership
  - apm
  - idempotent-scripts
  - settings-json
  - self-healing-automation
related_components:
  - dot_claude/settings.json.tmpl
  - dot_apm/apm.yml
  - .chezmoiscripts/run_after_apm-install.sh.tmpl
  - chezmoi-script-types
---

# chezmoiテンプレート管理ファイルを外部ツールが書き換える場合はrun_after_を使い、run_onchange_は使わない

## Context

PR #260（ブランチ `apm-skill-mcp-management`）は、Claude CodeのMCPサーバーおよびSkill/プラグイン管理を [microsoft/apm](https://github.com/microsoft/apm)（APM、パッケージマネージャCLI）に一本化する移行だった。この移行の過程で、設定ファイルの所有権が競合する問題が発覚した。

`apm install --global --target claude`（APM CLIのコマンド）は、Skillプラグイン（例: `superpowers`）が持つフックを `~/.claude/settings.json` に直接書き込む。しかし同じファイルは、このリポジトリの `dot_claude/settings.json.tmpl`（chezmoiのGoテンプレート）によって完全に所有されており、`chezmoi apply` のたびに**このテンプレートの内容だけを根拠にゼロから再レンダリング**される（`CLAUDE.md` の「Key Patterns」節、`dot_apm/apm.yml` + APM のパラグラフに経緯が記載されている）。

当初の実装では、apm installを実行する自動化スクリプトを `run_onchange_after_apm-install.sh.tmpl` という、chezmoi組み込みのスクリプト種別の一つとして書いた。`run_onchange_` スクリプトは何らかの追跡対象コンテンツのハッシュを追跡し（ここではAPMのマニフェストファイル `dot_apm/apm.yml` を `# apm.yml hash: {{ include "dot_apm/apm.yml" | sha256sum }}` というコメントで埋め込んで追跡していた）、そのハッシュが前回のapplyから変化した場合にのみ実行される。

この実装は**最初の1回だけ**は正しく動作した。`apm.yml` が新規作成／変更された直後の最初のapplyでスクリプトが実行され、`apm install` が走り、期待通り `settings.json` にフックが現れた。しかし、次の `chezmoi apply`（`apm.yml` に変更がなくても）では、chezmoiのテンプレートエンジンが `settings.json.tmpl` を——通常の `.tmpl` ファイルすべてに対してそうするように——無条件に再レンダリングし、`settings.json` をテンプレート側の内容（APMが追加したフックを知らない版）で上書きしてしまう。`apm.yml` のハッシュは変化していないため `run_onchange_` スクリプトは再実行されず、フックを復元するものが何もない。結果として、フックはエラーも警告も一切出さずに静かに消える。移行直後の目視確認では「うまくいった」ように見え、後になって全く無関係な理由で誰かが実行した次の `chezmoi apply` のタイミングで初めて（しかも無言で）壊れる。

この問題は、実際に不具合が再現するのを観察してではなく、実装中のタスクレベルレビュー（サブエージェントによるコードレビュー）が「2回目以降のapplyでどうなるか」をchezmoiの実行モデルに沿って推論することで、マージ前に発見された。

## Guidance

**Before**（最初の実装）:

```sh
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# apm.yml hash: {{ include "dot_apm/apm.yml" | sha256sum }}

if ! command -v apm &>/dev/null; then
  echo "apm CLI not found, skipping apm install --global"
  exit 0
fi

apm install --global --target claude || echo "WARNING: apm install --global failed; run it manually to sync Skills/MCP servers" >&2
{{ end -}}
```

ファイル名: `.chezmoiscripts/run_onchange_after_apm-install.sh.tmpl`（この名前のファイルは後述のリネームにより現在は存在しない。過去の状態として引用している）

**After**（修正後。現在の `.chezmoiscripts/run_after_apm-install.sh.tmpl` の内容）:

```sh
{{ if eq .chezmoi.os "darwin" -}}
#!/usr/bin/env bash
set -euo pipefail

# 毎回のapplyで実行する(run_onchange_ではない): apmが書き込むSkillのフックは
# ~/.claude/settings.json内にあり、chezmoiがsettings.json.tmplで同ファイルを
# 完全管理しているため、apm.ymlが変化しないapplyでもフックが消えないよう
# 毎回再同期する必要がある。

if ! command -v apm &>/dev/null; then
  echo "apm CLI not found, skipping apm install --global"
  exit 0
fi

apm install --global --target claude || echo "WARNING: apm install --global --target claude failed; run it manually to sync Skills/MCP servers" >&2
{{ end -}}
```

本ドキュメントが教える教訓（run_onchange_からrun_after_への変更）そのものに関わる差分は、次の2点である。

1. ファイル名を `run_onchange_after_apm-install.sh.tmpl` から `run_after_apm-install.sh.tmpl` に変更した。chezmoiの命名規則では、`onchange_` を落として `run_after_`（または `run_before_`）だけにすると、ハッシュ変化などのゲート条件を一切持たず、**すべての `chezmoi apply` で無条件に実行**される。
2. `# apm.yml hash: ...` の追跡コメントを削除し、代わりに毎回無条件実行する理由を説明する日本語コメントに置き換えた。何もそのハッシュに対してゲートしていない以上、ハッシュコメントを残す意味がなくなったため。

上記のAfterコードブロックにはもう1点差分がある——失敗時の警告メッセージに `--target claude` が追記されている点——が、これはこのリネームと同じコミットで入った変更ではない。実際には、リネーム直後の時点では `apm install --global --target claude` というコマンド自体は既に `--target claude` 付きだったが、失敗時のフォールバックメッセージの文言だけが `--target claude` を欠いたまま取り残されており、後日の別の全体レビューで見つかった不整合として個別に修正された。本ドキュメントの教訓（run_onchange_ vs run_after_）とは無関係な、たまたま同じファイル内で起きた別件の修正である点に注意されたい。

一般化した原則:

> chezmoiがテンプレートとして完全所有しているファイルに対し、外部ツール／プロセスが自分自身のタイミングで書き込みを行っている場合、その外部ツールの書き込みを再度呼び戻す（re-assert する）ための同期スクリプトは `run_after_`（無条件実行）でなければならず、`run_onchange_`（何らかの入力のハッシュにゲートされた実行）であってはならない。理由は、共有ファイルを所有する側のテンプレートが、そのハッシュとは無関係に**毎回のapplyで無条件に再レンダリングされる**ため、ゲート条件を「共有ファイルが直前に上書きされたかどうか」に一致させることが原理的にできないからである。

## Why This Matters

このクラスのバグには3つの厄介な性質が重なっている。

- **エラーが一切出ない**: `apm install` は成功し、`chezmoi apply` も正常終了する。異常終了もwarningログも存在しない。
- **1回目のapply（およびそれを対象にした単発のスモークテスト）は必ずパスする**: バグが顕在化するのは「変更を伴わない2回目以降のapply」というシナリオに限られるため、実装直後の動作確認だけでは検出できない。
- **発生タイミングが移行作業から切り離される**: 実際に壊れるのは、後日、全く無関係な目的（例えば別のdotfile変更の適用）で誰かが `chezmoi apply` を実行した瞬間であり、原因究明の際に「最近何を変更したか」という直感的な絞り込みが機能しない。

このクラスの構造は、このリポジトリの `CONCEPTS.md` の「Target」概念がすでに抽象的に言い当てている。`CONCEPTS.md` の該当箇所には次のようにある（引用）:

> A Target's writers are not only the people who open it. The application a Target configures often writes its own settings back into that same file at runtime, and such a write is indistinguishable from a hand edit — it is discarded by the next apply just the same, silently and with no record of what was there. A setting that keeps being lost this way is a setting whose home is the Source.

（`CONCEPTS.md` の「Managed files > Target」節、"A Target's writers are not only the people who open it" から始まる段落）

今回のケースはこの一般原則の具体的なインスタンスである。「アプリケーション」がAPM、「同じファイルに書き込まれる設定」がSkillフック、「次のapplyで静かに破棄される」が `settings.json.tmpl` の毎回の完全再レンダリングにそれぞれ対応する。`CONCEPTS.md` が示す解決の方向性——「消え続ける設定は、その設定の本来の置き場所（Source）を持つべきだ」——は、今回は「フックの内容自体をSourceとしてchezmoiに宣言する」ことはできない（フックの内容はAPM側のプラグイン定義から動的に生成されるため）ため、代わりに「外部ツールの書き込みを、共有ファイルが上書きされた直後に毎回再実行して埋め戻す」という運用的な解決（`run_after_`）を取った、という位置づけになる。

## When to Apply

以下のいずれかに該当する場合、この原則の適用を検討する。

- chezmoiが `.tmpl` として完全所有している設定ファイル（`modify_` による部分所有ではなく、テンプレートからのゼロからの再レンダリングであるもの）に対し、
- chezmoiの外側で動作する別のツール・プロセス（パッケージマネージャ、プラグインシステム、実行時状態を自分の設定ファイルに永続化するアプリケーションなど）が、
- そのファイルに対して独自のタイミングで書き込みを行っており、
- その書き込み内容を維持し続けるために、chezmoi側から何らかの同期・再アサートの自動化スクリプトを書く必要がある場合。

このとき、同期スクリプトのトリガー条件を「共有ファイルが直前に上書きされたかどうか」以外の何か（マニフェストファイルのハッシュなど）にゲートしてはならない。共有ファイルを所有するテンプレート自身が、そのハッシュの変化と無関係に毎回のapplyで再レンダリングされる以上、ゲート条件が実際の破壊タイミングと一致しないからである。実務上は、`run_onchange_` ではなく `run_after_`（または `run_before_`、順序要件次第）を選び、無条件実行にする。

なお、これは「共有ファイルへの書き込みが常に `run_after_` であるべき」という一般則ではない点に注意する。競合する完全所有テンプレートが存在しない場合（例えば後述の `chezmoi-declarative-marketplace-sync-over-bidirectional.md` が扱う `installed_plugins.json` / `known_marketplaces.json` のように、対象ファイルを再レンダリングするchezmoi側テンプレートがそもそも存在しない場合）は、`run_onchange_` のハッシュゲートで十分であり、むしろ不要な毎回実行を避けられる。判断基準は「対象ファイルを、この自動化スクリプトとは無関係に毎回のapplyで再レンダリングする、別の完全所有テンプレートが存在するかどうか」である。

## Examples

Before/Afterの差分は上記Guidance節のコード比較の通り。ファイル名の変更点のみをまとめると:

| | ファイル名 | 実行条件 |
|---|---|---|
| Before | `run_onchange_after_apm-install.sh.tmpl` | `apm.yml` のSHA256ハッシュが前回applyから変化した場合のみ |
| After | `run_after_apm-install.sh.tmpl` | 無条件（毎回のapply） |

このクラスのバグを将来検出するための検証パターンとして、「一時的なdestinationディレクトリに対して2回連続で `chezmoi apply` を行い（1回目と2回目の間でテンプレートやマニフェストに変更を加えない）、外部ツールが書き込んだはずの内容（今回で言えばAPMが追加したフック）が2回目のapply後も生存しているかをアサートする」という二重apply検証が有効である。

ただし正直に書いておくと、この修正自体は前述の通り、実際にこの二重apply検証を最後まで実行して不具合を再現させたことによって見つかったのではない。実装中のタスクレベルレビューが、chezmoiの実行モデル（`run_onchange_` のハッシュゲートと `.tmpl` の毎回無条件再レンダリングという2つの独立した仕組みの組み合わせ）を推論することで、2回目以降のapplyで何が起きるかを予測し、事前に発見したものである。設計ドキュメント（`docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md` の「実装時の訂正」節）にも、この二重apply検証を実機で回した記録はなく、あくまで推論ベースの発見として記録されている。したがって、この二重apply検証パターンは「今後同種のバグを機械的に検出するために推奨される手法」として提示するものであり、「今回の発見に実際に使われた手法」ではない点を区別しておく。

## Related

- `.chezmoiscripts/run_after_apm-install.sh.tmpl` — 現行の修正済みスクリプト
- `dot_claude/settings.json.tmpl` — chezmoiが完全所有するテンプレート
- `dot_apm/apm.yml` — APMのマニフェスト
- `CLAUDE.md`「Key Patterns」節の `dot_apm/apm.yml` + APM のパラグラフ、および「Known Pitfalls」節 — この修正を事後的に説明している既存の記述
- `.claude/rules/chezmoi-patterns.md` の "Declarative Sync Pattern" 節 — 同じ教訓の短い要約
- `CONCEPTS.md`（「Managed files > Target」節） — 「外部ツールがTargetに書き戻す設定は、次のapplyで無記録のまま静かに破棄される」という一般原則
- `docs/superpowers/specs/2026-08-02-apm-skill-mcp-management-design.md`（「実装時の訂正」節） — この方針転換が実装中に承認された経緯
- [`docs/solutions/integration-issues/chezmoi-apply-overwrites-runtime-plugin-changes.md`](../integration-issues/chezmoi-apply-overwrites-runtime-plugin-changes.md) — 関連するが区別すべき問題。こちらは競合する完全所有テンプレートが無いケースで `modify_` スクリプトによる部分所有が解決策だったのに対し、本ドキュメントは2つの完全所有メカニズムが同一ファイルを競合するケースで `run_after_` によるタイミング制御が解決策になっている
- PR #260（ブランチ `apm-skill-mcp-management`）
