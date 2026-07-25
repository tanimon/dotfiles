# Permission Tier Model for git/gh Write Commands — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **2026-07-25 correction — read before re-executing any step.** This plan was written and
> executed for **six** entries, including `"Bash(git push:*)"` as Tier 1. Final review of the
> branch found the Tier 1 justification for `push` false — the force-push `deny` entries are
> *prefix* rules, so trailing-flag force (`git push origin main --force`), `+refspec` force,
> and `--delete` / `:branch` remote-branch deletion all evade them. `git push` was returned to
> `ask`; **five** entries moved. The as-executed end state is `allow` = 63, `ask` = 44
> (`Bash(gh` 39, `Bash(git` 5), `deny` = 46 unchanged. Task 2's verbatim replacement blocks
> below record the text as originally planned; the text actually in `CLAUDE.md` today is the
> corrected version — treat `CLAUDE.md` and
> `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` as authoritative over
> this plan wherever they disagree. (Task 4's closing note already anticipated exactly this
> correction; see the last paragraph of this file.)

**Goal:** Move six append-only / local-only git and gh commands from `permissions.ask` to `permissions.allow` in the global Claude Code settings template, and document the risk-tier model that justifies the split.

**Architecture:** Three independent changes to a chezmoi-managed template and two documentation files. No code, no scripts, no new tooling. Verification is a render-and-assert cycle: `chezmoi execute-template` produces the effective JSON, `jq` asserts the permission arrays. The assertion script is written first and must fail before the edit is made.

**Tech Stack:** chezmoi Go templates, `jq`, `make` targets (`check-templates`, `scan-sensitive`, `lint`).

**Spec:** `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`

## Global Constraints

- Source of truth is `dot_claude/settings.json.tmpl` under `~/.local/share/chezmoi/`. **Never** edit the deployed target `~/.claude/settings.json` — it is overwritten on the next `chezmoi apply`.
- `permissions.deny` must be byte-identical before and after. No entry is added, removed, or reordered.
- `permissions.allow` entries are inserted preserving the list's existing ASCII-alphabetical order.
- Exactly six entries move. Any other change to `permissions.ask` is out of scope.
- Documentation under `docs/` and `CLAUDE.md` is agent-facing and must be written in **English** (`~/.claude/rules/common/documentation-language.md`). Commit messages follow `<type>(<scope>): <description>` in Japanese, matching this repo's history.
- Post-change counts, to be asserted verbatim: `allow` = 64, `ask` = 43, `deny` = 46, `ask` entries starting `Bash(gh` = 39, `ask` entries starting `Bash(git` = 4. **(Superseded — see the correction banner: the shipped counts are `allow` = 63, `ask` = 44, `Bash(git` = 5.)**
- The six moving entries, exact strings:
  `"Bash(git commit:*)"`, `"Bash(git merge:*)"`, `"Bash(git push:*)"`, `"Bash(git revert:*)"`, `"Bash(gh pr comment:*)"`, `"Bash(gh issue comment:*)"`.

---

### Task 1: Move the six entries in `dot_claude/settings.json.tmpl`

**Files:**
- Modify: `dot_claude/settings.json.tmpl:26-40` (the `allow` array — insertions)
- Modify: `dot_claude/settings.json.tmpl:128-178` (the `ask` array — removals)
- Test: no committed test file. An ad-hoc assertion script is written to the scratchpad and run before and after the edit. This matches the verification precedent of PR #224, which asserted the same way without adding a permanent target.

**Interfaces:**
- Consumes: nothing.
- Produces: the rendered `~/.claude/settings.json` permission arrays that Tasks 2 and 3 describe in prose. No symbols.

**Background the implementer needs:**

`dot_claude/settings.json.tmpl` is a Go template, not plain JSON — it contains `{{ .chezmoi.homeDir }}` substitutions and `{{/* ... */}}` comment blocks. It cannot be parsed by `jq` directly. To inspect it you must render it first, which requires both a config file carrying the `[data]` namespace and an explicit `--source`:

