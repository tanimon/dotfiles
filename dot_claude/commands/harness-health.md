Diagnose the harness engineering health of this project and suggest improvements.

## Diagnosis Steps

1. **Check CLAUDE.md** (Weight: 30%)
   - Does it exist? → If not, suggest `/scaffold-claude-md`
   - Does it have these key sections?
     - [ ] Project description / "What This Is"
     - [ ] Common commands
     - [ ] Architecture overview
     - [ ] Known pitfalls
     - [ ] Testing instructions
   - Is it concise (<200 lines) or bloated?
   - Does it contain generic advice that belongs in `~/.claude/rules/` instead?

2. **Check project rules** (Weight: 20%)
   - Does `.claude/rules/` exist?
   - Are there project-specific rules (not just copies of global rules)?
   - Do rules reference actual project files as examples?
   - If no rules exist, suggest `/scaffold-project-rules`

3. **Check testing harness** (Weight: 20%)
   - Can tests be run with a single command?
   - Is the test command documented in CLAUDE.md?
   - Is there CI configuration?
   - Are test conventions documented?

4. **Check tooling integration** (Weight: 15%)
   - Is there a linter configured?
   - Are pre-commit hooks set up?
   - Is there a formatter configured?

5. **Check documentation quality** (Weight: 15%)
   - Are there architecture docs or ADRs?
   - Is there a contributing guide?
   - Are there inline comments on complex logic?

## Output Format

```
# Harness Health Report

## Score: [X/100]

### ✅ Strengths
- [What's already well-configured]

### ⚠️ Gaps
- [Missing or weak areas, ordered by impact]

### 🔧 Recommended Actions
1. [Highest-impact action first]
2. [Next action]
...

### Quick Wins (< 5 minutes each)
- [Fast improvements that add immediate value]
```

## Important
- Be specific — name exact files and commands
- Prioritize gaps by impact on agent productivity
- Do not suggest changes to global rules from this command
- Focus on what makes THIS project easier for agents to work with
