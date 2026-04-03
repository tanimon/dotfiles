---
title: "feat: Automate GitHub Security Alert handling via claude-code-action"
type: feat
status: completed
date: 2026-04-02
---

# feat: Automate GitHub Security Alert handling via claude-code-action

## Overview

Add a GitHub Actions workflow that automatically processes GitHub Security Alerts (Dependabot alerts, code scanning alerts, secret scanning alerts) using `claude-code-action`. When a new security alert fires, the workflow triggers Claude to analyze the alert, attempt a fix (for Dependabot and code scanning), or flag it for human review (for secret scanning and high-risk changes).

## Problem Frame

GitHub Security Alerts accumulate silently in the repository's Security tab. Currently there is no automation to triage, fix, or escalate these alerts. The repository already has Renovate for dependency updates, but Renovate does not cover all Dependabot alert scenarios (e.g., transitive dependencies, alerts on packages not in `renovate.json` scope). Code scanning alerts from CodeQL and secret scanning alerts require manual attention. This feature brings security alerts into the same automated remediation pipeline as harness-analysis issues.

## Requirements Trace

- R1. Automatically trigger on new Dependabot alerts and attempt to fix them (dependency update or dismissal with rationale)
- R2. Automatically trigger on new code scanning alerts and attempt to fix or create a trackable issue
- R3. Automatically trigger on new secret scanning alerts and create a high-priority issue for human review
- R4. Follow existing repository patterns (claude-code-action, SHA-pinned actions, security hardening)
- R5. Distinguish low-risk fixes (auto-PR) from high-risk changes (issue comment for human review)
- R6. Support manual dispatch for re-processing existing alerts
- R7. Scheduled sweep to catch alerts that webhook events may have missed

## Scope Boundaries

- **In scope:** Workflow creation, alert triage logic via claude-code-action prompt, PR creation for fixes, issue creation for unfixable alerts
- **Out of scope:** Custom CodeQL query authoring, Dependabot configuration file creation (Renovate handles dependency updates), secret revocation automation (too dangerous to automate), modifying existing Renovate configuration
- **Non-goal:** Replacing Renovate — this complements Renovate by handling alerts Renovate doesn't cover

## Context & Research

### Relevant Code and Patterns

- `.github/workflows/harness-auto-remediate.yml` — Closest existing pattern: label-triggered claude-code-action workflow with low-risk/high-risk bifurcation, PR creation, and issue commenting
- `.github/workflows/claude.yml` — claude-code-action usage with security hardening (SHA pinning, `author_association` guards, fork PR exclusion)
- `.github/workflows/harness-analysis.yml` — Scheduled analysis pattern with issue snapshot diffing
- `renovate.json` — Existing dependency management; extends `config:recommended` and `helpers:pinGitHubActionDigests`
- `package.json` — npm dependencies managed by pnpm (lodash vulnerabilities currently open)

### Institutional Learnings

- GitHub Actions expressions do not support `in` with array literals — use `contains(fromJSON(...), ...)`
- Actions must be pinned to full commit SHAs with `# vN` comment
- Workflows default to read-only permissions — explicitly set `contents: write`, `pull-requests: write`, `issues: write` as needed
- Fork PR exclusion guards are required for public repository security

### External References

- GitHub webhook events: `dependabot_alert`, `code_scanning_alert`, `secret_scanning_alert` are all available as workflow triggers
- GitHub REST API: `GET /repos/{owner}/{repo}/dependabot/alerts`, `PATCH /repos/{owner}/{repo}/dependabot/alerts/{alert_number}` for dismissal
- GitHub REST API: `GET /repos/{owner}/{repo}/code-scanning/alerts`, `GET /repos/{owner}/{repo}/secret-scanning/alerts`
- Required permissions: `security_events: write` for code scanning, `vulnerability-alerts: read` (implicit for Dependabot)

## Key Technical Decisions

