# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Managed files

### Source
The version-controlled file this repository owns and edits — the authority for what a managed file should contain. Naming conventions on a Source's filename encode how it maps to its Target and what permissions the Target receives, so the mapping is derived from the name rather than declared separately.

A Source is not always a literal copy of its Target. Some Sources are templates rendered per machine; others are scripts that receive the current Target and emit a modified version, letting the repository own only a subset of a file whose remainder is written by an external tool at runtime.

### Target
The deployed file in the home directory that a Source renders to. Targets are generated output: an edit made directly to a Target is overwritten the next time the repository is applied and is never version-controlled. Every "where do I change this?" resolves to the Source, never the Target.

Rendering is one-directional and is performed from whichever checkout the tool treats as its source directory — not necessarily the checkout being edited. A change that is committed but not yet present in that source directory will not appear in a Target, and the absence reads as "nothing to deploy" rather than as an error.

A Target's writers are not only the people who open it. The application a Target configures often writes its own settings back into that same file at runtime, and such a write is indistinguishable from a hand edit — it is discarded by the next apply just the same, silently and with no record of what was there. A setting that keeps being lost this way is a setting whose home is the Source.

When a Target is only partially owned — its Source is a script that reads the Target's current state and re-emits a modified version, rather than a template rendered from scratch — the transform re-derives the whole file from whatever it currently observes on every run. If that observation is empty or corrupted (a race with another writer, an aborted run), the Target's entire unmanaged portion can be lost even though the Source itself was never touched.

## Permission policy

### Risk Tier
A four-level classification of a write command by how reversible its effect is and how far that effect reaches, used to decide whether the command runs unprompted or behind an approval gate. Tier 0 is local and fully reversible. Tier 1 appends to an existing container, creating no new work item and changing neither shared object state nor anyone's queue. Tier 2 changes shared object state — lifecycle transitions, mutation of existing objects, review verdicts. Tier 3 is destructive, irreversible, or rewrites history.

Tier 1 carries a second requirement beyond the append-only property merely being true: the property must be **enforceable by the permission rule syntax**. Rules match on command prefixes, so a command whose destructive spellings can be reached by moving a flag past the prefix cannot be Tier 1, however append-only its ordinary invocation appears. This requirement exists because classifying by concept rather than by what the matcher can express once silently removed a guardrail.
