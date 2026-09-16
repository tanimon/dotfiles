# Permission Tier Model for git/gh Write Commands — Design

**Date:** 2026-07-25
**Status:** Approved (pending user review of this document)
**Module:** `dot_claude/settings.json.tmpl`

> **2026-07-25 correction (found in final review).** As first written, this design moved
> **six** entries and classified `Bash(git push:*)` as Tier 1 (append-only), justified by the
> force-push entries in `deny`. Final review of the branch found that justification false:
> those `deny` entries are *prefix* rules, so `git push origin main --force`,
> `git push origin +main`, and `git push --delete origin foo` / `git push origin :foo` all
> evade them, and `--delete` / `--mirror` / `--prune` are not append-only at all. Granting
> `push` would have converted force-push and remote-branch deletion from prompted to silent.
> `git push` was returned to `ask` and the Tier 1 claim retracted; **five** entries move. The
> tier definitions themselves are unchanged — `push` simply is not a member of Tier 1,
> because prefix matching cannot establish append-only-ness for it. Everything below reflects
> the corrected decision.

## Context

The original request was: "these git/gh commands are `ask` in global Claude Code settings,
but I want them `allow` in this repository." Investigation showed that request is not
satisfiable as stated, and the reason generalizes far beyond this one change.

### Why per-directory relaxation is impossible

Claude Code evaluates permission rules `deny` → `ask` → `allow`, first match wins, and this
order holds **across settings scopes**. From the official documentation:

> Rules are evaluated in order: deny, then ask, then allow. The first match in that order
> determines the outcome, and rule specificity doesn't change the order. [...] The same
> precedence applies between ask and allow: a matching ask rule prompts even when a more
> specific allow rule also matches the same call.

> The same holds across settings scopes: if user settings allow a permission and project
> settings deny it, the deny rule blocks it. The reverse is also true.

Three consequences, each verified against the docs:

1. **A project-scope `allow` cannot relax a user-scope `ask`.** Writing the rules into this
   repository's `.claude/settings.json` or `.claude/settings.local.json` has no effect.
2. **There is no ancestor-directory lookup for `permissions`.** Placing a settings file at
   a parent of many repositories does not apply to them:
   > Hooks and other `.claude/settings.json` keys load from the current working directory's
   > `.claude/` folder with no parent-directory fallback.

   This differs from skills, subagents, and slash commands, which *are* discovered from
   parent directories. `.claude/settings.local.json` loads from the git repository root
   (v2.1.211+), which is still repo-scoped, not tree-scoped.
3. **A PreToolUse hook cannot relax it either.** Hooks can only add restriction:
   > Claude Code evaluates deny and ask rules regardless of what a PreToolUse hook returns:
   > a matching deny rule blocks the call, and a matching ask rule still prompts even when
   > the hook returned `"allow"` or `"ask"`.

   `bypassPermissions` mode is likewise excluded: it "skips permission prompts, except those
   forced by explicit `ask` rules".

So the only two shapes that can express "gated here, not there" are:

- **(A)** A permissive declarative baseline plus a user-level PreToolUse hook that inspects
  `cwd` and returns `permissionDecision: "ask"` outside the relaxed directories.
- **(B)** A single global declarative policy, tuned by risk rather than by location.

**(B) was chosen.** (A) moves the gate from a one-line declarative rule into a shell script
whose correctness becomes security-critical, must re-implement Claude Code's compound-command
parsing (`env FOO=1 git push`, `foo && git push`) to avoid failing open, and must exit 2 —
not 1 — on internal error, which conflicts with this repo's hook exit-code contract in
`.claude/rules/shell-scripts.md`. Under `defaultMode: auto` with `gh *` in
`sandbox.excludedCommands`, the `ask` gate is the only remaining control on `gh` mutations
(see `docs/solutions/integration-issues/claude-code-defaultmode-auto-gh-command-gating.md`),
so trading a declarative gate for a scripted one is a poor exchange.

Choosing (B) means this change applies to **every** repository. That is an accepted
consequence, not an oversight.

## The tier model

