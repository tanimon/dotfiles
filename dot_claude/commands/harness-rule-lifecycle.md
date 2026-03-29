Manage the lifecycle of harness rules across all scopes. Inventory rules, detect staleness, and maintain rule health.

## Step 1: Inventory All Rules

Scan these three sources and build a complete rule inventory:

### Global rules (deployed to ~/.claude/rules/)

```bash
find dot_claude/rules/ -name '*.md' -type f | sort
```

### Project-specific rules

```bash
find .claude/rules/ -name '*.md' -type f | sort
```

### CLAUDE.md Known Pitfalls

Extract the "Known Pitfalls" section from `CLAUDE.md` and count the number of subsections (each `###` heading is one pitfall rule).

## Step 2: Analyze Each Rule

For each rule file found in Step 1:

1. **Read the file** to check for YAML frontmatter (delimited by `---`):
   ```yaml
   ---
   date: 2026-01-15
   trigger: "agent used chezmoi add --autotemplate on JSON"
   ---
   ```
2. **Get the file age** from git:
   ```bash
   git log --diff-filter=A --format='%aI' -- <file_path> | tail -1
   ```
3. **Classify status**:
   - **active** — has frontmatter with `date` and `trigger`, and is less than 90 days old (or has related recent git activity)
   - **stale** — older than 90 days with no commits touching the file in that period
   - **untracked** — missing YAML frontmatter (no `date` or `trigger` fields)

## Step 3: Output Summary Table

Display a markdown table:

```
| Status    | Global (dot_claude/rules/) | Project (.claude/rules/) | CLAUDE.md Pitfalls |
|-----------|---------------------------|--------------------------|--------------------|
| Active    | N                         | N                        | N                  |
| Stale     | N                         | N                        | N                  |
| Untracked | N                         | N                        | N/A                |
| **Total** | **N**                     | **N**                    | **N**              |
```

Then list each rule with its path, age, and status.

## Step 4: Offer Actions

Ask which action to perform:

### A) Audit stale rules

For each rule older than 90 days:
1. Read the rule content
2. Search git log for related commits (matching keywords from the rule)
3. Check if the files or patterns referenced in the rule still exist
4. Report whether the rule is still relevant or should be deprecated/removed

### B) Add tracking metadata

For each rule file missing YAML frontmatter:
1. Look up the file's creation date from git
2. Infer a `trigger` from the first paragraph or heading
3. Prepend YAML frontmatter:
   ```yaml
   ---
   date: <creation-date>
   trigger: "<inferred trigger description>"
   ---
   ```
4. Verify the file still renders correctly after adding frontmatter

### C) Deprecate a rule

Ask which rule to deprecate, then:
1. Add `status: deprecated` to the frontmatter
2. Add `deprecated_date` and `reason` fields
3. If there is a replacement rule, add a `replaced_by` field pointing to it
4. Do NOT delete the file — deprecated rules serve as historical reference

### D) Merge rules

Ask which rules to merge, then:
1. Read all candidate rules
2. Identify overlapping content and unique content from each
3. Create a single merged rule file with combined guidance
4. Add frontmatter noting the merge (source files, merge date)
5. Deprecate the original rule files with `replaced_by` pointing to the merged file
6. Run `make lint` to verify nothing broke

## Important

- Never delete rule files — deprecate them instead
- Always run `make lint` after modifying rule files
- CLAUDE.md pitfalls are managed inline — do not add YAML frontmatter to CLAUDE.md itself
- When merging, prefer the location (global vs project) that matches the rule's scope
- Commit changes with type `chore:` (e.g., `chore: deprecate stale harness rules`)
