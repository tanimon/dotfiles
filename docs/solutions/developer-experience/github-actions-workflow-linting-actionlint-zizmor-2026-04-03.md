---
title: Adding GitHub Actions workflow linting with actionlint and zizmor
module: ci-cd
date: 2026-04-03
problem_type: developer_experience
component: tooling
severity: medium
root_cause: missing_tooling
resolution_type: tooling_addition
applies_when:
  - Adding static analysis for GitHub Actions workflow files
  - Choosing between actionlint, ghalint, and zizmor
  - Integrating new lint tools into a Makefile + CI + pre-commit pipeline
tags:
  - github-actions
  - actionlint
  - zizmor
  - linting
  - ci-cd
  - security
  - harness-engineering
---

# Adding GitHub Actions workflow linting with actionlint and zizmor

## Context

GitHub Actions workflow files (.github/workflows/*.yml) had no static analysis or security auditing despite being critical CI/CD infrastructure. A prior incident (silent `in` operator failure in GHA expressions) explicitly recommended actionlint but it was never added. Existing security findings included missing `persist-credentials: false`, template injection via `${{ }}` in run blocks, and secrets without dedicated environments.

## Guidance

### Tool Selection: actionlint + zizmor (not ghalint)

| Tool | Focus | Stars | Install |
|------|-------|-------|---------|
| **actionlint** | Syntax, types, expression checking, shellcheck-in-run | 3.7k | `brew install actionlint` |
| **zizmor** | Security (35+ audits) | 4k+ | `brew install zizmor` |
| ~~ghalint~~ | Security policy (excluded) | 222 | No Homebrew |

ghalint was excluded because zizmor covers most of its policies (SHA pinning, permissions, secrets-inherit) with deeper analysis. ghalint lacks Homebrew availability and is migrating to lintnet, adding maintenance risk.

### Integration Pattern (3-layer pipeline)

**Makefile** — Use `command -v` guard pattern (same as shellcheck/shfmt for system binaries):

```makefile
actionlint:
	@if command -v actionlint >/dev/null 2>&1; then \
		echo "Running actionlint..."; \
		actionlint; \
	else \
		echo "WARNING: actionlint not found, skipping"; \
	fi

zizmor:
	@if command -v zizmor >/dev/null 2>&1; then \
		echo "Running zizmor..."; \
		zizmor .github/workflows/; \
	else \
		echo "WARNING: zizmor not found, skipping"; \
	fi
```

Note: actionlint auto-discovers `.github/workflows/*.yml` (no args needed). zizmor requires an explicit directory argument.

**CI** — Pin versions. actionlint uses binary download (like shfmt), zizmor uses pip:

```yaml
actionlint:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@<sha>
      with:
        persist-credentials: false
    - name: Install actionlint
      run: |
        ACTIONLINT_VERSION=1.7.12
        curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
          | tar xz -C /usr/local/bin actionlint
    - run: make actionlint

zizmor:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@<sha>
      with:
        persist-credentials: false
    - name: Install zizmor
      run: pip install zizmor==1.23.1
    - run: make zizmor
```

**Pre-commit** — Scope to workflow files only:

```yaml
- id: actionlint
  entry: bash -c 'if command -v actionlint &>/dev/null; then actionlint "$@"; else echo "actionlint not found, skipping"; fi' --
  files: '\.github/workflows/.*\.yml$'
```

### Suppression Patterns

**actionlint** — Use `.github/actionlint.yaml` for per-file suppression of **verified** false positives only. Do NOT suppress `unknown Webhook event` warnings without confirming the event name is a valid GitHub Actions workflow trigger — GitHub webhook event names and Actions trigger event names are different namespaces. See `docs/solutions/integration-issues/github-actions-invalid-webhook-event-triggers-2026-04-03.md` for a case where suppressions masked real errors.

```yaml
# Example: suppress only when you've verified the event IS a valid Actions trigger
# that actionlint doesn't recognize yet
paths:
  .github/workflows/example.yml:
    ignore:
      - 'verified false positive pattern here'
```

**zizmor** — Use inline comments for accepted patterns:

```yaml
claude_code_oauth_token: ${{ secrets.TOKEN }} # zizmor: ignore[secrets-outside-env]
```

### zizmor Auto-Fix

`zizmor --fix=all` can auto-fix several finding types:
- **artipacked**: Adds `persist-credentials: false` to all `actions/checkout` steps
- **template-injection**: Moves `${{ }}` expressions from `run:` blocks to `env:` variables

Run `--fix=all` first, then handle remaining findings manually.

## Why This Matters

- actionlint catches expression type errors that silently evaluate to false in GHA (a prior incident caused real breakage)
- zizmor detects supply-chain risks (vulnerable actions, impostor commits) that are increasingly exploited
- Together they provide comprehensive coverage: actionlint for correctness, zizmor for security
- Integration into the existing 3-layer pipeline ensures consistent enforcement locally and in CI

## When to Apply

- Adding new lint tools to a Makefile + CI + pre-commit pipeline in this repository
- Choosing between GitHub Actions linting tools
- Fixing zizmor or actionlint findings in workflow files
- Setting up CI jobs for standalone binary tools (not pnpm-managed)

## Examples

**Before:** Workflow with template injection vulnerability:
```yaml
- run: |
    gh issue view "${{ steps.issue.outputs.number }}" ...
```

**After:** Expression moved to env var:
```yaml
- env:
    ISSUE_NUMBER: ${{ steps.issue.outputs.number }}
  run: |
    gh issue view "${ISSUE_NUMBER}" ...
```

## Related

- `docs/solutions/integration-issues/github-actions-expression-in-operator-does-not-exist-2026-03-29.md` — Prior incident that recommended actionlint
- `docs/solutions/developer-experience/chezmoi-oxlint-oxfmt-lint-pipeline-gotchas-2026-03-29.md` — Pattern for adding linters to this pipeline
- `docs/solutions/developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md` — Mirror contract between Makefile and CI
- tanimon/dotfiles#110 — Original issue
- tanimon/dotfiles#112 — Implementation PR