The current `ask` list (49 entries: 41 `gh`, 8 `git`) was assembled incrementally across
PR #217 and PR #224 without an explicit classification rule. This design introduces one, so
future additions have a criterion to be judged against instead of being argued case by case.

Two axes: **is it reversible**, and **does it reach other people** (notification, queue,
durable record, CI).

| Tier | Definition | Destination |
|------|------------|-------------|
| **0** | Local-only and fully reversible. Nothing leaves the machine until pushed. | `allow` |
| **1** | **Append-only** to an existing container. Creates no new work item and changes no shared object's state or anyone's queue. | `allow` |
| **2** | Changes shared object state: lifecycle transitions (create / close / reopen / ready / merge / transfer), mutation of existing objects, and review verdicts. Reaches other people's visibility or queue. | `ask` |
| **3** | Destructive, irreversible, or history-rewriting. | `ask`, or `deny` when there is no legitimate agent use |

The append-only axis is what makes the resulting placement coherent. `gh pr comment` is
`allow` while `gh pr edit` is `ask` — apparently inverted, since commenting notifies people
and editing only touches metadata — because a comment appends to an existing thread and
creates no work item, whereas `--add-reviewer` / `--add-assignee` mutate a shared object and
push work into someone's queue.

Membership in Tier 1 additionally requires that the append-only property be **enforceable by
the rule syntax available**. Prefix matching is all `permissions` offers, so a command whose
destructive spellings can be reached by moving a flag past the prefix cannot be Tier 1 no
matter how its common invocation behaves. `git push` fails exactly this test — see the
`stays in ask` table below.

## Changes to `dot_claude/settings.json.tmpl`

Five entries move from `ask` to `allow`. `deny` is unchanged.

| Tier | Entry | Rationale |
|------|-------|-----------|
| 0 | `Bash(git commit:*)` | Local. Reversible via `amend` / `reset`. Invisible to others until pushed. |
| 0 | `Bash(git merge:*)` | Local. Recoverable via `ORIG_HEAD`. Aborts rather than overwriting local modifications, so it cannot destroy uncommitted work. |
| 0 | `Bash(git revert:*)` | Local. Only creates a new commit. |
| 1 | `Bash(gh pr comment:*)` | Appends to a thread. Editable and deletable. |
| 1 | `Bash(gh issue comment:*)` | Same as above; kept symmetric with the PR verb. |

Resulting counts: `ask` 49 → 44 (`gh` 41 → 39, `git` 8 → 5); `allow` 58 → 63; `deny` 46
unchanged.

### What deliberately stays in `ask`

| Entry | Tier | Reason |
|-------|------|--------|
| `gh pr create` / `close` / `reopen`, `gh issue create` / `close` / `reopen` | 2 | Lifecycle transitions. Create puts a new work item into other people's field of view and triggers CI. |
| `gh pr edit`, `gh issue edit` | 2 | `--add-reviewer` / `--add-assignee` place work directly into someone's queue. Prefix matching cannot separate those from `--title`; the write intent lives in a flag, not a fixed prefix — the same limitation already documented for `gh api --method`. Rather than pretend a `Bash(gh pr edit --add-reviewer:*)` rule provides protection it cannot (argument order defeats it), the whole verb stays gated. |
| `gh pr ready` | 2 | Leaving draft is a formal review request. `--undo` exists, but the notification cannot be recalled. |
| `gh pr review` | 2 | Approve / request-changes can be submitted on anyone's PR and survive dismissal in the record. |
| `gh pr merge` | 2 | Unchanged from #224. |
| `gh issue delete`, `gh issue transfer` | 3 | Irreversible or hard to undo. |
| `git push` (**superseded 2026-09-16 — see the addendum at the end of this document; it left `ask` and is now hook-enforced**) | not Tier 1 | A plain `git push` does append to an existing branch, but the append-only property is not expressible in prefix rules. The `deny` entries `Bash(git push --force:*)`, `--force-with-lease`, and `-f` match only when the flag immediately follows `git push`; `git push origin main --force`, `git push origin main -f`, and `git push origin +main` are all force pushes that evade them, and `git push --delete origin foo`, `git push origin :foo`, `git push --mirror`, `git push --prune` delete remote refs outright. Granting `push` would make every one of those silent. Same flag-position problem as `git reset` below and `gh api`. The `deny` entries are retained, but they close only the leading-flag spellings — the `ask` gate is what actually covers the rest. |
| `git reset` | 3 | `--hard` destroys uncommitted work unrecoverably. Splitting `Bash(git reset --hard:*)` into `ask` while allowing `Bash(git reset:*)` is defeated by `git reset HEAD~1 --hard` — the flag-position problem again. |
| `git rebase`, `git cherry-pick`, `git filter-branch` | 3 | History rewriting. |
| `gh release` / `secret` / `variable` / `workflow` / `repo` / `label` / `gist` / `run` / `cache` verbs | 2–3 | Unchanged. Applying the tier model to them produces the same placement they already have. |