```bash
TESTDIR=$(mktemp -d)
printf '[data]\nprofile = "work"\nghOrg = "testorg"\n' > "$TESTDIR/chezmoi.toml"
chezmoi execute-template --config "$TESTDIR/chezmoi.toml" --source "$(pwd)" \
  < dot_claude/settings.json.tmpl > "$TESTDIR/rendered.json"
```

`--init --promptString` does **not** work here: it answers `promptStringOnce` prompts but does not populate `.data`, so `.ghOrg` and `.profile` render empty. This is a documented pitfall in `CLAUDE.md`.

- [ ] **Step 1: Write the failing assertion script**

Create `"$TMPDIR/assert-perms.sh"` (use the session scratchpad, not the repo — this script is not committed):

```bash
#!/usr/bin/env bash
set -euo pipefail

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

printf '[data]\nprofile = "work"\nghOrg = "testorg"\n' > "$TESTDIR/chezmoi.toml"
chezmoi execute-template --config "$TESTDIR/chezmoi.toml" --source "$(pwd)" \
  < dot_claude/settings.json.tmpl > "$TESTDIR/rendered.json"

MOVED='["Bash(git commit:*)","Bash(git merge:*)","Bash(git push:*)","Bash(git revert:*)","Bash(gh pr comment:*)","Bash(gh issue comment:*)"]'
STAY_ASK='["Bash(gh pr create:*)","Bash(gh pr edit:*)","Bash(gh pr close:*)","Bash(gh pr reopen:*)","Bash(gh pr ready:*)","Bash(gh pr review:*)","Bash(gh pr merge:*)","Bash(gh issue create:*)","Bash(gh issue edit:*)","Bash(gh issue close:*)","Bash(gh issue reopen:*)","Bash(gh issue delete:*)","Bash(gh issue transfer:*)","Bash(git reset:*)","Bash(git rebase:*)","Bash(git cherry-pick:*)","Bash(git filter-branch:*)"]'

jq -e --argjson moved "$MOVED" --argjson stay "$STAY_ASK" '
  (.permissions.allow // []) as $allow
  | (.permissions.ask // []) as $ask
  | (.permissions.deny // []) as $deny
  | [
      ($moved - $allow | length == 0),
      ($moved - ($moved - $ask) | length == 0),
      ($stay - $ask | length == 0),
      ($allow | length == 64),
      ($ask | length == 43),
      ($deny | length == 46),
      ([$ask[] | select(startswith("Bash(gh"))] | length == 39),
      ([$ask[] | select(startswith("Bash(git"))] | length == 4),
      ([$allow[] | select(startswith("Bash("))] | . == sort)
    ]
  | all
' "$TESTDIR/rendered.json" > /dev/null

echo "PASS: permission arrays match the tier model"
```

Reading the three set assertions: `$moved - $allow` empty means every moved entry is present in `allow`; `$moved - ($moved - $ask)` empty means no moved entry remains in `ask`; `$stay - $ask` empty means every deliberately-gated entry is still in `ask`.

The final clause enforces the alphabetical-insertion constraint, but only over the `Bash(`-prefixed slice. Do not widen it to the whole `allow` array: `jq`'s `sort` is by codepoint, and the full array is ordered case-insensitively (`"mcp__context7"` sits before `"Read(...)"` and `"WebFetch(...)"`, whereas codepoint order puts every uppercase-initial entry first). Asserting `$allow == ($allow | sort)` would fail on a correct edit. Within the `Bash(` slice everything after the prefix is lowercase, so codepoint order and the list's actual order agree.

- [ ] **Step 2: Run the script to verify it fails**

```bash
bash "$TMPDIR/assert-perms.sh"
```

Expected: exits non-zero with no `PASS` line. `jq -e` returns 1 when the filter produces `false`. Before the edit, `allow` is 58 and `ask` is 49, so at least four clauses are false.

If it fails for any *other* reason — a `jq` parse error, `chezmoi: command not found`, an empty render — stop and fix the harness before continuing. A script that fails for the wrong reason proves nothing.

- [ ] **Step 3: Insert the six entries into the `allow` array**

