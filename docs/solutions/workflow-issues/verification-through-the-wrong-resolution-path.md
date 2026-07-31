---
title: A verification that resolves a different path than the artifact under test passes vacuously
date: 2026-07-25
category: workflow-issues
module: verification-design
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - "Running any bare chezmoi command (apply, diff, managed, ignored, execute-template) from a git worktree whose path differs from chezmoi's configured source directory"
  - "Designing or reviewing a verification step for a tool that resolves its target from configuration rather than from the current working directory"
  - "Verifying that something worked by asserting on an end state that some other action could also have produced"
  - "Trusting a check that has only ever been observed passing"
  - "fail open で degrade する強制機構（サンドボックス、feature flag、`|| true`）に許可を追加し、1 回の成功だけでその許可が効いたと判断しようとしているとき"
  - "Diagnosing unexplained drift between a deployed target and its source when more than one checkout of the same repo exists on the machine"
symptoms:
  - "\"chezmoi managed | grep <new-entry>\" reports the expected result even though the entry exists only on a branch chezmoi is not reading"
  - "Unexplained drift between ~/ and the source tree, misdiagnosed as a concurrent session editing files"
  - "chezmoi execute-template renders a script whose resolved sourceDir points into a different worktree"
  - "A tool reports ALLOWED or PASS for something that is in fact impossible or never ran"
tags:
  - verification
  - vacuous-check
  - fail-open
  - chezmoi
  - git-worktree
  - silent-failure
  - discoverability
related_components:
  - tooling
  - documentation
---

# A verification that resolves a different path than the artifact under test passes vacuously

## Context

A verification step is supposed to be evidence. It only produces evidence if it resolves to the
*same artifact* the change touched. When the tool reaches its target through a different
resolution path than the thing you edited, the check still runs, still exits zero, and still
prints a green line — while proving nothing.

That is worse than a missing check. A missing check leaves you uncertain, and uncertainty prompts
more looking. A vacuous check leaves you *confident and wrong*, and confidence ends the
investigation. It is anti-informative: the signal actively points away from the truth.

This repository has a standing instance. The working checkout is a **git worktree**, and
chezmoi's *configured* source directory is a **different worktree of the same repo**:

```
$ git rev-parse --git-dir
~/.local/share/chezmoi/.git/worktrees/seal      # a worktree, not a main checkout
$ git rev-parse --git-common-dir
~/.local/share/chezmoi/.git                     # differs from --git-dir => worktree
$ chezmoi source-path
~/.local/share/chezmoi                           # on main, NOT the branch being edited
```

So every bare `chezmoi` invocation — `apply`, `diff`, `status`, `managed`, `ignored`,
`execute-template` — reads `main` and cannot see the branch's work. It does not error. It answers
a different question, fluently.

**The fix was already documented, and was still missed twice in one session.** That is the part
worth carrying forward. `check-templates-render-only-no-json-validation.md`'s Prevention section
already said, verbatim: "Always pass `--source "$(pwd)"` when rendering for verification. Without
it, `chezmoi` uses its configured source dir (`~/.local/share/chezmoi`), so edits made in a
separate worktree/checkout won't appear — the render (and any `chezmoi diff`) silently reflects
the wrong copy." The convention also lived in `Makefile:213`. Two agents in the same session still
walked into it, because the guidance was bullet two of four inside a document titled about JSON
validation depth. This is a **discoverability** failure, not a knowledge gap — which is why the
durable contribution here is the general principle, not the flag.

## Guidance

**Pass `--source "$(pwd)"` to every `chezmoi` invocation when the checkout is a worktree** — not
just to `execute-template`.

```sh
chezmoi managed  --source "$(pwd)"
chezmoi ignored  --source "$(pwd)"
chezmoi diff     --source "$(pwd)"
chezmoi execute-template --source "$(pwd)" < some.tmpl
chezmoi apply --force --source "$(pwd)" -- "$HOME/.config/foo"
```

**Detect the condition in three commands.** The first two are generic git; the third asks chezmoi
which tree it will actually read:

