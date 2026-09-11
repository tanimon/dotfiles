# AGENTS.md

このリポジトリのエージェント向け指示は `CLAUDE.md`（同ディレクトリ）に一元化している。Codex もまず `CLAUDE.md` を全文読むこと。以下は Codex に当てはまらない Claude Code 固有の記述だけを注記する。

- `/harness-reflect` / `/harness-review` などのスラッシュコマンド、`~/.claude/` 配下のパス（settings / rules / skills / scripts / harness 状態）、`dot_claude/` の説明は Claude Code 専用。Codex から同等の操作をする場合は `justfile` のレシピ（`just lint` 等）と `docs/` を直接使う。
- `claude` シェルコマンドの nono ラッパー（`dot_config/nono/`）と Claude Code ネイティブ Bash サンドボックスの記述は Claude Code の起動経路の話。Codex のサンドボックスには適用しない。

それ以外（chezmoi の命名規約・Known Pitfalls・Verification・Identity leak guard）は `CLAUDE.md` の記述がそのまま Codex にも適用される。
