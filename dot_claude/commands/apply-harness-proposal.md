Apply a validated harness improvement proposal to the chezmoi source tree. Proposals come from the `propose-harness-improvement` skill after passing the `validate-harness-proposal` skill.

## Input

A validated proposal in structured format containing:
- **Scope**: Project rule / Global rule / Hook / Skill / Solution doc
- **Risk tier**: Low (auto-apply) / High (review required)
- **Target file**: Exact path in chezmoi source tree
- **Action**: Create / Amend / Replace
- **Content**: The exact text to add or change

If no proposal is provided, ask the user to run `/propose-harness-improvement` first.

## Constraints

- **NEVER** edit deployed targets directly — always edit chezmoi source files
- **MUST** run `make lint` after changes
- **MUST** verify `chezmoi apply --dry-run` succeeds
- **NEVER** modify `.tmpl` files without understanding Go template syntax
- **NEVER** create `modify_` scripts that could produce empty stdout

## Low-Risk Workflow (Auto-Apply)

For proposals classified as low-risk (documentation, formatting rules, solution docs):

### 1. Apply the change

Based on the action type:
- **Create**: Write the new file at the target path
- **Amend**: Edit the existing file to add or modify content
- **Replace**: Replace the specified section in the target file

### 2. Validate

```bash
make lint
chezmoi apply --dry-run
```

Fix any failures. If lint cannot be fixed without changing the proposal content, escalate to high-risk workflow.

### 3. Commit

```bash
git add <changed files>
git commit -m "chore(harness): <brief description of the improvement>"
```

### 4. Report

Output what was applied, which file was changed, and confirm lint passed.

## High-Risk Workflow (Review Required)

For proposals classified as high-risk (behavioral rules, hooks, CI, templates):

### 1. Create feature branch

```bash
git checkout -b fix/harness-<short-description>
```

If already on a feature branch, create a new one from the current branch.

### 2. Apply the change

Same as low-risk step 1.

### 3. Validate

```bash
make lint
chezmoi apply --dry-run
```

### 4. Commit and push

```bash
git add <changed files>
git commit -m "chore(harness): <brief description>"
git push -u origin HEAD
```

### 5. Create PR

```bash
gh pr create --title "chore(harness): <description>" --body "## Harness Improvement

**Issue:** <from proposal>
**Risk tier:** High
**Scope:** <from proposal>

### What changed
<description of the change>

### Rationale
<from proposal rationale>

### Validation
- [x] `make lint` passes
- [x] `chezmoi apply --dry-run` succeeds
"
```

### 6. Report

Output the PR URL and note that human review is required before merge.

## Integration with /resolve-harness-issues

When processing GitHub Issues from `harness-analysis` CI:
1. Read the issue body as the problem description
2. Run `Skill(propose-harness-improvement)` with the issue content
3. Run `Skill(validate-harness-proposal)` on the generated proposal
4. If approved, follow the appropriate workflow above
5. Close the issue with a reference to the commit or PR

## Output

After completion, report:
- What was changed (file path and description)
- Risk tier and workflow used
- Lint/validation result
- Commit hash or PR URL