Four edits in the `allow` array. Each shows the surrounding context so the insertion point is unambiguous.

After `"Bash(fd:*)",` (line 26), insert two lines:

```json
      "Bash(fd:*)",
      "Bash(gh issue comment:*)",
      "Bash(gh pr comment:*)",
      "Bash(gh pr reviews:*)",
```

After `"Bash(git checkout:*)",` (line 30), insert one line:

```json
      "Bash(git checkout:*)",
      "Bash(git commit:*)",
      "Bash(git diff:*)",
```

After `"Bash(git ls-tree:*)",` (line 34), insert one line:

```json
      "Bash(git ls-tree:*)",
      "Bash(git merge:*)",
      "Bash(git pull:*)",
```

After `"Bash(git pull:*)",` (line 35), insert two lines:

```json
      "Bash(git pull:*)",
      "Bash(git push:*)",
      "Bash(git revert:*)",
      "Bash(git show:*)",
```

Indentation is six spaces, matching the surrounding array.

- [ ] **Step 4: Remove the six entries from the `ask` array**

Delete these five lines outright:

```json
      "Bash(gh issue comment:*)",
      "Bash(gh pr comment:*)",
      "Bash(git commit:*)",
      "Bash(git merge:*)",
      "Bash(git push:*)",
```

The sixth, `"Bash(git revert:*)"`, is the **last element of the array and has no trailing comma**. Deleting it leaves `"Bash(git reset:*)",` with a dangling comma, which is invalid JSON. Remove the entry and the preceding comma together, so the array tail reads:

```json
      "Bash(git rebase:*)",
      "Bash(git reset:*)"
    ],
    "defaultMode": "auto",
```

Do not touch `"Bash(git push --force:*)"`, `"Bash(git push --force-with-lease:*)"`, or `"Bash(git push -f:*)"` at lines 97-99 — those are in `deny` and must stay.

- [ ] **Step 5: Run the assertion script to verify it passes**

```bash
bash "$TMPDIR/assert-perms.sh"
```

Expected: prints `PASS: permission arrays match the tier model` and exits 0.

- [ ] **Step 6: Run the repo's own template check**

```bash
make check-templates
```

Expected: passes. This validates that every `.tmpl` in the repo still renders, catching a stray character the `jq` assertion would not see because it only inspects one file.

- [ ] **Step 7: Confirm `deny` is untouched**

```bash
git diff --no-ext-diff -U0 dot_claude/settings.json.tmpl | grep -E '^[+-]' | grep -v '^[+-][+-]'
```

`--no-ext-diff` is **required**: this repo sets `diff.external = difft`, and difftastic's output carries no `+`/`-` line prefixes, so without the flag the `grep` matches nothing and the step silently appears to pass while verifying nothing.

Expected: exactly 14 lines — 7 `+` and 7 `-`. If any line from the `deny` array (roughly lines 84-127) appears, revert and redo.

- [ ] **Step 8: Commit**

```bash
git add dot_claude/settings.json.tmpl
git commit -m "feat(claude): append-only な git/gh コマンド 6 件を ask から allow へ

リスク階層 (Tier 0-3) に基づき、ローカル完結・可逆な git commit/merge/revert
と、既存の入れ物への追記のみで共有状態を変えない git push / gh pr comment /
gh issue comment を allow へ移動。

ライフサイクル遷移 (create/close/reopen/ready/merge)、既存オブジェクトの変更
(edit)、レビュー判断 (review)、破壊的操作 (reset/rebase/cherry-pick/
filter-branch) は ask 維持。deny は無変更。

設計: docs/superpowers/specs/2026-07-25-permission-tier-model-design.md"
```

Note: `git commit` is still `ask`-gated at the time this step runs, because the change has not been applied to `~/.claude/settings.json` yet. Expect an approval prompt. That is correct behavior, not a failure.

---

### Task 2: Update the governance passages in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md:69` (the single long "Native Bash sandbox (migration target)" paragraph — three separate substring replacements within it)

**Interfaces:**
- Consumes: the permission arrays produced by Task 1.
- Produces: nothing consumed by later tasks.

