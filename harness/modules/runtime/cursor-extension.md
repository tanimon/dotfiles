# Cursor 固有のルール(dotfiles リポジトリ)

このリポジトリの**プロジェクト**共通指示は**このファイルには入っていない**。Cursor は project root の `AGENTS.md` をネイティブに読むので、アーキテクチャ・コマンド・Known Pitfalls はすべてそちらにある。**まず `AGENTS.md` を読むこと。**

プロジェクト共通指示をここに複製しないのは意図的で、複製すると Cursor だけが同じ内容を `AGENTS.md` とこのルールの 2 経路からロードすることになるため(`docs/adr/0004-cursor-project-instructions-via-agents-md.md`)。

一方、このファイルの後半にある**グローバル(プロジェクト横断)のポリシー**は意図的にここに置いてある。Claude Code は `~/.claude/CLAUDE.md`、Codex は `~/.codex/AGENTS.md` からそれを受け取るが、Cursor には書いてよいグローバル面が無い(User Rules は非公開ストレージ)。このルールは**他のどの製品も読まない**ので、ここに載せても二重ロードにならない(`docs/adr/0005-global-policy-reaches-cursor-via-project-rules.md`)。

## このファイル自体について

`.cursor/rules/dotfiles.mdc` は**生成物**。Source は `harness/modules/runtime/cursor-extension.md`・`harness/modules/global/` と `harness/project.json` の宣言で、`just harness-sync` で再生成する。直接編集すると `just check-instructions` が drift として落とす。

## Cursor 固有の制約

- MCP サーバはこの rule では設定しない。このリポジトリの MCP 宣言(`dot_apm/apm.yml` の `dependencies.mcp`)はまだ Claude Code 向けにしか配布されておらず、Cursor への配布とスコープの扱いは #312 の担当。
- User Rules(Customize → Rules)はこのリポジトリからは一切触らない。非公開のストレージを書き換える手段しか無いため、意図的に対象外にしている(#308)。
