---
date: 2026-03-29
trigger: "Agent breaks Renovate adjacency contract in .chezmoiexternal.toml"
---

# Renovate + .chezmoiexternal.toml

Rules for managing external dependencies in `.chezmoiexternal.toml` with Renovate auto-updates.

## Renovate Contract

The regex custom manager in `renovate.json` requires these three lines to be **strictly adjacent in order** — no blank lines, no reordering:

```toml
  url = "https://github.com/owner/repo.git"
  # renovate: branch=main
  ref = "full-sha-here"
```

Breaking this adjacency silently disables Renovate auto-updates for that entry.

## Adding a New External Entry

1. Add the TOML block with `url`, `# renovate: branch=<branch>`, and `ref` in order
2. Pin `ref` to a full commit SHA (not a tag or branch name)
3. Include `refreshPeriod` for chezmoi's own refresh cycle
4. Verify Renovate detects the entry: check the Renovate dashboard or dry-run

## Existing Entries

See `.chezmoiexternal.toml` for current entries (Claudeception skill, cco).

## Related

- `renovate.json` — Renovate configuration with regex custom manager
- `docs/solutions/integration-issues/chezmoi-external-script-repo-with-renovate-sha-pinning.md` — Detailed solution record