### Explicit `allow` enumeration

Under `defaultMode: auto`, removing an entry from `ask` is sufficient to make it run without
a permission prompt. (**2026-09-16 correction:** this section originally said "an unlisted
command is auto-approved". That is imprecise — an unlisted command is routed to auto mode's
classifier, which decides per invocation and can still prompt. The distinction matters for
the addendum below: delegating to the classifier is a probabilistic gate, not the absence of
one, and it is not reproducible enough to test deterministically.) The five entries are
nonetheless enumerated in `allow` for:

- visibility in `/permissions`
- recording intent, so a future reader sees a deliberate grant rather than an accidental omission
- resilience if `defaultMode` is ever returned to `default`

This matches how `git add` and `git checkout` are already handled. Entries are inserted
preserving the list's existing alphabetical order.

## Accepted residual risks

1. **`git commit` runs unsandboxed *and* unprompted.** `git commit` is in
   `sandbox.excludedCommands` (so `op-ssh-sign` can reach the 1Password SSH agent socket) and
   now also in `allow`, so a repo-controlled pre-commit hook executes outside the sandbox with
   nothing prompting. Accepted on the basis that work happens in trusted repositories, and
   because this repo's own `prek`/`secretlint` pre-commit hooks must not be neutralized —
   disabling them would remove a real secret-detection gate. Revisit if untrusted
   repositories enter the workflow. `git push` is *not* part of this residual: it stayed in
   `ask`, so its unsandboxed SSH transport and `network.allowedDomains` bypass remain
   prompt-backstopped. See
   `docs/solutions/integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md`.
2. **`gh pr comment` / `gh issue comment` reach other people.** Commenting on someone else's
   PR sends a notification. Accepted because the action is append-only and both editable and
   deletable.
3. **`git merge` can produce a conflicted working tree.** Recoverable; merge aborts rather
   than overwriting local modifications.

## Documentation changes

- **`CLAUDE.md`** — the "git write governance" sentence in the native Bash sandbox section
  states that `commit` is `ask`-gated, which this change falsifies (`push` remains accurate).
  Rewrite both the git and gh governance passages around the tier model; record why
  `gh pr comment` is `allow` while `gh pr edit` is `ask`, since that pairing looks wrong
  without the append-only axis, and record why `push` is *not* Tier 1 despite appending, so
  the question is not reopened.
- **`docs/solutions/integration-issues/`** — one new document recording the three
  constraints from the Context section. The durable value is the constraint, not this
  particular list of five commands: without it, the next attempt to scope permissions by
  directory will repeat the same dead end (project `allow`, then a hook returning `"allow"`,
  then `bypassPermissions`). Cross-reference
  `claude-code-defaultmode-auto-gh-command-gating.md` and
  `native-sandbox-1password-socket-signing-2026-07-09.md`.

## Verification

1. `make check-templates` — template renders.
2. Render with `chezmoi execute-template --config <test toml> --source "$(pwd)"` and assert
   with `jq`, following the procedure established in #224:
   - each of the five entries appears in `allow` and is absent from `ask`
   - `allow` length is 63; `ask` length is 44, `gh`-prefixed 39, `git`-prefixed 5
   - `deny` is byte-identical to before the change
   - `gh pr edit`, `gh pr create`, `gh pr review`, `gh pr ready`, `git push`, `git reset` are
     still in `ask`
