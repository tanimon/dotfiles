Review the current session for agent mistakes, bad patterns, or surprising behaviors, then propose harness improvements.

## Analysis Steps

1. **Identify the problem**: What went wrong or was suboptimal in this session? Look at:
   - Incorrect assumptions made
   - Wrong files edited or created
   - Patterns that violated project conventions
   - Commands that failed or produced unexpected results
   - Unnecessary work or wasted effort

2. **Classify the scope**: For each issue, determine:
   - **Project-specific** → Add to this project's CLAUDE.md under "Known Pitfalls"
   - **Global (cross-project)** → Add to `~/.claude/rules/` (propose a specific file and section)
   - **Automatable** → Suggest a hook addition to `~/.claude/settings.json`

3. **Generate proposals**: For each issue, output a structured proposal:

```
### Issue: [Brief description]

**What happened:** [Concrete description of the bad behavior]
**Root cause:** [Why the agent did this]
**Scope:** Project / Global / Hook

**Proposed rule/entry:**
[The exact text to add, ready to copy-paste]

**Where to add it:**
[Exact file path]
```

4. **Prioritize**: Order proposals by impact:
   - Rules that prevent data loss or security issues → CRITICAL
   - Rules that prevent wasted work (wrong approach, unnecessary files) → HIGH
   - Rules that improve code quality or consistency → MEDIUM

5. **Important**:
   - Only propose rules for issues that are likely to recur
   - Do not propose rules for one-off mistakes caused by ambiguous instructions
   - Keep proposed rules concise and actionable
   - Check existing rules first to avoid duplicates
   - If the issue is already covered by an existing rule that was ignored, propose strengthening that rule instead of adding a new one
