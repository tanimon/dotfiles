---
status: accepted
date: 2026-09-14
---

# グローバルポリシーは Managed Project の `.cursor/rules/*.mdc` から Cursor へ配送する

Claude Code と Codex にはそれぞれグローバル指示のネイティブな置き場がある(`~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`)。**Cursor には無い。** Cursor のグローバル面は User Rules だけで、これは非公開ストレージにしか存在せず、#308 が「Undocumented modification of Cursor User Rules storage」を明示的に Out of Scope としている。

そこで、グローバル(プロジェクト横断)の Content Module を Managed Project の `.cursor/rules/dotfiles.mdc` に同梱する。`.mdc` は **Cursor だけが読む Target** なので、ここに載せても他の製品には届かず、Cursor 自身にとっても経路は 1 つのままである(プロジェクトの `AGENTS.md` にはグローバルモジュールを入れない)。

これは ADR 0004(「`.cursor/rules/*.mdc` は Cursor 固有の Runtime Extension 専用にする」)をスコープを限って改めるものである。0004 の**理由**である「Cursor だけが同じ内容を 2 経路でロードするのを避ける」は保たれている — 0004 が禁じたのは *プロジェクト* 共有モジュールの複製であり、それらは引き続き `AGENTS.md` からのみ届く。判定基準は「`.mdc` が薄いこと」ではなく「同じ内容が同じ runtime に 2 経路で届かないこと」である。

## Considered Options

- **Cursor にはグローバルポリシーを配送しない** — 却下。3 製品のうち 1 つだけが「デフォルトで同意しない」「構造化された選択肢で尋ねる」といった横断ポリシーを受け取らない状態になる。#308 が解こうとしている「3 製品が同じ指示に従っているか分からない」状態そのもの。
- **User Rules のストレージを直接書く** — 却下。#308 の Out of Scope。非公開のフォーマットに依存する同期は、Cursor の更新で黙って壊れる。
- **プロジェクトの `AGENTS.md` にグローバルモジュールを入れる** — 却下。Cursor には届くが、同じファイルを読む **Codex がグローバルとプロジェクトの 2 経路で同じ文を受け取る**。ADR 0004 が拒否した重複を、別の製品に移し替えるだけ。
- **Cursor 用にもう 1 つ `.mdc` を作る(例: `global.mdc`)** — 却下。Target が 1 つ増えるだけで、配送経路の数は変わらない。薄いファイルを 2 つ持つより、1 つの `.mdc` の中を「Cursor 固有」「グローバル」の節に分けるほうが読み手にとって追いやすい。

## Consequences

- Cursor のグローバルポリシーは **Managed Project でしか保証されない**。enroll されていないリポジトリで Cursor を開いた場合、Claude Code と Codex はグローバル指示を受け取るが Cursor は受け取らない。これは Cursor 側の機能不足であって同期機構の欠陥ではないが、「3 製品が同じ指示で動いている」と言えるのは Managed Project の中だけ、という制限として記録しておく。
- 他の Managed Project へ展開するとき、`lib/path.bash` が絶対パスと `../` を拒否するため、別リポジトリの `project.json` から dotfiles リポジトリの `harness/modules/global/` は参照できない。第 2 の source root を許すか、モジュールを vendoring するかは #322(enroll)で決める。
- `.cursor/rules/dotfiles.mdc` の内容がプロジェクト固有とグローバルの 2 種類を持つようになるので、drift を直すときに「どちらの Source か」を間違えやすい。banner に両方の Source を書いてある。
- グローバルモジュールを将来プロジェクトの `AGENTS.md` にも入れたくなったら、その時点で Codex の二重ロードが発生する。`test/harness-global-instructions.bats` がその宣言を両方向から拒否する。
