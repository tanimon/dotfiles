---
date: 2026-03-06
trigger: "Go files not auto-formatted or statically analyzed after edit"
---

# Go Hooks

> Go specific hooks configuration.

## PostToolUse Hooks

Configure in `~/.claude/settings.json`:

- **gofmt/goimports**: Auto-format `.go` files after edit
- **go vet**: Run static analysis after editing `.go` files
- **staticcheck**: Run extended static checks on modified packages
