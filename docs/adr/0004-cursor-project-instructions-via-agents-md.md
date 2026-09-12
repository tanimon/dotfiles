---
status: accepted
date: 2026-09-12
---

# Cursor の共有プロジェクト指示は `AGENTS.md` に相乗りさせ、`.cursor/rules/*.mdc` は Cursor 固有の Runtime Extension 専用にする

Cursor は project root の `AGENTS.md` をネイティブに読む(公式ドキュメントが `.cursor/rules` の代替として明記している)。したがって共有の Content Module を `.cursor/rules/*.mdc` にも展開すると、Cursor だけが同じ内容を `AGENTS.md` と `.mdc` の 2 経路からロードすることになる — #308 が Portable Hook について拒否した「1 つのイベントに複数の owner」と同型の重複である。そこで `AGENTS.md` を Codex と Cursor が共有する Target とし(runtime 拡張の文面も両者に当てはまる「Claude 以外のエージェント向け」の内容に限る)、`.cursor/rules/dotfiles.mdc` には Cursor 固有の記述だけを `alwaysApply: true` で置く。

## Considered Options

- **`.mdc` を共有モジュール込みの自己完結ファイルにする** — 却下。製品ごとに完全に独立した Target になる点は素直だが、Cursor での二重ロードを受け入れることになる。Target の独立性より、モデルに渡る内容が正しいことを優先する。
- **`.cursor/rules/` を作らない** — 却下。`AGENTS.md` だけでも Cursor の指示は成立するが、Cursor 固有のポリシー(例: Cursor の MCP はプロジェクトスコープのみ、#312)を将来置く場所が無くなる。薄くてもネイティブな Target を 1 つ持たせる。
- **`AGENTS.md` の runtime 拡張を Codex 専用にする** — 却下。同じファイルを Cursor も読むので、Codex にしか当てはまらない記述を入れると Cursor に誤った指示が渡る。拡張の粒度を「Claude 以外のエージェント共通」に上げる。

## Consequences

- `AGENTS.md` の Target は manifest 上 `runtime: codex` だが、実際には Cursor もこのファイルから共有内容を受け取る。Target Owner(`compose`)は 1 つのままで矛盾しないが、「1 Target = 1 runtime」という manifest の形と実際の読み手が 1 対 1 でない例外として記録しておく。
- Claude Code は `AGENTS.md` を読まないことを実測で確認している(2026-09-12)。将来 Claude Code が `AGENTS.md` を読むようになると Claude 側で二重ロードが発生するので、`CLAUDE.md` と `AGENTS.md` の両方を生成する構成はその時点で再検討が要る。
