---
title: "just の shebang レシピに @ を付けると本文全体がエコーされる(Makeとは逆の挙動)"
date: 2026-08-06
category: integration-issues
module: justfile
problem_type: integration_issue
component: tooling
symptoms:
  - "`just <recipe>` で shebang レシピ(1行目が `#!/usr/bin/env bash`)に `@` を付けて実行すると、実際の出力の前にレシピ本文全体(`#!/usr/bin/env bash` 行を含む)が標準エラーに出力されてから実行される — Make由来の1行レシピにおける `@` の「出力抑制」という直感とは正反対の挙動"
  - "justfile の14レシピ中8つ(shellcheck, shfmt, oxlint, oxfmt, actionlint, zizmor, check-templates, scan-sensitive) — 旧Makefileの `@`-quiet ターゲットから移植したすべての shebang レシピ — が、実行するたびに想定外の冗長なスクリプトダンプ出力を出していた"
  - "同じ shebang レシピから `@` を外すと静かに実行されるようになった — 単に効果が無いのではなく、1行レシピとは正反対の効果になっていることが確認された"
  - "残る6つの1行(非shebang)レシピ(secretlint, test-modify, test-scripts, test-sensitive, test-harness-scripts, test-nono-profile)は期待通りに動作していた — `@` はこれらではMake由来の直感どおりコマンドエコーを正しく抑制していた"
root_cause: wrong_api
resolution_type: code_fix
severity: medium
related_components:
  - development_workflow
tags: [just, justfile, makefile-migration, shebang-recipe, at-prefix, quiet-flag, ci-output, silent-failure]
---

# just の shebang レシピに @ を付けると本文全体がエコーされる(Makeとは逆の挙動)

## Problem

`Makefile` から `justfile` への移行時、複数行ロジックを持つレシピを shebang レシピ(1行目 `#!/usr/bin/env bash`、以降がまるごと1つの bash スクリプト)として書き、Makefile の `@` プレフィックス(コマンドエコー抑制)の習慣をそのまま持ち込んで `@shellcheck:` のように shebang レシピにも `@` を付けたところ、意図と正反対に「レシピ本文をまるごと標準エラーに出力してから実行する」動作になっていた。

## Symptoms

- `just shellcheck` や `just oxlint` など、静かに実行されるはずのレシピを叩くと、実際のコマンド出力の前に `#!/usr/bin/env bash` から始まるスクリプト本文全体が標準エラーに丸ごと出力される。
- `just --list` の出力(レシピ名・コメント)は正常に見えるため、一覧表示だけでは異常に気づけない。実際にレシピを実行して初めて症状が出る。
- CI ログや `just lint` の出力が、Makefile 時代よりもノイズが多く、各チェックの本質的な出力(shellcheck の警告、oxlint の結果など)がスクリプト本文の再掲で埋もれる。

## What Didn't Work

最初の思い込みは「`@` は Make と同じように、レシピの出力を静かにするフラグだから、shebang レシピにも普通のレシピにも同様に効くはず」というものだった。実際には `@` はレシピの種類によって効果が反転する。1行レシピ(`noat_oneliner: echo "hi"` のような形)では `@` は期待通りコマンドエコーを抑制するが、shebang レシピでは逆に本文エコーを引き起こす。この非対称性を知らずに、Makefile の `@`-quiet 規約を機械的に全レシピへ移植したことが根本原因。

さらに輪をかけて悪かったのは検証プロセス側の欠陥で、最初の実装者は「検証済み」と報告していたが、後続のコードレビュー(このセッション内の実装レビュー工程)で調べたところ、実際には移行対象だった15個のレシピのうち2個(`secretlint`, `test-modify`)の出力しか実出力付きで示されていなかったことが判明した。サンプル数が全体の1/7強に過ぎず、たまたま確認した2個が問題を露呈しない組み合わせだったため、このバグは一次実装のセルフチェックをすり抜けた。「検証した」という報告と「全数を検証した」は同義ではない、という点が今回はっきりした。

## Solution

修正は PR #269(tanimon/dotfiles、Issue #232 を close)に含まれる(このリポジトリのローカルチェックアウトでは commit `cbd284c5ec14eb3d015c0ea28f0adfde1d57bf8f` として残っているが、この記録時点で PR は未マージのため、マージ後は squash/rebase でこの SHA 自体が変わりうる — 参照する場合は PR #269 を優先すること)。shebang レシピからは `@` を外し、1行レシピの `@` はそのまま残す。実際の diff(`justfile` より抜粋):

```diff
 # Lint shell scripts
-@shellcheck:
+shellcheck:
     #!/usr/bin/env bash
     if command -v shellcheck >/dev/null 2>&1; then
         if [ -n "{{shell_files}}" ]; then
             echo "Running shellcheck..."
             shellcheck {{shell_files}}
         else
             echo "No shell files found"
         fi
     else
         echo "WARNING: shellcheck not found, skipping"
     fi
```

