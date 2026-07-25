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
| `git push` | not Tier 1 | A plain `git push` does append to an existing branch, but the append-only property is not expressible in prefix rules. The `deny` entries `Bash(git push --force:*)`, `--force-with-lease`, and `-f` match only when the flag immediately follows `git push`; `git push origin main --force`, `git push origin main -f`, and `git push origin +main` are all force pushes that evade them, and `git push --delete origin foo`, `git push origin :foo`, `git push --mirror`, `git push --prune` delete remote refs outright. Granting `push` would make every one of those silent. Same flag-position problem as `git reset` below and `gh api`. The `deny` entries are retained, but they close only the leading-flag spellings — the `ask` gate is what actually covers the rest. |
| `git reset` | 3 | `--hard` destroys uncommitted work unrecoverably. Splitting `Bash(git reset --hard:*)` into `ask` while allowing `Bash(git reset:*)` is defeated by `git reset HEAD~1 --hard` — the flag-position problem again. |
| `git rebase`, `git cherry-pick`, `git filter-branch` | 3 | History rewriting. |
| `gh release` / `secret` / `variable` / `workflow` / `repo` / `label` / `gist` / `run` / `cache` verbs | 2–3 | Unchanged. Applying the tier model to them produces the same placement they already have. |

### Explicit `allow` enumeration

Under `defaultMode: auto`, removing an entry from `ask` is sufficient to make it
auto-approved — an unlisted command is auto-approved. The five entries are nonetheless
enumerated in `allow` for:

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
- `gh api` remains unlisted and therefore auto-approved under `defaultMode: auto` — the known
  residual tracked in issue #225. Unaffected by this change.
