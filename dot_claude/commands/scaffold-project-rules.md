Analyze this project's tech stack and generate appropriate `.claude/rules/` files for it.

## Steps

1. **Detect tech stack**: Read project config files (package.json, go.mod, Gemfile, Cargo.toml, pyproject.toml, Makefile, docker-compose.yml, etc.)

2. **Check existing rules**: Read `.claude/rules/` if it exists. Do not duplicate.

3. **Scan for conventions**: Look at existing code for patterns:
   - File naming conventions
   - Error handling patterns
   - Test file organization
   - Import ordering
   - State management patterns

4. **Generate rules** in `.claude/rules/` based on detected stack:

   **For any project:**
   - `project-conventions.md` — Naming, file organization, patterns specific to this project

   **Stack-specific (only if detected):**
   - Web frontend (React/Next.js/Vue): Component patterns, state management, API calls
   - Backend API (Rails/Express/FastAPI): Endpoint design, auth patterns, error responses
   - CLI tool (Go/Rust/Python): Command structure, flag patterns, output formatting
   - Library/SDK: API surface design, versioning, documentation requirements
   - Infrastructure (Terraform/Docker): Resource naming, module structure

5. **Rule quality checklist** for each generated file:
   - [ ] References actual files in this project as examples
   - [ ] Specific enough to change agent behavior
   - [ ] Does not duplicate global rules from `~/.claude/rules/`
   - [ ] Focuses on project-specific patterns, not general best practices

6. **Important**:
   - Create `.claude/rules/` directory if it doesn't exist
   - Generate focused, concise rules — avoid generic content
   - Include "Patterns to follow" sections pointing to specific files in this project
   - Keep each rule file under 100 lines
   - Do NOT create rules for things the linter already enforces
