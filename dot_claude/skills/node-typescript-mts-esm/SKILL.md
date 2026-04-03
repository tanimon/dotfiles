---
name: node-typescript-mts-esm
description: |
  Fix MODULE_TYPELESS_PACKAGE_JSON warning when running TypeScript files with
  node --experimental-strip-types. Use when: (1) Node.js warns "Module type of
  file is not specified and it doesn't parse as CommonJS", (2) running .ts files
  with ESM imports (import/export) without a package.json "type": "module",
  (3) writing TypeScript scripts for chezmoi executable_ files that use ESM.
  Solution: use .mts extension instead of .ts to signal ESM without needing
  package.json changes.
author: Claude Code
version: 1.0.0
date: 2026-03-23
---

# Node.js TypeScript ESM: Use .mts to Avoid MODULE_TYPELESS_PACKAGE_JSON Warning

## Problem
When running a `.ts` file with `node --experimental-strip-types`, Node.js emits:
```
[MODULE_TYPELESS_PACKAGE_JSON] Warning: Module type of file:///path/to/file.ts
is not specified and it doesn't parse as CommonJS. Reparsing as ES module because
module syntax was detected. This incurs a performance overhead.
To eliminate this warning, add "type": "module" to /path/to/package.json.
```

This happens because `.ts` doesn't carry an ESM signal. Node.js first tries to
parse as CommonJS, fails, then re-parses as ESM — wasting time and polluting stderr.

## Context / Trigger Conditions
- Using `node --experimental-strip-types` (Node.js v22.6.0+)
- TypeScript file uses ESM syntax (`import`/`export`)
- No `"type": "module"` in the nearest `package.json`
- Common in standalone scripts, CLI tools, or chezmoi-managed dotfiles where
  modifying `package.json` is undesirable

## Solution
Rename `.ts` → `.mts`. The `.mts` extension is the TypeScript equivalent of `.mjs`
and explicitly signals ESM to Node.js, just as `.mjs` does for JavaScript.

```bash
# Before: warning
node --experimental-strip-types script.ts

# After: no warning
node --experimental-strip-types script.mts
```

No code changes needed — only the file extension matters.

### When to use each extension

| Extension | Module system | Use when |
|-----------|--------------|----------|
| `.ts`     | Ambiguous (needs package.json) | Project has `"type": "module"` in package.json |
| `.mts`    | Always ESM | Standalone scripts, no package.json control |
| `.cts`    | Always CJS | CommonJS-only contexts |

## Verification
Run the script and confirm no `MODULE_TYPELESS_PACKAGE_JSON` warning on stderr:

```bash
node --experimental-strip-types script.mts 2>&1 | grep -c MODULE_TYPELESS
# Expected: 0
```

## Example
Converting a chezmoi-managed hook script:

```
# chezmoi source → target mapping
executable_notify.ts  → ~/.claude/scripts/notify.ts   # triggers warning
executable_notify.mts → ~/.claude/scripts/notify.mts  # clean execution
```

## Notes
- `.mts` is supported by `--experimental-strip-types` since the same Node.js
  versions that support `.ts` (v22.6.0+)
- TypeScript itself treats `.mts` as ESM in `tsc` compilation as well
- If running via a wrapper that copies to `/tmp`, preserve the `.mts` extension
  in the cached copy — Node.js uses the extension, not file content, to determine
  module type
- See also: `cco-seatbelt-nodejs-fix` for Seatbelt sandbox issues with
  `--experimental-strip-types`
