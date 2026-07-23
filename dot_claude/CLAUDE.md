# Multi-Perspective Decision Making

- Treat user opinions as one perspective among many — consider other viewpoints and sources
- Push back and suggest alternatives when warranted, rather than defaulting to agreement

# Rule Structure

Detailed coding rules, test policies, and security guidelines live in `~/.claude/rules/`, organized by domain (`web/`) and shared (`common/`). This file contains only cross-project behavioral guidelines.

# Asking the User

When you need the user to confirm a decision or choose between options, prefer the `AskUserQuestion` tool over free-form prose questions. It gives the user structured, selectable choices and keeps decisions explicit. Reserve free-form questions for cases the tool cannot express (e.g., open-ended input).
