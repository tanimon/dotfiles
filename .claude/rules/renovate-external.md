---
date: 2026-04-12
trigger: "Agent breaks Renovate adjacency contract in .chezmoiexternal.toml"
paths:
  - ".chezmoiexternal.toml"
  - "renovate.json"
---

# Renovate + .chezmoiexternal.toml

Rules for managing external dependencies in `.chezmoiexternal.toml` with Renovate auto-updates. `dot_apm/apm.yml` には Renovate 管理対象が無い（`dependencies.mcp` のみ。経緯は `docs/solutions/tooling-decisions/apm-skills-vs-native-claude-code-marketplace.md`）。

## Renovate Contract — .chezmoiexternal.toml

All external entries use `type = "archive"` with SHA-embedded GitHub archive URLs. The regex custom manager in `renovate.json` requires these two lines to appear **in order with no intervening keys or content** — only whitespace between them:

```toml
  url = "https://github.com/owner/repo/archive/full-sha-here.tar.gz"
  # renovate: branch=main
```

Breaking this adjacency silently disables Renovate auto-updates for that entry.

**Why archive, not git-repo:** chezmoi's `git-repo` type has no `ref` field — there is no way to pin a `git-repo` entry to a specific commit. `type = "archive"` embeds the SHA in the URL, achieving actual supply-chain pinning. chezmoi v2.70.1+ enforces strict TOML parsing and rejects unknown fields.

## Adding a New External Entry

1. Add the TOML block with `type = "archive"`
2. Use a GitHub archive URL embedding the full commit SHA: `https://github.com/owner/repo/archive/<sha>.tar.gz`
3. Add `# renovate: branch=<branch>` immediately after the `url` line
4. Add `stripComponents = 1` to strip the archive's top-level directory
5. Include `refreshPeriod` for chezmoi's own refresh cycle
6. Verify Renovate detects the entry: check the Renovate dashboard or dry-run

## Existing Entries

See `.chezmoiexternal.toml` for current entries: ECC(affaan-m/ECC)から選んだファイル(`ecc-code-review` コマンド・agent 4 つ・rules/typescript・rules/web)。ECC の 4 エントリは同じ SHA を指す。ECC を plugin として丸ごと有効化しない理由は `docs/superpowers/specs/2026-09-24-ecc-minimal-install-design.md`。gstack skills は 2026-09-24 に撤去した(利用実態が WebFetch に寄っていたため。残骸は `.chezmoiremove` で消す)。

## ここに入れないもの — 配布元がパスを所有する外部スキル

`.chezmoiexternal.toml` が使えるのは、**展開先を chezmoi が単独で所有する**外部リソースだけ。専用インストーラと更新機構を持つツールのスキルは対象外で、そのツールの方式に従う。

**Orca（`stablyai/orca` の `skills/*`。2026-09-18 に判断）:** `npx skills add https://github.com/stablyai/orca --skill <name> --global`（headless なら `orca skills install --skill <name>`）を使う。理由は 2 つ:

- **バージョン一致が壊れる。** 公開されている `SKILL.md` は 3.5KB の discovery stub で、実体のガイドは `orca skills get <name>` がインストール済み Orca バイナリのバージョンに合わせて返す。stub をバイナリと無関係に Renovate で SHA 更新すると、この設計が意図的に避けているドリフトを自分で作ることになる。
- **所有権が衝突する。** Orca は正本を `~/.agents/skills/<name>/` に置き、`~/.claude/skills/<name>` から相対 symlink を張り、install receipt で更新・削除・ドリフトを追跡する。Orca のドキュメントは "Orca never replaces a path it does not own" と明記しており、chezmoi が置いたファイルはアプリ内アップデータから永久に Skipped / Needs attention 扱いになる（`stablyai/orca` の `docs/reference/agent-skill-provider-paths.md`）。

`~/.agents/` は `.chezmoiignore` 済みなので、この方式で入ったスキルはリポジトリに現れない。新マシンでは `npx skills add` の再実行が必要 — 宣言的な再現性より配布元の所有権を優先した判断。

## Related

- `renovate.json` — Renovate configuration with regex custom manager
- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — Detailed solution record