3. `make lint` (secretlint, shellcheck, shfmt, oxlint, oxfmt, actionlint, zizmor, modify\_
   tests, script tests, templates, sensitive scan).
4. `make scan-sensitive` — new markdown files are covered.
5. `chezmoi apply`, then confirm in a fresh session that `git commit` runs without a prompt
   and `gh pr create` still prompts.

## Out of scope

- No `.claude/settings.json` in this repository. It would have no effect on `ask` rules, and
  adding a file that appears to grant permissions but does not is worse than adding nothing.
- No PreToolUse permission hook.
- No audit of the remaining 44 `ask` entries. Applying the tier model to them yields their
  current placement, so there is nothing to change.
- No change to `deny`.
- `gh api` remains unlisted and therefore falls to auto mode's classifier under
  `defaultMode: auto` — the known residual tracked in issue #225. Unaffected by this change.

---

## Addendum — 2026-09-16: `git push` moves out of `ask`, gated by a `PreToolUse` hook

**Status:** Approved. Supersedes the "No PreToolUse permission hook" line in *Out of scope*
above and moves `Bash(git push:*)` out of the *What deliberately stays in `ask`* table.

### Problem

The blanket `Bash(git push:*)` in `ask` prompted on every push, including the routine
append-only case that is most of them. That is approval fatigue, and approval fatigue is
itself a security problem: a gate that fires constantly gets click-through-approved without
reading.

The obvious fix — drop the entry and let auto mode's classifier decide — is the exact move
this document retracted in its 2026-07-25 correction, only with a probabilistic gate in place
of no gate. It leaves `git push origin main --force`, `git push origin +main`,
`git push --delete origin foo`, `git push origin :foo`, `--mirror`, and `--prune` to LLM
judgment, and that judgment cannot be tested deterministically (a fresh session per trial,
non-reproducible), which conflicts with this repository's rule that monitoring is
deterministic shell and LLM judgment runs only where failures are visible.

### Decision

Split the two cases rather than choosing between them.

- `Bash(git push:*)` is removed from `ask`.
- `dot_claude/scripts/executable_git-push-guard.sh` runs as a `PreToolUse` hook with
  `matcher: "Bash"`. It reads the whole command string, so it finds the dangerous flag
  **wherever it sits** — the property prefix matching structurally cannot provide.
- Decisions: `deny` for `--force` / `--force-with-lease[=…]` / `--force-if-includes` /
  `--delete` / `--mirror` / `--prune`, a bundled short option containing `f` or `d`, a
  `+`-prefixed refspec, and a `:`-prefixed (empty-source) refspec. `ask` when the push
  segment cannot be read through — a variable, a command substitution, or a `-c` override
  mentioning `push`. No output otherwise, so a plain push falls to the classifier without a
  prompt.
- Segments are split on `;`, `&`, `|`, and newlines, so a force push hidden after `&&` is
  still seen.
- `deny` for the destructive spellings (rather than `ask`) follows the 2026-09-15 precedent
  set for `gh pr merge` / `revert`: leaving a click-through gate is where the prompts come
  back, and force push is a thing the human does from their own terminal.

### Why this is not Tier 1

Tier 1 membership requires the safety property be **enforceable by the rule syntax
available**. A hook is a different channel with two properties a rule does not have:

1. **It can fail open.** If the script is absent (a machine before `chezmoi apply`),
   unwired, or crashes, it emits nothing and the tool call proceeds through the normal
   permission flow. A rule is always evaluated. This is why the three leading-flag `deny`
   entries (`--force`, `--force-with-lease`, `-f`) are **retained** rather than deleted as
   redundant — they are the floor when the hook is not there.
2. **Its coverage is a token scan, not a semantic one.** It reads the command string the
   agent issues, not what that string ultimately does.

The correct label is **hook-enforced**, a third category alongside the rule-enforced tiers.

