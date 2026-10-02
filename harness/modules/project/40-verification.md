## Verification

```sh
just lint                      # Run ALL checks locally (mirrors CI)
chezmoi apply --dry-run        # Preview changes before applying
```

`just --list` enumerates the individual recipes with their descriptions — do not maintain a copy of that list here, it drifts. Every recipe `lint` depends on is also run by CI except those in the `local-only` group (`just --list` shows them under `[local-only]`), so local is a superset of CI's recipe set. A recipe goes in that group only when CI cannot run it (nono is not installed there; a darwin-only template renders empty on ubuntu). `just test-ci-parity` fails when `lint.yml` and `lint:` disagree in either direction, so a new suite must be added to both — job steps get their tools from `.github/actions/setup-lint`, which is the only place versions and action pins are written (ADR 0013). Green locally still does not guarantee green in CI: CI runs on ubuntu (GNU coreutils), and BSD/GNU differences in `stat` / `sed` / `grep` have turned CI red while local was green (PR #328). After pushing, check the PR's CI before reporting done.

Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). For similar past issues, search `docs/solutions/`.

検証コマンドは手で組まない。`shellcheck -x <files>` や `shfmt -i 4 -d <files>` を並べず `just lint` か個別レシピを呼ぶ — 手組みは対象の漏れや `-i 4` の落としで CI と静かにずれる。ブランチ / PR の状態も同じ理由で `bash scripts/pr-context.sh` を使う。
