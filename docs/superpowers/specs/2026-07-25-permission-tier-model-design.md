# Permission Tier Model for git/gh Write Commands — Design

**Date:** 2026-07-25
**Status:** Approved (pending user review of this document)
**Module:** `dot_claude/settings.json.tmpl`

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

The append-only axis is what makes the resulting placement coherent. `git push` is `allow`
while `gh pr edit` is `ask` — apparently inverted, since one is a remote write and the other
edits metadata — because push appends commits to an existing branch (force-push is already
in `deny`, and rewriting published history is therefore blocked) whereas edit mutates a
shared object.

## Changes to `dot_claude/settings.json.tmpl`

Six entries move from `ask` to `allow`. `deny` is unchanged.

| Tier | Entry | Rationale |
|------|-------|-----------|
| 0 | `Bash(git commit:*)` | Local. Reversible via `amend` / `reset`. Invisible to others until pushed. |
| 0 | `Bash(git merge:*)` | Local. Recoverable via `ORIG_HEAD`. Aborts rather than overwriting local modifications, so it cannot destroy uncommitted work. |
| 0 | `Bash(git revert:*)` | Local. Only creates a new commit. |
| 1 | `Bash(git push:*)` | Appends to an existing branch. All three force-push spellings (`--force`, `--force-with-lease`, `-f`) remain in `deny`. |
| 1 | `Bash(gh pr comment:*)` | Appends to a thread. Editable and deletable. |
| 1 | `Bash(gh issue comment:*)` | Same as above; kept symmetric with the PR verb. |

Resulting counts: `ask` 49 → 43 (`gh` 41 → 39, `git` 8 → 4); `allow` 58 → 64; `deny` 46
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
| `git reset` | 3 | `--hard` destroys uncommitted work unrecoverably. Splitting `Bash(git reset --hard:*)` into `ask` while allowing `Bash(git reset:*)` is defeated by `git reset HEAD~1 --hard` — the flag-position problem again. |
| `git rebase`, `git cherry-pick`, `git filter-branch` | 3 | History rewriting. |
| `gh release` / `secret` / `variable` / `workflow` / `repo` / `label` / `gist` / `run` / `cache` verbs | 2–3 | Unchanged. Applying the tier model to them produces the same placement they already have. |

### Explicit `allow` enumeration

Under `defaultMode: auto`, removing an entry from `ask` is sufficient to make it
auto-approved — an unlisted command is auto-approved. The six entries are nonetheless
enumerated in `allow` for:

- visibility in `/permissions`
- recording intent, so a future reader sees a deliberate grant rather than an accidental omission
- resilience if `defaultMode` is ever returned to `default`

This matches how `git add` and `git checkout` are already handled. Entries are inserted
preserving the list's existing alphabetical order.

## Accepted residual risks

1. **`git push` in unprotected repositories.** This repo's `main` carries an active ruleset
   (`deletion`, `non_fast_forward`, `required_signatures`, `pull_request`, `code_scanning`,
   `code_quality`, `copilot_code_review`), so direct pushes to `main`, force pushes, and
   branch deletion are refused server-side. Repositories without equivalent protection get
   no such backstop, and a bare `git push` while `main` is checked out cannot be
   distinguished by prefix matching from a feature-branch push. Mitigation is defence in
   depth (`deny` on all force-push forms, branch protection on repositories that matter),
   not the permission layer.
2. **`gh pr comment` / `gh issue comment` reach other people.** Commenting on someone else's
   PR sends a notification. Accepted because the action is append-only and both editable and
   deletable.
3. **`git merge` can produce a conflicted working tree.** Recoverable; merge aborts rather
   than overwriting local modifications.

## Documentation changes

- **`CLAUDE.md`** — the "git write governance" sentence in the native Bash sandbox section
  states that `commit` and `push` are `ask`-gated, which this change falsifies. Rewrite both
  the git and gh governance passages around the tier model, and record why `git push` is
  `allow` while `gh pr edit` is `ask`, since that pairing looks wrong without the append-only
  axis.
- **`docs/solutions/integration-issues/`** — one new document recording the three
  constraints from the Context section. The durable value is the constraint, not this
  particular list of six commands: without it, the next attempt to scope permissions by
  directory will repeat the same dead end (project `allow`, then a hook returning `"allow"`,
  then `bypassPermissions`). Cross-reference
  `claude-code-defaultmode-auto-gh-command-gating.md` and
  `native-sandbox-1password-socket-signing-2026-07-09.md`.

## Verification

1. `make check-templates` — template renders.
2. Render with `chezmoi execute-template --config <test toml> --source "$(pwd)"` and assert
   with `jq`, following the procedure established in #224:
   - each of the six entries appears in `allow` and is absent from `ask`
   - `ask` length is 43, `gh`-prefixed 39, `git`-prefixed 4
   - `deny` is byte-identical to before the change
   - `gh pr edit`, `gh pr create`, `gh pr review`, `gh pr ready`, `git reset` are still in `ask`
3. `make lint` (secretlint, shellcheck, shfmt, oxlint, oxfmt, actionlint, zizmor, modify\_
   tests, script tests, templates, sensitive scan).
4. `make scan-sensitive` — new markdown files are covered.
5. `chezmoi apply`, then confirm in a fresh session that `git commit` runs without a prompt
   and `gh pr create` still prompts.

## Out of scope

- No `.claude/settings.json` in this repository. It would have no effect on `ask` rules, and
  adding a file that appears to grant permissions but does not is worse than adding nothing.
- No PreToolUse permission hook.
- No audit of the remaining 43 `ask` entries. Applying the tier model to them yields their
  current placement, so there is nothing to change.
- No change to `deny`.
- `gh api` remains unlisted and therefore auto-approved under `defaultMode: auto` — the known
  residual tracked in issue #225. Unaffected by this change.
