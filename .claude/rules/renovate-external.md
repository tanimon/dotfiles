---
date: 2026-04-12
trigger: "Agent breaks Renovate adjacency contract in .chezmoiexternal.toml or dot_apm/apm.yml"
paths:
  - ".chezmoiexternal.toml"
  - "dot_apm/apm.yml"
  - "renovate.json"
---

# Renovate + .chezmoiexternal.toml / dot_apm/apm.yml

Rules for managing external dependencies in `.chezmoiexternal.toml` and `dot_apm/apm.yml` with Renovate auto-updates.

## Renovate Contract — .chezmoiexternal.toml

All external entries use `type = "archive"` with SHA-embedded GitHub archive URLs. The regex custom manager in `renovate.json` requires these two lines to appear **in order with no intervening keys or content** — only whitespace between them:

```toml
  url = "https://github.com/owner/repo/archive/full-sha-here.tar.gz"
  # renovate: branch=main
```

Breaking this adjacency silently disables Renovate auto-updates for that entry.

## Renovate Contract — dot_apm/apm.yml (`dependencies.apm`) — 廃止済み（2026-08-10）

> **2026-08-10 update:** Skill/plugin management (`dependencies.apm`)はネイティブClaude Codeマーケットプレイス方式(`dot_claude/settings.json.tmpl`の`enabledPlugins`/`extraKnownMarketplaces`)に巻き戻された。`apm.yml`には`dependencies.mcp`のみが残り、バージョン参照を持つgit shorthandピンが存在しないため、以下の3つのcustom regex manager（および対応する`packageRules`エントリ）は`renovate.json`から削除済み。以下は歴史的記録として残す。

`dependencies.apm` entries used git shorthand: `owner/repo[/subpath]#ref`. Three `renovate.json` custom regex managers covered them, chosen by what `ref` looks like:

| `ref` shape | Example | Manager | Datasource |
|---|---|---|---|
| `vX.Y.Z` | `obra/superpowers#v6.2.0` | generic tag manager | `github-tags` (default semver) |
| `<repo-specific-prefix>-vX.Y.Z` | `EveryInc/compound-engineering-plugin#compound-engineering-v3.21.0` | dedicated prefix manager | `github-tags` with `versioningTemplate: regex:^<prefix>-v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$` |
| 40-char commit SHA + trailing `# renovate: branch=<branch>` comment | `getsentry/plugin-claude#4b61acc2...9e # renovate: branch=main` | digest manager | `git-refs` |

Rules when adding a new `dependencies.apm` entry:

- **Prefer pinning to a real upstream tag** over a bare commit SHA whenever the upstream repo publishes one for the artifact you're pinning (check `gh api repos/<owner>/<repo>/tags`) — tag-based tracking is quieter and gives semver-comparable updates. A bare SHA pin is the fallback only for repos with no tags, or when the currently-desired commit predates the latest tag.
- If the upstream repo mixes tag-naming schemes across sub-packages (e.g. a monorepo tagging each plugin separately), do **not** rely on default `semver` versioning — a competing unrelated tag series (e.g. `v2.42.0` alongside `compound-engineering-v3.21.0`) can be picked as "latest" incorrectly. Use `versioningTemplate: "regex:^<prefix>-v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$"` scoped to the exact prefix instead of `extractVersionTemplate` — `extractVersion` strips the prefix from the value written back to the file, producing a ref that doesn't exist upstream; `versioningTemplate: regex:...` keeps the full raw tag as the round-tripped value while still constraining comparison to matching tags.
- For bare-SHA pins, add ` # renovate: branch=<default-branch>` (space before `#`, so YAML parses it as a real comment, not part of the plain scalar — the scalar's own embedded `#ref` separator has no preceding space, which is what makes both coexist on one line) immediately after the SHA. Verify the actual default branch first (`gh api repos/<owner>/<repo> --jq .default_branch`) — don't assume `main`.
- `depName`/`packageName` extraction strips any subpath after the second `/` (e.g. `anthropics/claude-plugins-official/plugins/foo` → `anthropics/claude-plugins-official`), since the git identity is the repo, not the in-repo path. Multiple subpath entries pinned to the same repo+SHA are extracted as independent dependencies but converge on the same target digest, so they land in the same Renovate branch/PR without needing extra `packageRules` grouping.
- A repo with very high commit frequency and no tags (digest-tracked) can produce a new "latest commit" on almost every Renovate run. `renovate.json`'s `packageRules` throttles all `dot_apm/apm.yml` git-refs updates to a weekly schedule for this reason — don't remove that schedule without confirming the tracked repos' commit cadence has slowed.

**Why archive, not git-repo:** chezmoi's `git-repo` type has no `ref` field — there is no way to pin a `git-repo` entry to a specific commit. `type = "archive"` embeds the SHA in the URL, achieving actual supply-chain pinning. chezmoi v2.70.1+ enforces strict TOML parsing and rejects unknown fields.

## Adding a New External Entry

1. Add the TOML block with `type = "archive"`
2. Use a GitHub archive URL embedding the full commit SHA: `https://github.com/owner/repo/archive/<sha>.tar.gz`
3. Add `# renovate: branch=<branch>` immediately after the `url` line
4. Add `stripComponents = 1` to strip the archive's top-level directory
5. Include `refreshPeriod` for chezmoi's own refresh cycle
6. Verify Renovate detects the entry: check the Renovate dashboard or dry-run

## Existing Entries

See `.chezmoiexternal.toml` for current entries (currently gstack skills only).

## Related

- `renovate.json` — Renovate configuration with regex custom manager
- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — Detailed solution record