- **Single workflow with multiple triggers:** One workflow file handles all three alert types with conditional job logic, rather than three separate workflows. This reduces maintenance overhead and follows the existing pattern of consolidated workflows.
- **claude-code-action for remediation:** Reuse the established claude-code-action pattern (same as harness-auto-remediate) rather than building custom scripts. Claude can analyze the alert context, read the codebase, and propose fixes intelligently.
- **Scheduled sweep as safety net:** A weekly schedule (in addition to webhook triggers) catches any alerts that webhook events missed (e.g., during workflow outages).
- **Risk-tier classification in prompt:** The claude-code-action prompt instructs Claude to classify fixes as low-risk (auto-PR) or high-risk (issue comment), matching the harness-auto-remediate pattern.
- **Secret scanning → issue only:** Secret scanning alerts are always treated as high-risk and create issues for human review. Automated revocation is too dangerous.

## Open Questions

### Resolved During Planning

- **Q: Should we use `dependabot_alert` or `schedule` trigger?** Both — `dependabot_alert` for real-time response, weekly schedule as a sweep for missed alerts.
- **Q: Separate workflows per alert type?** No — one workflow with conditional logic is more maintainable and follows repo conventions.
- **Q: How to handle Renovate overlap?** The workflow should check if Renovate already has an open PR for the same dependency before creating a duplicate. Claude can do this via `gh pr list --search`.

### Deferred to Implementation

- **Exact prompt tuning:** The claude-code-action prompt will need iteration based on real alert handling results.
- **Concurrency limits:** May need `concurrency` groups per alert type if multiple alerts fire simultaneously.

## Implementation Units

- [ ] **Unit 1: Create security alerts workflow**

**Goal:** Add `.github/workflows/security-alerts.yml` that triggers on `dependabot_alert`, `code_scanning_alert`, `secret_scanning_alert` events and a weekly schedule.

**Requirements:** R1, R2, R3, R4, R6, R7

**Dependencies:** None

**Files:**
- Create: `.github/workflows/security-alerts.yml`

**Approach:**
- Use `on: dependabot_alert`, `code_scanning_alert`, `secret_scanning_alert` (types: [created, reopened]) plus `schedule` and `workflow_dispatch`
- Three jobs: `dependabot`, `code-scanning`, `secret-scanning`, each with appropriate `if` conditions
- Each job uses `claude-code-action` with a specialized prompt for that alert type
- Dependabot job: analyze alert, check for existing Renovate PR, attempt fix or dismiss with rationale
- Code scanning job: analyze alert, attempt fix, or create issue
- Secret scanning job: always create high-priority issue for human review
- All actions SHA-pinned with `# vN` comments
- Permissions: `contents: write`, `pull-requests: write`, `issues: write`, `id-token: write`, `security-events: write`
- `author_association` guard not needed (events are system-triggered, not user-triggered)
- `concurrency` groups per alert type to prevent parallel remediation conflicts

**Patterns to follow:**
- `.github/workflows/harness-auto-remediate.yml` — low-risk/high-risk classification, PR creation, issue commenting
- `.github/workflows/claude.yml` — SHA pinning, permission model
- `.github/workflows/harness-analysis.yml` — scheduled sweep with summary output

**Test scenarios:**
- Happy path: Dependabot alert created → workflow triggers → Claude analyzes → creates PR with dependency update
- Happy path: Code scanning alert created → workflow triggers → Claude analyzes → creates fix PR or issue
- Happy path: Secret scanning alert created → workflow triggers → issue created for human review
- Happy path: Manual dispatch → workflow processes specified alert type
- Happy path: Scheduled sweep → processes all open alerts not already handled
- Edge case: Renovate already has open PR for same dependency → Claude skips duplicate PR creation
- Edge case: Alert is for a transitive dependency not directly in package.json → Claude explains in issue comment
- Error path: claude-code-action fails → workflow reports failure in step summary without crashing

