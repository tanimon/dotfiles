---
title: "Self-improvement harness dead for weeks via three silent failures (expired token, green gate skip, plugin rename)"
date: 2026-07-06
category: integration-issues
module: harness-automation
problem_type: integration_issue
component: development_workflow
symptoms:
  - "harness-analysis.yml failed weekly since 2026-06-07 with 401 Invalid authentication credentials (only signal was CI email)"
  - "auto-promote.yml completed green in 8-11s every week — the snapshot health gate failed but exited success by design"
  - "Session-start ECC briefing showed Pipeline BROKEN for months with no diagnosis or fix instruction"
  - "~/.claude/homunculus/ did not exist; observer hooks never fired despite enabledPlugins entry"
root_cause: config_error
resolution_type: workflow_improvement
severity: high
related_components:
  - tooling
  - documentation
tags: [harness-engineering, silent-failure, claude-code-plugins, github-actions, scheduled-workflows, ecc-continuous-learning, oauth-token]
---

# Self-improvement harness dead for weeks via three silent failures

## Problem

The repo's entire self-improvement loop (weekly harness analysis, instinct
auto-promotion, and the local ECC continuous-learning observer) was dead for
weeks to months through three *independent* failures — and no part of the
harness surfaced any of them. The meta-problem: the harness had no mechanism
to detect its own failure.

## Symptoms

- `harness-analysis.yml` failed every scheduled run since 2026-06-07 with
  `401 Invalid authentication credentials` (expired `CLAUDE_CODE_OAUTH_TOKEN`,
  created 2026-03-28). Only signal: CI failure email.
- `auto-promote.yml` "succeeded" in 8–11s every week since mid-May. The
  instinct-snapshot health gate (`scripts/validate-instinct-snapshot.sh`) was
  failing (snapshot stale since 2026-04-30), but gate failure exited green by
  design, so the run list looked healthy.
- The session-start briefing printed `Pipeline: BROKEN` every session for
  months. It named the broken stages but carried no root cause and no fix
  command, so it became permanent noise nobody acted on.
- `~/.claude/homunculus/` did not exist at all: the upstream
  everything-claude-code marketplace renamed its plugin back to `ecc`
  (rename history: PR #154 cleaned up `ecc`→`everything-claude-code`, PR #172
  reverted after upstream renamed again), orphaning the
  `everything-claude-code@everything-claude-code` key in `enabledPlugins`.
  Claude Code silently skips an enabledPlugins key that matches no installed
  plugin — hooks just stop firing.

## What Didn't Work

- **Relying on the session briefing as the alert channel.** A recurring
  banner with no diagnosis trains the reader to ignore it. Alert fatigue set
  in within days; the banner then hid three months of breakage in plain sight.
- **Designing the auto-promote gate to skip green.** The intent (a stale
  snapshot is an "expected" condition, don't spam red runs) was reasonable,
  but success-on-skip made `gh run list` indistinguishable from healthy
  operation.
- **Treating plugin state as stable.** `installed_plugins.json` is runtime
  state outside chezmoi management; the settings key silently diverged from
  it twice due to upstream renames.

## Solution

PR #211 closed the loop at every layer:

1. **Shared alert action** — `.github/actions/harness-issue-alert` creates or
   comments on a `harness-analysis` issue, deduplicated by exact title:

   ```yaml
   - name: Alert on workflow failure
     if: failure()
     uses: ./.github/actions/harness-issue-alert
     with:
       title: "[harness] Scheduled workflow failing: Harness Analysis"
       body: |
         ## Problem ...
       gh-token: ${{ github.token }}
   ```

   Wired into all scheduled workflows (`harness-analysis.yml`,
   `auto-promote.yml`, `security-alerts.yml`) and additionally into
   auto-promote's gate-fail path (`if: steps.health.outputs.gate == 'fail'
   && github.event_name == 'schedule'`), so silent skips also surface.
   Bot-created issues do not retrigger `harness-auto-remediate.yml` (its
   sender guard rejects `github-actions[bot]`), so no alert loop.

2. **Plugin key fix + detection** — `enabledPlugins` updated to `ecc@ecc`,
   plugin reinstalled locally (`claude plugin install ecc@ecc`).
   `pipeline-health.sh` gained a stage-0 check that reads
   `~/.claude/plugins/installed_plugins.json` for an `ecc@`/
   `everything-claude-code@` key and emits `plugin_status` + an actionable
   `hint` in its JSON output.

3. **Actionable briefing** — `learning-briefing.sh` now prints
   `Fix: <hint>` next to `Pipeline: BROKEN`, so the banner tells the reader
   (human or agent) the exact command to run.

Remaining manual step: regenerate the expired token
(`claude setup-token` → `gh secret set CLAUDE_CODE_OAUTH_TOKEN`).

## Why This Works

Each fix converts an invisible failure into an item in the queue the harness
already processes: scheduled-workflow failures and gate skips become
`harness-analysis` issues (the same label `/resolve-harness-issues` and the
auto-remediate workflow consume), and the local briefing carries its own
remediation command. The failure-detection loop is now closed — a broken
harness automation feeds the same improvement pipeline it belongs to,
instead of relying on a human happening to read CI emails or act on a
context-free banner.

## Prevention

- **Every scheduled workflow must end with an `if: failure()` alert step**
  using `.github/actions/harness-issue-alert` (documented in CLAUDE.md).
  The alert steps need `issues: write` permission.
- **Never let a health gate exit green on a scheduled run without an
  escalation path.** Skipping work is fine; skipping silently is not.
- **After plugin marketplace auto-updates, verify `claude plugin list`**
  matches the `enabledPlugins` keys in `settings.json.tmpl`. An orphaned key
  produces no error — the plugin's hooks simply stop firing.
  `pipeline-health.sh` now detects this as "ECC Plugin: NOT INSTALLED".
- **Recurring status banners must include the fix, not just the state.**
  A diagnosis-free "BROKEN" message becomes noise within days.
- `CLAUDE_CODE_OAUTH_TOKEN` expires; when scheduled `claude-code-action`
  workflows start failing fast (~30s) with 401, regenerate it before
  debugging anything else.

## Related Issues

- PR #211 — the fix (also closes #99, #100, #157)
- Issue #128 — verified stale during the same audit (already fixed by #142)
- `docs/solutions/integration-issues/ecc-continuous-learning-harness-integration-2026-04-03.md` — original ECC integration
- `docs/solutions/integration-issues/ecc-plugin-enablement-and-selective-rules-install-2026-04-03.md` — earlier plugin enablement work
- `docs/solutions/integration-issues/github-actions-security-alert-workflow-pitfalls-2026-04-02.md` — related scheduled-workflow pitfalls
