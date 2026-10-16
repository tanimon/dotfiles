---
status: accepted
date: 2026-10-16
---

# Key Patterns の「Global agent instructions」節は、harness が生成しない手書きの `paths` 指定 rule に置き、Codex には自動では読み込ませない

グローバル指示(`~/.claude/CLAUDE.md` / `~/.codex/AGENTS.md`)の合成の説明は、グローバル指示のテンプレートとその bats を扱うときにしか要らないのに、共有モジュール Key Patterns の一部として全セッションで常時ロードされていた(#497)。そこで本文を `.claude/rules/global-agent-instructions.md`(frontmatter の `paths` で対象を絞る手書きの rule)に移し、Key Patterns には 1 文の参照だけを残す。正本は rule ファイルの 1 箇所で、`harness/modules/` には写しを置かない。

**Codex には自動では読み込まれないが、参照をたどれば読める。これは移す前と変わらない。** ルートの `AGENTS.md` は Key Patterns を末尾に置き、Codex の `project_doc_max_bytes`(既定 32 KiB。このリポジトリの Codex 設定に上書きは無い)による切り捨てがそのモジュールの内側で起きる並びになっている。移す前の測定では、この節は `AGENTS.md` の先頭から 45,678 バイトの位置で始まっており、自動で読み込まれる範囲の外にあった。その代わり Codex の Runtime Extension(`harness/modules/runtime/codex-extension.md`)が、切り捨てられた後半を `harness/modules/project/35-key-patterns.md` で読むよう案内している。移した後もそのモジュールに残した 1 文が rule のパスを指すので、たどる段が 1 つ増えるだけで経路は残る。

## Considered Options

- **rule を harness の Target として生成し、`harness/modules/` に正本を置く** — 却下。compose adapter の frontmatter は値がスカラーだけで、`paths` の配列を書けない。adapter を配列に対応させる改修とその bats が要り、約 2.1k 文字を常時ロードから外すための作業としては見合わない。手書きの `paths` 指定 rule は `.claude/rules/harness-weekly.md` に前例がある。
- **nested `CLAUDE.md` に置く** — 却下。対象のファイルが `dot_claude/` `dot_codex/` `.chezmoitemplates/` `test/` に分散していて、1 つのディレクトリに収まらない。`dot_claude/CLAUDE.md` は `~/.claude/CLAUDE.md` の Source(`dot_claude/CLAUDE.md.tmpl`)と衝突する。
- **Codex にも届ける(nested `AGENTS.md` など)** — 見送り。Codex が読むのは cwd までの祖先にある `AGENTS.md` だけで、扱うファイルに応じた遅延ロードは無い。移す前も自動では読み込まれておらず、参照をたどる経路は移した後も残るので、新しい仕組みを作る理由は無い。

## Consequences

- `check-instructions` が drift として見るのは生成される Target だけなので、rule ファイルを直接編集してよい。
- rule ファイルは `paths` を持つので起動時には読み込まれないが、`scripts/instruction-size-limits.txt` の既定値(`*` の行)では測られる。
- 対象のファイルを増やしたり改名したりしたら、rule の `paths` も合わせて直す。外れても何も失敗せず、内容が読み込まれなくなるだけ。
