---
date: 2026-10-16
trigger: "常時ロードされるルートの CLAUDE.md に、グローバル指示のテンプレートを触るときにしか要らない節が載っていた"
paths:
  - "dot_claude/CLAUDE.md.tmpl"
  - "dot_codex/AGENTS.md.tmpl"
  - ".chezmoitemplates/agent-instructions-common"
  - "dot_claude/rules/common/**"
  - "test/global-instructions.bats"
  - "test/rendered-instruction-size.bats"
---

# Global agent instructions(`~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`)

リポジトリ内の指示(ルートの `CLAUDE.md` の Key Patterns「Generated agent instructions」)とは合成の機構が違う。**グローバル指示は `harness/` を通らず、chezmoi テンプレートだけで合成する**(ADR 0005。`harness/manifest.json` の `targets` は空のまま)。この内容がルートの `CLAUDE.md` ではなくこの rule にある理由は ADR 0018。

## 合成の構成

共有本文は `.chezmoitemplates/agent-instructions-common` に 1 箇所だけ置き、`dot_claude/CLAUDE.md.tmpl` と `dot_codex/AGENTS.md.tmpl` が `{{ template "agent-instructions-common" }}` で取り込む(`gitignore-common` と同じパターン)。`~/.codex/AGENTS.md` は「Codex 用前置き → 共有本文 → `dot_claude/rules/common/*.md` の連結」で、rules の Source は移動せず Codex 側が `include` で直接読む。

**連結されるのは `dot_claude/rules/common/` に Source として存在するものだけ**で、`~/.claude/rules/{typescript,web}/` は `.chezmoiexternal.toml` が ECC リポジトリから SHA 固定で取り込むものなので Source に無く、Codex には連結されない(Codex 前置きの「ルール構成」はこの事実を明示する)。ECC は plugin として丸ごと有効化せず、使っているファイルだけを external で取り込む(`docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md`)。`~/.claude/rules/` 配下に symlink で差し込まれる仕事用ルールはマシン固有なので含まれない。Cursor はグローバル rules を持たないため対象外(ADR 0004)。

共有本文には製品名も製品固有のツール名も書かない — `AskUserQuestion` は Claude 側の末尾セクションにだけ置き、共有本文は「番号付きの選択肢を提示する」という製品非依存の意図だけを持つ。

## rules の取り込みは `glob` ではなく `include` の明示列挙

第一の理由は連結順序が読めること(その順序が `AGENTS.md` の並びで、Codex の切り捨ては末尾から起きる)。加えて `glob` の**相対**パターンは cwd 相対で評価されるため、`chezmoi apply` の実行位置によっては黙って空リストを返し、ルールが 1 件も入らない `AGENTS.md` を静かに生成する(実測済み。`glob (joinPath .chezmoi.sourceDir "…")` の**絶対**パターンなら cwd に依存しないことも実測済みなので、これは glob を採らない決め手ではなく副次的な理由)。`dot_claude/rules/common/` にファイルを足したら `dot_codex/AGENTS.md.tmpl` にも 1 行足すこと。

## 検査

`just test-global-instructions`(`test/global-instructions.bats`。描画は `test/helpers/render.bash` の `render_template` を通す)で、共有本文が両出力に入ること・rules 全件が `AGENTS.md` に入ること・`AskUserQuestion` が `CLAUDE.md` にしか出ないことを見る。

合成後の出力のサイズ上限(`AGENTS.md` は Codex の `project_doc_max_bytes` の 32 KiB まで)は `scripts/instruction-size-limits.txt` の `render:` の行が正本で、`test/rendered-instruction-size.bats`(`just test-instruction-size`)が全 profile で描画して測る。

どちらの bats も chezmoi が無い環境では skip せず fail する(skip にすると CI で空振りするため、`test/global-instructions.bats` を動かす CI job `global-instructions` と `test/rendered-instruction-size.bats` を動かす CI job `test-instruction-size` がそれぞれ chezmoi を入れている)。