**Background the implementer needs:**

Line 69 is one paragraph of roughly 900 words. Do not rewrite it wholesale — make three targeted substring replacements. Each `old_string` below is unique within the file.

There is a **security-posture change** buried in this paragraph that the spec did not call out, and it must be recorded honestly rather than quietly left stale. The paragraph currently justifies running `git commit`/`git push` outside the sandbox with the words "accepted because git writes are ask-gated (below)". After Task 1 that justification is false: those two commands now run unsandboxed **and** without an approval prompt. Concretely, a repo-controlled pre-commit hook, or a remote reached via `GIT_SSH_COMMAND` or an `ext::` URL, executes outside the Seatbelt boundary with nothing prompting first. Replacement 1 records this.

> **Superseded 2026-07-25 (final review).** The paragraph above, and Replacement 1 below, apply to `git commit` only. `git push` was returned to `ask`, so its unsandboxed SSH transport and `network.allowedDomains` bypass remain prompt-backstopped. `CLAUDE.md` carries the corrected split.

- [ ] **Step 1: Replace the stale sandbox-exclusion justification**

Find this exact substring:

```
— accepted because git writes are ask-gated (below) and this repo's own trusted `prek`/`secretlint` pre-commit hooks must **not** be `--no-verify`/`core.hooksPath`-disabled (that would drop a real secret-detection gate).
```

Replace with:

```
— **no longer backstopped by an approval prompt** as of 2026-07-25: `git commit`/`git push` moved to `allow` under the tier model (below), so a repo-controlled pre-commit hook or a `GIT_SSH_COMMAND`/`ext::` remote now executes unsandboxed with no prompt. Accepted on the basis that work happens in trusted repositories, and because this repo's own trusted `prek`/`secretlint` pre-commit hooks must **not** be `--no-verify`/`core.hooksPath`-disabled (that would drop a real secret-detection gate). Revisit this if untrusted repositories enter the workflow.
```

- [ ] **Step 2: Replace the git write governance passage**

Find this exact substring:

```
**git write governance:** `permissions.ask` gates `commit`, `push`, and history-altering git (`rebase`, `reset`, `revert`, `cherry-pick`, `merge`, `filter-branch`) behind an approval prompt (deny > ask > allow; `ask` fires even under `bypassPermissions`, so unattended runs *block* on these — intended). Routine writes (`add`, `checkout`, `fetch`, `pull`, `submodule`, `worktree`) stay in `allow` so autonomous loops don't deadlock; read-only git is built-in no-prompt. All three force-push forms (`--force`, `--force-with-lease`, `-f`) stay in `deny`.
```

Replace with:

```
**git write governance (tier model):** placement follows a four-tier risk model — Tier 0 local and fully reversible, Tier 1 append-only to an existing container, Tier 2 changes shared object state, Tier 3 destructive or history-rewriting (`docs/superpowers/specs/2026-07-25-permission-tier-model-design.md`). Tier 0 (`commit`, `merge`, `revert`) and Tier 1 (`push`) sit in `allow`; Tier 3 (`reset`, `rebase`, `cherry-pick`, `filter-branch`) stays in `ask` (deny > ask > allow; `ask` fires even under `bypassPermissions`, so unattended runs *block* on these — intended). Routine writes (`add`, `checkout`, `fetch`, `pull`, `submodule`, `worktree`) stay in `allow` so autonomous loops don't deadlock; read-only git is built-in no-prompt. All three force-push forms (`--force`, `--force-with-lease`, `-f`) stay in `deny` — that `deny` is precisely what makes `push` append-only and therefore Tier 1, so weakening it would invalidate `push`'s placement. `reset` is *not* split into `Bash(git reset --hard:*)`-in-`ask` plus `Bash(git reset:*)`-in-`allow`: `git reset HEAD~1 --hard` defeats the prefix match, the same flag-position problem that keeps `gh api` ungateable.
```

