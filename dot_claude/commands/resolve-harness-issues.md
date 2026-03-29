Resolve open GitHub issues labeled `harness-analysis`. These issues are created by the weekly CI harness analysis workflow.

## Constraints

- **MUST** work on a feature branch — never commit directly to main
- **MUST** run `make lint` before committing
- **MUST** close each resolved issue with a comment referencing the fix commit

## Workflow

### 1. Check for open issues

```bash
gh issue list --label harness-analysis --state open --json number,title,body
```

If no open issues exist, report "No open harness-analysis issues" and stop.

### 2. Triage issues

For each issue, classify as:
- **Fixable** — concrete action with specific file paths
- **Wontfix** — false positive or not actionable (e.g., plugin skill mistaken for missing local command)

For wontfix issues, close with a comment explaining why:
```bash
gh issue close <number> --comment "Closing as not-a-bug: <reason>"
```

### 3. Create feature branch

```bash
git checkout main && git pull origin main
git checkout -b fix/harness-analysis-<date>
```

### 4. Fix each issue

For each fixable issue:
1. Read the issue body to understand the exact file paths and recommended action
2. Apply the fix (edit files, delete dead code, update docs, etc.)
3. Track which issues are addressed by each change

### 5. Verify

```bash
make lint
chezmoi apply --dry-run
```

Fix any failures before proceeding.

### 6. Commit

Stage and commit with a message referencing the issue numbers:
```
fix: resolve harness engineering CI issues (#N, #M, ...)
```

### 7. Document (optional)

If the fixes revealed non-obvious patterns or pitfalls worth recording:
- Update `docs/solutions/developer-experience/autonomous-harness-engineering-hooks-2026-03-28.md`
- Or run `/ce:compound` to create a new solution doc

### 8. Push and create PR

```bash
git push -u origin HEAD
gh pr create --title "fix: resolve harness-analysis issues" --body "..."
```

Include a summary of what was fixed and which issues are resolved.

### 9. Close issues

For each fixed issue, close with a reference to the PR:
```bash
gh issue close <number> --comment "Fixed in <PR-URL>"
```

## Output

After completion, report:
- Number of issues resolved vs wontfixed vs remaining
- PR URL (if created)
- Any issues that need manual attention
