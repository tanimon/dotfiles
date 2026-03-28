Analyze this project and generate a CLAUDE.md file for it. Follow these steps:

1. **Detect project type**: Read package.json, go.mod, Gemfile, Cargo.toml, pyproject.toml, or similar to identify the tech stack.

2. **Scan project structure**: Use `ls`, `tree` (depth 3), and read key config files to understand the architecture.

3. **Identify existing patterns**: Look for test files, CI config, linting config, and coding conventions already in use.

4. **Check for existing CLAUDE.md**: If one exists, analyze gaps and suggest additions rather than overwriting.

5. **Generate CLAUDE.md** with these sections:

```markdown
# CLAUDE.md

## What This Is
[One paragraph: what the project does, its primary language/framework]

## Common Commands
[Commands developers actually run: build, test, lint, dev server, deploy]

## Architecture
[Key directories, data flow, important patterns]

## Testing
[How to run tests, coverage requirements, testing conventions]

## Known Pitfalls
[Things that have caused agent mistakes — start empty, add as issues arise]

## Style & Conventions
[Naming, file organization, import ordering — only if not covered by linter config]
```

6. **Important guidelines**:
   - Keep it concise — CLAUDE.md is read every session, brevity matters
   - Focus on what an agent NEEDS to know, not what it can discover by reading code
   - The "Known Pitfalls" section starts sparse — it grows through actual failures
   - Reference deeper docs by path rather than inlining their content
   - Do NOT add generic advice already covered by `~/.claude/rules/`
