## Verification

```sh
just lint                      # Run ALL checks locally (mirrors CI)
chezmoi apply --dry-run        # Preview changes before applying

# Individual recipes (same as CI jobs):
just secretlint                # Scan for leaked secrets
just shellcheck                # Lint non-.tmpl shell scripts
just shfmt                     # Check shell script formatting (indent=4)
just oxlint                    # Lint JS/TS files (.js, .mjs, .mts, .ts)
just oxfmt                     # Check JS/TS and JSON formatting
just actionlint                # Lint GitHub Actions workflows (syntax + types)
just zizmor                    # Security audit GitHub Actions workflows
just test-modify               # Smoke test modify_ scripts
just test-scripts              # Smoke test harness scripts
just test-harness-scripts      # Smoke test harness loop scripts (trigger/briefing/doctor)
just test-harness-sync         # Smoke test the harness sync/check seam (harness/bin/harness.sh)
just check-instructions        # Fail if a generated agent instruction Target was hand-edited
just test-harness-instructions # Smoke test the project instruction sync (compose adapter, --no-probe)
just test-global-instructions  # Smoke test the global instruction composition (~/.claude/CLAUDE.md + ~/.codex/AGENTS.md)
just check-templates           # Validate chezmoi .tmpl files
just scan-sensitive            # Scan every file for PII, credentials, and literal work-org / account names
just test-sensitive            # Smoke test sensitive info scanner
just test-nono-profile         # Validate the nono sandbox profile (skipped if nono absent)
```

Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). CI (`.github/workflows/lint.yml`) and local use the same `just` recipes — if it passes locally, CI will pass too. For similar past issues, search `docs/solutions/`.