> **Retracted 2026-07-25 (final review) — the block immediately above is quoted as planned, not as shipped.** Two of its assertions are **false** and were never allowed to reach the final branch: that `push` is Tier 1 sitting in `allow`, and that the force-push `deny` entries are "precisely what makes `push` append-only". Those `deny` entries are prefix rules; `git push origin main --force`, `git push origin +main`, and `git push --delete origin foo` / `git push origin :foo` all evade them, and `--delete`/`--mirror`/`--prune` are not append-only at all — the very flag-position problem the same sentence names for `git reset` and `gh api`. `git push` stays in `ask`. Read the shipped text in `CLAUDE.md`, not this block.

- [ ] **Step 3: Update the gh governance verb list**

Find this exact substring:

```
verbs like `create`/`edit`/`merge`/`close`/`delete`/`comment`/`run`/`set`), enumerated at the *verb* level
```

Replace with:

```
verbs like `create`/`edit`/`merge`/`close`/`delete`/`run`/`set`), enumerated at the *verb* level
```

Then find this exact substring:

```
read-only `gh` (`gh pr view`/`reviews`, and unlisted read verbs under `defaultMode: auto`) stays frictionless.
```

Replace with:

```
read-only `gh` (`gh pr view`/`reviews`, and unlisted read verbs under `defaultMode: auto`) stays frictionless, and `gh pr comment`/`gh issue comment` sit in `allow` as Tier 1 — append-only to an existing thread, editable and deletable. `gh pr edit`/`gh issue edit` deliberately stay in `ask` despite looking equally minor: `--add-reviewer`/`--add-assignee` push work into someone else's queue and prefix matching cannot separate them from `--title`.
```

- [ ] **Step 4: Verify the replacements landed and nothing else changed**

```bash
grep -c "ask-gated (below)" CLAUDE.md          # expect 0
grep -c "git write governance (tier model)" CLAUDE.md   # expect 1
grep -c "Tier 1 — append-only\|as Tier 1" CLAUDE.md     # expect >= 1
git diff --stat CLAUDE.md                       # expect 1 file, 1 insertion, 1 deletion
```

The paragraph is a single line, so `git diff --stat` reports one changed line regardless of how much text moved. That is expected.

- [ ] **Step 5: Run the sensitive-information scan**

```bash
make scan-sensitive
```

Expected: `No sensitive information found in N file(s)`.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): git/gh write governance を Tier モデルへ書き換え

commit/push が ask から外れたことで、sandbox excludedCommands の
トレードオフ根拠「git writes are ask-gated」が成立しなくなったため、
承認プロンプトによる裏付けが失われた旨を明記。

あわせて gh の verb 列挙から comment を外し、comment が Tier 1 で
allow、edit が Tier 2 で ask に残る理由を追記。"
```

---

### Task 3: Record the scoping constraints in `docs/solutions/`

**Files:**
- Create: `docs/solutions/integration-issues/claude-code-ask-rule-cannot-be-relaxed-per-directory-2026-07-25.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

**Background the implementer needs:**

This is the highest-value artifact of the whole change. The six-entry diff is disposable; the constraint is not. Without this document the next attempt to scope permissions by directory will walk the same dead end in the same order — project-scope `allow`, then a PreToolUse hook returning `"allow"`, then `bypassPermissions` — and burn the same investigation time.

Solution documents in this repo carry YAML front-matter and follow a fixed section order. Read `docs/solutions/integration-issues/claude-code-defaultmode-auto-gh-command-gating.md` first for the house format. Note that existing solution documents in this directory are written in **Japanese** despite the global English rule for agent-facing docs; follow the directory's actual convention, not the global rule, so the corpus stays internally consistent.

- [ ] **Step 1: Write the document**

Create the file with this front-matter and these sections. The `problem_type`, `root_cause`, `resolution_type`, and `severity` values must be drawn from the vocabulary already used in the directory.

