## Verification

```sh
just lint                      # Run ALL checks locally (mirrors CI)
chezmoi apply --dry-run        # Preview changes before applying
```

`just --list` enumerates the individual recipes with their descriptions — do not maintain a copy of that list here, it drifts. Every recipe `lint` depends on is also a CI job except `test-nono-profile` (CI does not install nono), so local is a superset: green locally means green in CI, not the other way round.

Note: shellcheck, shfmt, oxlint, and oxfmt cannot lint `.tmpl` files (Go template syntax is incompatible). For similar past issues, search `docs/solutions/`.

検証コマンドは手で組まない。`shellcheck -x <files>` や `shfmt -i 4 -d <files>` を並べず `just lint` か個別レシピを呼ぶ — 手組みは対象の漏れや `-i 4` の落としで CI と静かにずれる。ブランチ / PR の状態も同じ理由で `bash scripts/pr-context.sh` を使う。