```sh
git rev-parse --git-dir           # .../.git/worktrees/<name>  => you are in a worktree
git rev-parse --git-common-dir    # .../.git                   => differs from above
chezmoi source-path               # the tree chezmoi will ACTUALLY read
```

If `chezmoi source-path` is not the directory you are editing, every bare chezmoi command is
lying to you. Verified at chezmoi v2.71.1:

```
$ chezmoi execute-template '{{ .chezmoi.sourceDir }}'
~/.local/share/chezmoi                          # wrong tree
$ chezmoi execute-template --source "$(pwd)" '{{ .chezmoi.sourceDir }}'
~/orca/workspaces/chezmoi/seal                  # correct
```

That divergence is not cosmetic.
`.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl:20` reads its input list from
`{{ .chezmoi.sourceDir }}/dot_config/nono/packs.txt`. Rendered without `--source`, the script
bakes in a path into the *other* worktree — a file that does not exist there.

**Second-order: `--source` alone is not enough for `apply`.** Once a managed target has been
modified outside chezmoi, `chezmoi apply` wants to confirm before overwriting, and a
non-interactive context cannot answer. Per the session that produced this learning, the prompt is
`<target> has changed since chezmoi last wrote it?`, followed by death with
`could not open a new TTY`. The escape is `--force` (`chezmoi apply --help`: "Make all changes
without prompting"). Scope the apply to the paths you changed:

```sh
chezmoi apply --force --source "$(pwd)" -- "$HOME/.config/foo"
```

Scoping is not tidiness. A full-tree apply re-triggers unrelated `run_onchange_` provisioning
scripts — real installs and network fetches you did not ask for.

**Reading vs deploying — two different decisions, and `CLAUDE.md` takes a stricter line on the
second.** Everything above is about *reads*: `managed`, `ignored`, `diff`, `execute-template`
must carry `--source` or they answer about the wrong tree, full stop. Whether to `apply` from an
unmerged branch at all is a separate call, and `CLAUDE.md`'s Known Pitfalls entry
("`chezmoi apply` deploys from `main`, not from your branch") says not to for routine work —
verify by rendering, deploy after the branch merges. That is the right default: an apply from a
branch puts unreviewed config into `~/`. The scoped-apply form above is for the case where you
deliberately need the artifact live to test it — this session applied
`~/.config/nono/profiles/claude-seal.json` that way because `nono run --profile` reads the
*deployed* profile, not the source tree, so the policy could not be exercised any other way. If
you are not in that situation, prefer rendering.

**The rule that generalizes: make the check fail first.** A verification you have never observed
failing has not been shown capable of detecting the thing it claims to detect. Before trusting a
new check, break the input on purpose and confirm a non-zero exit. `Makefile:435`
(`test-nono-profile`) was trusted only after three deliberate injections — an unknown key, a JSON
syntax error, and an unresolvable `extends` — each confirmed to exit non-zero. That is the
difference between a target that passes and a target that *works*.

## Why This Matters

**A green check that proved nothing.** Two entries were added to `.chezmoiignore` and verified
with `chezmoi managed | grep -E '^\.config/nono'`, expecting the new `packs.txt` to be absent.
It was absent. The rule looked correct. But the mechanism of that absence was not the ignore
rule — the *entire* `dot_config/nono/` directory does not exist in the tree chezmoi was reading:

```
$ ls ~/.local/share/chezmoi/dot_config/nono/
No such file or directory
```

Re-running with `--source` supplied the missing evidence: `chezmoi ignored --source "$(pwd)"`
lists `.config/nono/packs.txt` (matching `.chezmoiignore:12`), while
`chezmoi managed --source "$(pwd)"` lists the sibling entries and never `packs.txt`. The
conclusion had been right by luck, not by evidence — and right-by-luck is indistinguishable from
right-by-verification at the moment you record it, distinguishable only expensively later.

**A wrong diagnosis built on a wrong reading.** The same session ran `chezmoi diff`, saw files in
`~/` differing from source, and concluded *another session is concurrently editing files* —
recommending against proceeding. The real cause was the same wrong-worktree read: `~/` was behind
commits that existed on `main`. A tool silently answering a different question does not merely
withhold a fact; it manufactures a false mental model, and the model then generates its own
downstream decisions.

**The pattern is not chezmoi-specific.** Other instances — the first three from the same session as
the chezmoi one:

- `nono why --profile claude-seal --host github.com --port 22` reports `ALLOWED` for a connection
  that is impossible. The output is candid about why — `Reason: proxy_allowed`,
  `Source: domain allowlist` — because the tool models the HTTP(S) proxy, not raw TCP. It answered
  a question about a **different transport** than the one asked. A reader skimming for `ALLOWED`
  reads the opposite of the truth. (See
  `../integration-issues/nono-sandbox-migration-observations-2026-07-25.md`.)
- A `run_onchange_` script was "verified" by observing its *outcome* — the package was present.
  That proved nothing: the package had been installed by hand moments earlier and the script had
  never executed. What tested it was rendering and running it directly. Asserting on an end state
  that something *else* can also produce is the same trap in different clothes.
- **`git diff | grep '^[+-]'` verifies nothing in this repo.** `diff.external = difft`
  (difftastic) is configured globally, so `git diff` emits no `+`/`-` line prefixes at all. Any
  check piping `git diff` into a `^[+-]` grep matches zero lines and *looks like it passed*.
  This one caught the author of this document: while resolving a merge, a
  `git diff <base> origin/main -- CLAUDE.md | grep -E '^[+-]'` returned empty and was briefly
  read as "upstream did not touch this file" — when in fact upstream had changed it by 43 lines.
  Use `git diff --no-ext-diff` when a command needs unified output. See the corresponding entry
  in `CLAUDE.md`'s Known Pitfalls.
- **サンドボックスの許可キーは、片側だけの実行では検証できない**（2026-07-30、別 session）。
  `sandbox.network.allowUnixSockets` に 1Password の agent socket を追加して commit 署名が通った
  — それだけでは何も示せない。`dot_claude/settings.json.tmpl` の `sandbox.failIfUnavailable: false`
  によりサンドボックスは **fail open** で degrade するので、「通った」は (a) キーが Seatbelt まで
  配線された、(b) サンドボックスがそもそも適用されていない、のどちらとも整合する。決着させたのは
  対照ペア: `sandbox` ブロックだけを `claude -p --settings` に渡し、当該キーの有無を唯一の差分にした
  2 回の実行で `ssh-add -l` が `Operation not permitted` ↔ 鍵の列挙に反転することを確認した。
  上の 3 例と違い、**検査対象が間違っているのではなく、検査したい強制機構そのものが黙って不在に
  なりうる**ケースである。fail open な仕組み（graceful degradation、feature flag、`|| true`、
  「利用不可なら素通し」フラグ）はすべて同じ形の空虚な PASS を生むので、許可を足した側の成功では
  なく、**外した側の失敗**が証拠になる。(See
  `../integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md`.)

## When to Apply

The chezmoi-specific fix applies whenever `chezmoi source-path` differs from your working
directory — most commonly a git-worktree checkout, but also a symlinked or relocated source dir,
or a machine where `chezmoi.toml` pins `sourceDir`.

The general rule applies far more broadly. Suspect a vacuous check whenever:

- The tool resolves its target through configuration rather than from your cwd — a configured
  source/root/workspace dir, an env var, a registry, a lockfile, a global install.
- You are verifying by **outcome** rather than by **execution**, and something other than the
  artifact under test could produce that outcome.
- The check has only ever been observed passing.
- The tool models a subset of the real system (one transport, one backend, one platform) and your
  question is about a part it does not model.
- Two checkouts, containers, virtualenvs, or clusters of the same thing exist on the machine.

The cheapest reflex, applicable in all of these: **before you trust a check, break the thing it
checks and watch it go red.**

## Examples

**Vacuous → grounded.**

```sh
# Before: passes trivially, proves nothing.
# Reads main, where dot_config/nono/ does not exist at all.
chezmoi managed | grep -E '^\.config/nono'

# After: reads the tree you actually edited.
chezmoi ignored --source "$(pwd)" | grep '^\.config/nono'   # => .config/nono/packs.txt
chezmoi managed --source "$(pwd)" | grep '^\.config/nono'   # => siblings, never packs.txt
```

**Outcome-assertion → execution.**

```sh
# Before: "the package is installed, so the script works."
# The package was installed by hand. The script never ran.
nono profile list | grep claude

# After: run the artifact under test.
chezmoi execute-template --source "$(pwd)" \
  < .chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl | bash
```

**Applying from a worktree, safely.**

```sh
# Before: reads main, dies on an unanswerable TTY prompt, and on success
# would re-fire every unrelated run_onchange_ script.
chezmoi apply

# After: right tree, no prompt, scoped blast radius.
chezmoi apply --force --source "$(pwd)" -- "$HOME/.config/nono"
```

## Verification Notes

Confirmed against the current tree at chezmoi v2.71.1: the worktree/`source-path` divergence and
the `--source` fix for `execute-template`, `managed`, and `ignored`; the absence of
`dot_config/nono/` from the configured source dir; `.chezmoiignore:12`; the
`{{ .chezmoi.sourceDir }}` reference at
`.chezmoiscripts/run_onchange_after_pull-nono-packs.sh.tmpl:20`; the pre-existing
`--source "$$(pwd)"` convention at `Makefile:213`; the `test-nono-profile` target at
`Makefile:435`; the verbatim Prevention bullet in
`../integration-issues/check-templates-render-only-no-json-validation.md`; `--force` semantics
from `chezmoi apply --help`; and the `nono why` proxy-only answer.

Reported by the session that produced this learning and **not** re-verified here: the exact
`has changed since chezmoi last wrote it?` prompt and the `could not open a new TTY` failure
(reproducing them requires inducing drift on a managed target), and the three `test-nono-profile`
fault injections.

## Related

- [check-templates renders only, it does not validate JSON](../integration-issues/check-templates-render-only-no-json-validation.md) — same silent-failure
  family, and the doc whose Prevention section already carried the `--source` fix. Its framing is
  narrower (verification renders); this doc covers `apply`/`diff`/`managed`/`ignored` and the
  `--force`/TTY trap.
- [Project-specific harness rules and CI](../developer-experience/chezmoi-project-harness-rules-and-ci-2026-03-28.md) — states `--source`
  is needed for `include` resolution. That reason is real but incomplete: `--source` is required
  whenever the invoking worktree differs from the configured source dir, `include` or not.
- [nono sandbox migration observations](../integration-issues/nono-sandbox-migration-observations-2026-07-25.md) — source of the
  `nono why` transport-modelling instance cited above.
- [1Password SSH signing under the native sandbox](../integration-issues/native-sandbox-1password-socket-signing-2026-07-09.md)
  — fail open な強制機構の実例の出所。`nono why` の例と地続きで、そこで「間違った transport を
  モデルしている」原因になっている生 TCP と HTTP(S) プロキシの区別が、この変更で `git push` だけを
  `excludedCommands` に残す理由でもある。
- [.chezmoiignore blocking dot_gitignore deployment](../integration-issues/chezmoiignore-blocking-dot-gitignore-deployment-2026-04-03.md) — origin of
  the `chezmoi managed | grep` verification idiom this doc shows failing vacuously.
- `CLAUDE.md` Known Pitfalls carries two entries of this class, arrived at independently: the
  chezmoi-source-worktree one (which states the stricter deploy-after-merge default reconciled
  above) and the difftastic one. Both now point back here for the general shape; keep the three in
  sync if any of them changes.
- [Moving git push from ask to allow defeats the force-push deny prefix](../integration-issues/git-push-ask-to-allow-defeats-force-push-deny-prefix.md) — a neighbouring
  species worth knowing: not a check that resolves the wrong thing, but a *control* that covers
  less than it appears to, because permission rules match by prefix and write intent can migrate
  into a flag position. Same lesson shape — enumerate what the guard does **not** match before
  trusting it.