```yaml
---
title: "ディレクトリ単位で ask 権限を緩めることはできない"
date: 2026-07-25
category: docs/solutions/integration-issues
module: dot_claude/settings.json.tmpl
problem_type: integration_issue
component: tooling
symptoms:
  - "特定リポジトリだけ git/gh の更新系コマンドを allow にしたいが、project の .claude/settings.json に allow を書いても承認プロンプトが出続ける"
  - "リポジトリ群の親ディレクトリに .claude/settings.json を置いても配下に適用されない"
  - "PreToolUse フックで permissionDecision: allow を返してもプロンプトが消えない"
root_cause: config_precedence
resolution_type: config_change
severity: medium
tags: [claude-code, permissions, ask, allow, precedence, settings-scope, hooks, per-directory]
---
```

Required sections, in this order:

1. **`# ディレクトリ単位で ask 権限を緩めることはできない`**
2. **`## Problem`** — the original goal: user-scope settings gate git/gh writes with `ask`; the wish was to relax that in one repository only.
3. **`## Symptoms`** — the three failure modes from the front-matter, expanded to a sentence each.
4. **`## What Didn't Work`** — four subsections, each stating the attempt, why it seemed plausible, and the documentation sentence that rules it out:
   - **project scope の `allow`** — quote: "The same precedence applies between ask and allow: a matching ask rule prompts even when a more specific allow rule also matches the same call." and "The same holds across settings scopes."
   - **親ディレクトリへの settings 配置** — quote: "Hooks and other `.claude/settings.json` keys load from the current working directory's `.claude/` folder with no parent-directory fallback." Contrast explicitly with skills / subagents / slash commands, which *are* discovered from parent directories — that asymmetry is what makes the wrong assumption feel reasonable. Note `.claude/settings.local.json` loads from the git repository root on v2.1.211+, which is still repo-scoped, not tree-scoped.
   - **PreToolUse フックで `"allow"` を返す** — quote: "Claude Code evaluates deny and ask rules regardless of what a PreToolUse hook returns: a matching deny rule blocks the call, and a matching ask rule still prompts even when the hook returned `\"allow\"` or `\"ask\"`."
   - **`bypassPermissions` モード** — quote: "Skips permission prompts, except those forced by explicit `ask` rules". Add that this is by design: `ask` is what makes a gate survive unattended runs.
5. **`## Solution`** — state the two shapes that *can* express location-dependent gating: (A) permissive declarative baseline plus a user-level PreToolUse hook branching on the `cwd` field of the hook's stdin JSON, returning `permissionDecision: "ask"` outside the relaxed directories; (B) a single global declarative policy tuned by risk. Record that (B) was chosen, and why (A) was rejected: it relocates the gate into a shell script whose correctness becomes security-critical, must re-implement compound-command parsing (`env FOO=1 git push`, `foo && git push`) to avoid failing open, and must exit **2** — not 1 — to block, which conflicts with the exit-code contract in `.claude/rules/shell-scripts.md`. Then summarize the tier model and the six entries that moved.
6. **`## Why This Works`** — the general rule: **`ask` is a floor, not a default.** Any scope can raise the floor; no scope can lower it. Allow rules and hook `"allow"` decisions are both *below* that floor. Therefore location-dependent permissioning must be expressed by choosing a permissive floor and adding restriction on top — never by choosing a restrictive floor and carving exceptions.
7. **`## Prevention`** — four bullets:
   - Before designing per-directory permissions, check whether the rule lives in `ask`/`deny`. If it does, project scope cannot help.
   - Do not assume `settings.json` resolution mirrors skill/agent/command resolution. Only the latter walks parent directories.
   - Hooks can only tighten permissions, never loosen them. Design accordingly.
   - When a declarative gate is replaced by a scripted one, the script must fail closed (`exit 2`) and must be smoke-tested.
8. **`## Related Issues`** — cross-reference:
   - `claude-code-defaultmode-auto-gh-command-gating.md` — same permission model; establishes "未列挙 = 自動承認" under `defaultMode: auto`, which is why `allow` enumeration is documentation rather than mechanism.
   - `native-sandbox-1password-socket-signing-2026-07-09.md` — introduced the git `ask` gate this change relaxes, and holds the `excludedCommands` trade-off whose justification Task 2 had to rewrite.
   - `docs/superpowers/specs/2026-07-25-permission-tier-model-design.md` — the design.
   - Issue #225 — `gh api` prefix-gating residual, unaffected.