**Verification:**
- Workflow YAML is valid (`actionlint` or manual review)
- `make lint` passes (secretlint does not flag the workflow)
- Workflow can be triggered via `workflow_dispatch` for testing
- Step summary output provides clear results for each alert processed

- [ ] **Unit 2: Add scheduled sweep job**

**Goal:** Add a `sweep` job to the workflow that runs on schedule and processes all open, unhandled security alerts.

**Requirements:** R7

**Dependencies:** Unit 1

**Files:**
- Modify: `.github/workflows/security-alerts.yml`

**Approach:**
- Add a `sweep` job that runs only on `schedule` and `workflow_dispatch` events
- Uses `gh api` to list open alerts across all three types
- Passes the alert summary to claude-code-action for batch processing
- Skips alerts that already have associated PRs or issues
- Writes a summary to `$GITHUB_STEP_SUMMARY`

**Patterns to follow:**
- `.github/workflows/harness-analysis.yml` — snapshot-before/after pattern for tracking new issues created

**Test scenarios:**
- Happy path: Scheduled run finds 2 open Dependabot alerts → processes both, creates PRs
- Edge case: No open alerts → summary reports "no alerts to process" and exits cleanly
- Edge case: Alert already has an associated PR → skipped with note in summary

**Verification:**
- Sweep job correctly gates on `schedule` and `workflow_dispatch` events only
- Summary output lists processed and skipped alerts

- [ ] **Unit 3: Add documentation to CLAUDE.md**

**Goal:** Document the new workflow in the Architecture section of CLAUDE.md.

**Requirements:** R4

**Dependencies:** Unit 1, Unit 2

**Files:**
- Modify: `CLAUDE.md`

**Approach:**
- Add a brief entry in the Architecture section describing the security alerts workflow
- Mention the three alert types handled and the low-risk/high-risk classification
- Add the manual trigger command to the Common Commands section

**Test expectation:** none — documentation-only change

**Verification:**
- `make lint` passes
- Documentation accurately reflects the implemented workflow

## System-Wide Impact

- **Interaction graph:** The workflow creates PRs and issues, which may trigger the existing `claude.yml` workflow if someone `@claude`s on them. No circular trigger risk since security alert events are system-generated.
- **Error propagation:** claude-code-action failures are contained within the workflow — they produce a failed step summary but do not affect other workflows.
- **State lifecycle risks:** Concurrent alerts could create overlapping PRs. Mitigated by `concurrency` groups per alert type.
- **API surface parity:** No API changes — this is a new workflow only.
- **Integration coverage:** The workflow's behavior depends entirely on claude-code-action prompt quality, which is best validated through real alert processing.
- **Unchanged invariants:** Existing Renovate configuration and PR flow unchanged. Existing harness workflows unchanged.

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| claude-code-action prompt may not produce good fixes for all alert types | Start with conservative prompt (prefer issue creation over risky auto-fixes); iterate based on results |
| Duplicate PRs if Renovate and this workflow both try to fix the same dependency | Prompt instructs Claude to check for existing Renovate PRs before creating new ones |
| GitHub API rate limits on scheduled sweeps | Sweep runs weekly (low frequency); limit to processing max 10 alerts per run |
| `dependabot_alert` event may not be available for all repository types | Fallback to scheduled sweep ensures coverage regardless of webhook availability |

## Sources & References

- Related issue: #85
- Existing pattern: `.github/workflows/harness-auto-remediate.yml`
- GitHub docs: [Dependabot alerts webhook](https://docs.github.com/en/webhooks/webhook-events-and-payloads#dependabot_alert)
- GitHub docs: [Code scanning alert webhook](https://docs.github.com/en/webhooks/webhook-events-and-payloads#code_scanning_alert)
- GitHub docs: [Secret scanning alert webhook](https://docs.github.com/en/webhooks/webhook-events-and-payloads#secret_scanning_alert)
