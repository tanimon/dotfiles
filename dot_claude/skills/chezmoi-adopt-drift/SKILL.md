---
name: chezmoi-adopt-drift
description: |
  Use when the user has hand-edited a dotfile in place under `~/` and wants those
  live changes pulled back into their chezmoi source repo — the opposite direction
  of `chezmoi apply`. This is selective `chezmoi re-add`: fold in some changes,
  hunks, or files while dropping others, so nothing gets silently reverted on the
  next apply.

  Trigger on intents like: `chezmoi status`/`chezmoi diff` shows files edited by
  hand (`M`/`MM`) and the user wants those edits saved into the source/dotfiles
  repo; re-add but only certain hunks, not the whole file; list what drifted and
  pick which to keep; an `export`/alias/setting added in `~/` that would vanish on
  apply and should be preserved. Fires in Japanese or English, even when the user
  never says "chezmoi," "drift," or "source" — as long as the intent is "edits I
  made to a deployed config in `~/` should go back into my dotfiles repo,
  selectively."

  Do NOT use for: `chezmoi add` of a brand-new file, `chezmoi apply` (source→home),
  listing managed files, plain git commit/PR, or non-chezmoi drift (e.g. Terraform).
---

# chezmoi-adopt-drift

Pull hand-edits made to deployed files (targets in `~/`) back into their
chezmoi source files, so `chezmoi apply` stops trying to revert them. The user
decides — per file, and per hunk within a file — which changes to keep.

## Why this needs care

chezmoi treats the **source** as truth: `chezmoi apply` overwrites the target
with what the source generates. So any change made directly in `~/` is
transient — it disappears on the next apply. "Adopting drift" means copying the
change the other direction, into the source, which is the durable location.

The trap: **the source is not always a verbatim copy of the target.** A
`.tmpl` source contains `{{ .chezmoi.homeDir }}` where the target has a real
path; a `modify_` source is a *script* whose output is the target. Blindly
writing target content over these sources destroys the template/script. This
skill classifies each drifted file first, and only auto-adopts the safe ones.

## Workflow

### 1. Find the drift

```sh
chezmoi status
```

The **first column** is drift: `M` = the actual file differs from what chezmoi
last wrote (someone edited the target), `D` = target was deleted, `A` = a new
file appeared where chezmoi expects none. The second column is what `apply`
*would* do. You care about the first column.

If the user named specific files, scope to them: `chezmoi status <path>...`.

Ignore entries where the first column is a space — those have no drift.

### 2. Classify each drifted target

For every drifted target, resolve its source and read the entry type — this
decides whether it is safe to adopt automatically:

```sh
chezmoi source-path "$HOME/.zshrc"   # -> .../dot_zshrc  (or dot_zshrc.tmpl, etc.)
```

| Source basename            | Type            | How to adopt                          |
|----------------------------|-----------------|---------------------------------------|
| plain (e.g. `dot_zshrc`)   | regular file    | **safe** — `re-add` or hunk-edit      |
| ends in `.tmpl`            | template        | **manual** — must re-insert variables |
| starts `modify_`           | modify script   | **manual** — drift is vs script output|
| starts `run_`/`create_`    | script/once     | skip — not a normal editable target   |
| starts `symlink_`          | symlink         | skip                                   |

Classify by inspecting the basename `chezmoi source-path` returns. Do not judge
`modify_dot_claude.json` by its `.json` extension — the `modify_` prefix wins;
it is a script.

### 3. Show the drift and let the user choose

For each drifted target, get the drift as a patch **in the direction that
describes what changed in the target**:

```sh
chezmoi diff --reverse --no-pager "$HOME/.zshrc"
```

`--reverse` flips chezmoi's default (which shows how to *undo* the drift) so the
diff reads source → actual: the `+` lines are what the user added in the target,
`-` lines what they removed. That is the change you are considering adopting.

Present a compact summary to the user: each drifted file, its type
(regular/template/modify), and its hunks numbered. Then ask which to adopt.

- **Few files, few hunks (≤4 choices):** use AskUserQuestion with
  `multiSelect: true`, one option per hunk (label it with the file + a one-line
  gist of the hunk).
- **Many hunks:** print a numbered list and ask the user to reply with the
  numbers to adopt (e.g. "1, 3, 4"). Offer "all" and "none" as shortcuts.

Never assume "adopt everything" — the whole point is selective adoption. Some
drift is accidental (a tool rewrote formatting) and the user will want to drop
it, letting the next `chezmoi apply` clean it up.

### 4. Apply the chosen changes to the SOURCE

Always edit the **source** file, never the target — edits to the target are
erased on the next apply and are not version-controlled. Find the source with
`chezmoi source-path`.

**Regular file, adopt the whole file:** let chezmoi do it — it is exact and
preserves file attributes:

```sh
chezmoi re-add "$HOME/.zshrc"
```

`re-add` refuses templates and ignores scripts by design, which matches the
classification above.

**Regular file, adopt only some hunks:** re-add takes the whole file, so for a
subset, edit the source directly with the Edit tool. The source content equals
what `chezmoi cat "$HOME/.zshrc"` prints (the target state before drift), so
transcribe only the selected `+`/`-` hunks from step 3 into the source. Leave
the un-selected regions untouched.

**Template (`.tmpl`) or `modify_` — do NOT auto-write.** The source is not the
target's content. Adopt by hand, reconciling the change into the source's real
shape:

- **`.tmpl`:** re-insert template variables. If the drift added a line
  containing `/Users/alice/...`, the source must use `{{ .chezmoi.homeDir }}`,
  not the literal path. Preserve existing `{{ ... }}` regions. Read the file
  first to match its templating style.
- **`modify_`:** the source is a script that transforms the current target on
  stdin (see `modify_dot_claude.json`, which uses `jq` to own only a subset of
  keys). Drift here means the *managed* portion changed. Only reflect the
  change if it falls inside the keys the script owns; if the drift is in a
  key the script deliberately passes through untouched, there is nothing to
  adopt — tell the user. Never overwrite the script with target content.

Show the user the exact source edit before making it for the manual cases, so
they can confirm the reconciliation is right.

### 5. Verify

After adopting, confirm the source now matches the (kept) intent:

```sh
chezmoi diff --no-pager "$HOME/.zshrc"   # adopted hunks -> gone; dropped hunks -> remain
chezmoi status "$HOME/.zshrc"
```

For fully-adopted files the diff should be empty. For partially-adopted files,
the remaining diff should be exactly the hunks the user chose to *drop* — point
this out so they know `chezmoi apply` will revert those. Do not run
`chezmoi apply` yourself unless the user asks; adopting drift is a source-side
operation and apply is a separate, target-mutating step.

## Guardrails

- **Never edit the target to "fix" drift.** The source is the durable side.
- **Never `chezmoi apply` to resolve drift** unless the user explicitly wants
  to discard their target edits — apply destroys un-adopted drift.
- **Templates and modify_ scripts are never machine-copied** from the target.
  Reconcile them by hand with the variables/script structure intact.
- **Report honestly:** if a drift can't be cleanly adopted (e.g. it lands in a
  passed-through key of a modify_ script, or a template region you can't safely
  reconstruct), say so and leave it for the user rather than guessing.