- [ ] **Step 2: Run the sensitive-information scan**

```bash
make scan-sensitive
```

Expected: `No sensitive information found in N file(s)`, with N one higher than in Task 2.

- [ ] **Step 3: Commit**

```bash
git add docs/solutions/integration-issues/claude-code-ask-rule-cannot-be-relaxed-per-directory-2026-07-25.md
git commit -m "docs(solutions): ディレクトリ単位で ask 権限を緩められない制約を記録

project scope の allow、親ディレクトリへの settings 配置、PreToolUse
フックの allow、bypassPermissions のいずれでも user scope の ask は
緩められないことを、公式ドキュメントの引用付きで記録。

ask は床であって既定値ではない — どのスコープからも床は上げられるが
下げられない、という一般則を Why This Works に置いた。"
```

---

### Task 4: Full verification and apply

**Files:** none modified.

**Interfaces:**
- Consumes: all three preceding tasks.
- Produces: a deployed `~/.claude/settings.json`.

**Deployment is blocked until merge.** This task originally assumed `chezmoi apply` deploys from this working tree. It does not: chezmoi's source directory `~/.local/share/chezmoi` is a **separate git worktree pinned to `main`**, so `chezmoi diff` / `chezmoi apply` read `main`, not this branch. Steps 3-5 are therefore only performable after this branch merges. Steps 1-2 run against the working tree and are performable now.

- [ ] **Step 1: Run the full lint suite**

```bash
make lint
```

Expected: every target passes. This is the same set CI runs, so a pass here means CI passes.

- [ ] **Step 2: Re-run the permission assertion against the final tree**

```bash
bash "$TMPDIR/assert-perms.sh"
```

Expected: `PASS: permission arrays match the tier model`. Re-running after Tasks 2 and 3 confirms neither documentation commit disturbed the template.

- [ ] **Step 3: Preview the deployment**

```bash
chezmoi diff ~/.claude/settings.json
```

Expected: exactly the five-entry move — additions in `allow`, removals in `ask`, nothing else. If any other key differs, there is uncommitted drift in the deployed target; resolve it before applying.

- [ ] **Step 4: Apply**

```bash
chezmoi apply ~/.claude/settings.json
```

- [ ] **Step 5: Confirm real behavior in a fresh session**

This cannot be automated — permission prompts are interactive and settings are read at session start. Start a new Claude Code session in this repository and confirm:

- `git commit` runs with no approval prompt
- `git push` **still prompts** (returned to `ask` in final review — see the correction banner)
- `gh pr create` still prompts
- `gh pr edit` still prompts
- `git reset` still prompts

Report the result. If a command that should be silent still prompts, the most likely cause is that `~/.claude/settings.local.json` or a project-scope settings file carries a conflicting entry — check with `/permissions`.

---

## Notes for the reviewer

**Deliberately not included, and why:**

- **No permanent `make` target for the permission assertion.** A committed regression test would catch a future edit that accidentally moves `gh pr create` into `allow`, which is real value. It is excluded because the spec's scope did not include it and PR #224 set the precedent of ad-hoc assertion. Worth raising as a follow-up if permission drift ever actually occurs.
- **No `.claude/settings.json` in this repository.** It cannot affect `ask` rules. Adding a file that appears to grant permissions but does not is worse than adding nothing.
- **No PreToolUse permission hook.**
- **No audit of the remaining 44 `ask` entries.** Applying the tier model to them yields their current placement.

**The one thing this plan surfaces that the spec did not:** Task 2 Step 1. The `excludedCommands` trade-off in `CLAUDE.md` was justified by the `ask` gate that this change removes, so `git commit`/`git push` now run both outside the sandbox and without a prompt. The plan records the change in posture rather than silently leaving stale text. If that posture is not acceptable, the correcting move is to return `Bash(git push:*)` to `ask` — which reverts one Tier 1 entry without disturbing the tier model. **That is exactly what final review decided, for an additional reason this plan did not foresee: the force-push `deny` entries are prefix rules and never made `push` append-only in the first place. See the correction banner at the top of this file.**