### Residuals (unchanged or newly accepted)

| Residual | Status |
|---|---|
| A force refspec reached through a shell alias or function | Not covered. The token scan reads the literal command only. |
| A wrapper or keyword that displaces `git` from position 0 — `env X=y git push …`, `VAR=v git push …`, `command`/`time`/`nohup`/`sudo`/`nice`/`exec`, and the one-line `for … do git push …; done` / `if …; then …; fi` forms | **Covered** (2026-09-16 review). The scan skips leading assignments and a fixed list of shell keywords and command prefixes before reading the binary, so these `deny` like any other push. `(cd … && git push …)` is covered by the same normalization pass that handles grouping punctuation. A prefix outside that list (`xargs -n1 git push … --force`) falls to `ask`, not silence. |
| `eval "…"` or `bash -c "…"` wrapping the push | Not covered. The inner string is opaque to the scan and the outer segment's `git` is quoted, which the fallback deliberately treats as text. |
| `gh api` performing the equivalent server-side operation | Not covered; the pre-existing #225 residual. |
| `$(…)` containing `&&`, which breaks the segment split | Not covered; the segment would be mis-split. Low realism. `$(git push … --force)` and the backtick form without `&&` fall to `ask` via the fallback — a substitution executes, so its delimiters are stripped, unlike the quotes around `echo "git push --force"`. |
| `git config remote.<name>.push …` or `git remote set-url …` in the same command string, followed by a plain push | **Not covered.** The `-c` form of the same redirection is caught (`ask`), the persistent form is not. Tracked as follow-up. |
| `git -c remote.<name>.url=…` redirecting the push to another remote | **Not covered.** The `-c` scan asks on `push` and `mirror` values only; `url` was left out because the substring is common enough in unrelated config that the false-`ask` rate is unmeasured. Same class as the row above. |
| A flag spelled through quoting or escapes — `--f'or'ce`, `--fo\rce` | Not covered. The scan is lexical, not a shell-accurate unquote; only one layer of surrounding quotes is stripped. Adversarial-only. |
| A command string long enough to exceed the hook's 5 s timeout | **Not covered.** `unquote` forks per token, so the scan is linear in token count and crosses 5 s at roughly 9,500 tokens; a timeout is a missing decision, i.e. fail-open. Far outside any real push. Tracked as follow-up. |
| Plain `git push` now runs **outside the sandbox with no prompt** | **Newly accepted.** `sandbox.excludedCommands` contains `git push *`, and the `ask` prompt was what suppressed that bypass of `network.allowedDomains`. The follow-up is to remove `git push *` from `excludedCommands` (the `insteadOf` flip should have made push HTTPS), but that is only verifiable in a fresh session and belongs in its own PR. |

### Verification

- `test/git-push-guard.bats` (62 cases), wired into `just test-scripts` and therefore
  `just lint` and CI. The suite is built as a **contrast pair**: the deny/ask cases are
  paired with cases that must produce *no* output (`git push -u origin feature`,
  `--dry-run`, `--no-force-with-lease`, a safe push after `&&`, a non-git command carrying
  `-f`). Without that half, a guard that denied unconditionally would pass every assertion
  and still make the setting unusable.
- The rendered `settings.json` was checked for valid JSON, the presence of the hook entry,
  the absence of any `git push` entry in `ask`, and the retention of the three `deny` rules.
- The deployed hook command is the script path itself. An earlier
  `mkdir -p … && script 2>>log` wrapper was removed: a failed redirection abandons the whole
  command, so an unwritable log directory would have skipped the script entirely and turned a
  logging problem into a missing decision. The log target now lives inside the script, guarded,
  and `test/git-push-guard.bats` pins that an unwritable `$HOME` still produces the `deny`.
- **Not verifiable on this branch:** that Claude Code actually invokes the hook.
  `chezmoi apply` deploys from `main`, and `settings.json` is read at session start. Confirm
  in a fresh session after merge that `git push origin <branch>` runs without a prompt and
  `git push origin <branch> --force` is refused.
