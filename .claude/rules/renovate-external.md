---
date: 2026-04-12
trigger: "Agent breaks Renovate adjacency contract in .chezmoiexternal.toml"
---

# Renovate + .chezmoiexternal.toml

Rules for managing external dependencies in `.chezmoiexternal.toml` with Renovate auto-updates.

## Renovate Contract

All external entries use `type = "archive"` with SHA-embedded GitHub archive URLs. The regex custom manager in `renovate.json` requires these two lines to be **strictly adjacent in order** — no blank lines, no reordering:

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

See `.chezmoiexternal.toml` for current entries (Claudeception skill, cco).

## Related

- `renovate.json` — Renovate configuration with regex custom manager
- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — Detailed solution record
