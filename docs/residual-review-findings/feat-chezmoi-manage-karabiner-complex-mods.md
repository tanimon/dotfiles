# Residual Review Findings

Branch: `feat/chezmoi-manage-karabiner-complex-mods`
Plan: `docs/plans/2026-05-09-001-feat-chezmoi-manage-karabiner-complex-mods-plan.md`
Run artifact: `/tmp/compound-engineering/ce-code-review/20260509-170813-d9d43d58/run-artifact.json`

The autofix pass on `feat: manage Karabiner Elements complex modification rules under chezmoi` (commits `0494606` plan-and-code, `a81c2c6` review autofix) applied 5 `safe_auto` findings. The findings below were not auto-applied and remain as residual work for follow-up.

## Residual Actionable Work

- **[P3][manual -> downstream-resolver]** `docs/plans/2026-05-09-001-feat-chezmoi-manage-karabiner-complex-mods-plan.md` — Plan rationale "Karabiner's default file mode is `0644`" contradicts reality (`0600`) and the deployed-state outcome documented in CLAUDE.md. Reviewer: ce-correctness-reviewer (correctness-001, confidence 75). Reason not auto-applied: `ce-work` guidance explicitly forbids editing the plan body during execution — the plan is a frozen decision artifact, not a living document. The deviation is recorded accurately in CLAUDE.md (which notes "First apply normalizes the file mode from Karabiner's `0600` to `0644`; Karabiner restores `0600` on next save") and in the autofix commit message. Follow-up should reconcile the plan's "No `private_` prefix" rationale paragraph: replace "Karabiner's default file mode is `0644`" with "chezmoi's `modify_` prefix is incompatible with `private_` (cannot preserve `0600` declaratively); Karabiner restores `0600` on next save anyway, so the mode normalization is self-healing".

- **[P3][gated_auto -> downstream-resolver]** `dot_config/karabiner/modify_karabiner.json:13` — Compound failure mode: `jq` missing AND empty stdin (new machine before Karabiner is installed AND launched) emits a bare newline instead of the bootstrap shape. Reviewers: ce-reliability-reviewer (R-003, confidence 75), ce-correctness-reviewer (correctness-004, confidence 50). Reason not auto-applied: edge case requiring two simultaneous failures with very low real-world probability (chezmoi prerequisites typically include `jq`; `automatic_backups/` is a Karabiner-runtime artifact that doesn't exist on a fresh machine until Karabiner is launched). The fix would reorder the bootstrap block above all guards, changing the semantics of all guard paths; safer to defer to a follow-up that also revisits the bootstrap shape and considers backporting to `modify_dot_claude.json`.

## Advisory (in autofix run artifact, not actionable)

The following advisory findings are noted in the run artifact but not promoted to actionable work:

- `printf '%s\n'` vs `printf '%s'` style on the merge-output line (cross-reviewer disagreement; output is byte-identical because jq supplies the trailing newline).
- Missing-source passthrough test using semantic JSON equality vs sibling's byte equality (style preference; alignment decision deferred).
- CLAUDE.md Key Patterns paragraph length (subjective; trim only if section becomes a maintenance burden).
- 4-space vs 2-space indentation in `modify_karabiner.json` vs `modify_dot_claude.json` (project rule explicitly mandates `shfmt -i 4`; the new script complies, the sibling is the pre-existing outlier).

## Run Context

- Mode: `autofix`
- Reviewers dispatched: ce-correctness-reviewer, ce-testing-reviewer, ce-maintainability-reviewer, ce-project-standards-reviewer, ce-reliability-reviewer
- Verdict: `Ready with fixes` (5 `safe_auto` findings applied; 2 residual `downstream-resolver` findings recorded)
- Smoke tests after autofix: 7 of 7 Karabiner scenarios PASS via `make test-modify`