同じパターンで `shfmt` / `oxlint` / `oxfmt` / `actionlint` / `zizmor` / `check-templates` / `scan-sensitive` の計8つの shebang レシピから `@` を除去した。一方、`secretlint` / `test-modify` / `test-scripts` / `test-sensitive` / `test-harness-scripts` / `test-nono-profile` の6つは1行レシピ(本文がコマンド1行のみ)であり、`@` を付けたままで意図通り動作するため変更していない。現在の `justfile` を見ると、この区別が実際に維持されている — 例えば `@secretlint:` に続く本文は `pnpm exec secretlint '**/*'` の1行のみ、対して修正後の `shellcheck:` は `@` なしで shebang 付き複数行スクリプトを持つ。

## Why This Works

このセッションでの調査(実際に手元の `just 1.58.0` で再現)により、以下が確認できた。最小再現用 justfile:

```
@quiet_shebang:
    #!/usr/bin/env bash
    echo "hello from quiet"

noat_shebang:
    #!/usr/bin/env bash
    echo "hello from noat"

@quiet_oneliner:
    echo "hi"

noat_oneliner:
    echo "hi"
```

これを `just -f repro.just <recipe>` で1つずつ実行した結果:

- `quiet_shebang`(`@` あり): `#!/usr/bin/env bash` と `echo "hello from quiet"` の2行がまず出力され、その後に実行結果 `hello from quiet` が出る — つまり `@` があるのに本文が丸ごとエコーされる。
- `noat_shebang`(`@` なし): `hello from noat` のみ — 静かに実行される。
- `quiet_oneliner`(`@` あり): `hi` のみ — 期待通り静か。
- `noat_oneliner`(`@` なし): `echo "hi"` が先に出力され、その後 `hi` — コマンドがエコーされてから実行される。

つまり `@` の効果は shebang レシピと1行レシピで完全に反転する。この機構の推測(shebang レシピは本文全体を一時スクリプトファイルに書き出して1つのプロセスとして実行するのに対し、1行レシピは各行を設定されたシェルに個別に渡して実行する、という実行経路の違いが `@` の意味を反転させている)は、`just` 自身のソースコードを直接確認できたわけではないため、あくまで今回の再現結果から推測される説明として記す。断定はしないが、独立した2種類の検証(実装レビュー時のコードレビュー subagent による再現、およびこのセッションでの再現)が完全に一致した挙動として観測されている。

## Prevention

- shebang レシピと1行レシピで `@` が対称に振る舞うと決して仮定しない。新しい justfile を書く、または既存の justfile をレビューするときは、上記の最小再現用 justfile(そのまま貼り付けて使える)を使って両方の形式で `@` の有無を実際に試すこと。
- Makefile の `@`-quiet 規約を `just` に移植するときは、移植した各レシピについて「exit code が 0 であること」だけでなく「実際の標準出力・標準エラー出力」を1つずつ目視確認する。今回のバグは、15個中2個だけをサンプル確認して「検証済み」と報告したことで一次実装のセルフチェックを通過してしまった。全数確認するか、少なくとも shebang レシピと1行レシピそれぞれ最低1個以上を確認すること。
- `just --list` の出力(レシピ名・コメントの一覧)が正しく見えることは、実行時の出力挙動を何も保証しない。`just --list` は静的なメタデータ表示に過ぎず、`@` の効果はレシピを実際に実行してみるまで分からない。
- この挙動は `just` 自身の実装に依存し、将来のバージョンで変わる可能性がある。今回の検証は `just 1.58.0`(`.github/workflows/lint.yml` が CI 上で `curl ... install.sh | bash -s -- --tag 1.58.0` によりピン止めしているのと同一バージョン)で行った。別バージョンの `just` を使う場合は、上記の最小再現用 justfile で挙動を再確認することを推奨する。
- 本修正は PR #269(tanimon/dotfiles、Issue #232 を close)に含まれる。この学びを記録した時点で、同PRに対する独立した `/code-review` セッションが `gh pr checks 269` で全チェック(Analyze, CodeQL, Secretlint, ShellCheck, actionlint, chezmoi templates, harness系スモークテスト, oxfmt, oxlint, shfmt, zizmor など)の green を確認している。ただし PR 自体はこの記録時点でまだ `state: OPEN`(未マージ)であり、クリーンな CI runner 上での最終的な green は別途確認が必要。

## Related Issues

- `docs/solutions/integration-issues/makefile-mktemp-silent-pass-and-macos-tmpdir-sandbox.md` — 同じ Makefile→justfile 移行プロジェクト(PR #269 / Issue #232)で見つかった別のバグ(Makefile レシピ内の未ガード `mktemp` が失敗時に静かに PASS してしまう問題)。今回の学びとは症状・根本原因・解決策のいずれも異なる(重複ではない)が、同じ移行作業の副産物として関連する。移行後の `check-templates` レシピは、このドキュメントが記録した `mktemp` ガード(`|| { echo "FAIL: mktemp failed"; exit 1; }`)をそのまま保持している。
- `docs/superpowers/specs/2026-08-06-makefile-to-justfile-migration-design.md` — 今回のバグが生まれた元となる設計ドキュメント。shebang レシピは「Make の `@`-quiet 相当の挙動を追加のマーカーなしで自然に持つ」という(誤った)前提を記述していた箇所がある。この前提は今回の修正コミットによって反証された。設計ドキュメント自体はこのリポジトリの規約により時点記録として扱われるため遡って編集しないが、将来この設計ドキュメントを読む人はこの学びを合わせて参照するとよい。
