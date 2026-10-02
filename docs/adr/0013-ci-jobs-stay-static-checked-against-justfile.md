---
status: accepted
date: 2026-10-02
---

# lint.yml の job は動的 matrix にせず static なまま残し、justfile の `lint:` との一致を検査する

検証 suite の正本は justfile の `lint:` の依存列とし、CI で回せないレシピには `[group('local-only')]` の印を付ける。lint.yml の job はレシピごとに static に書き、ツールの導入は composite action `.github/actions/setup-lint` に集約する。写しが正本からずれないことは `test/ci-parity.bats`(`just test-ci-parity`)が双方向に検査する。suite の追加で lint.yml を触らずに済む動的 matrix(前段 job が `just --dump` から一覧を作り、1 つの job 定義を `fromJSON` で回す)は採らなかった。suite ごとに要るツール(pnpm・chezmoi・shfmt など)が違うため、matrix にすると「どの suite が何を要るか」を justfile 側に新しく宣言させる必要があり、それが justfile と CI の間の新しい interface になる。全 job に全ツールを入れればその宣言は要らないが、すべての job が遅くなる。

## Considered Options

- **動的 matrix** — 却下。上記のとおり。
- **1 job で `just lint` を回す** — 却下。並列実行と、どの suite が落ちたかの一覧性を失う。
- **lint.yml を正本にし、justfile の `lint:` をそこから導く** — 却下。CI を持たないローカル実行が YAML に依存する。

## Consequences

- suite を足すときは、justfile のレシピと `lint:`、lint.yml の job の 2 箇所を触る。片方を忘れると `test-ci-parity` が落ちる。
- lint.yml の `run` は `just <recipe>` の 1 行か、`just` という語を含まない行に限る。それ以外の形は検査が読み切れないので fail になる。
- 検査は mikefarah 版の yq v4 を要求する(CI は runner に入っているもの、ローカルは `darwin/Brewfile`)。
- ローカル action を全 job が参照するため、zizmor の self-repository 監査は `.github/zizmor.yml` で 1 箇所で無効にしている(`$/...` 構文を actionlint が拒否するため。rhysd/actionlint#711)。
- pre-commit の hook は、今も justfile とは独立した entry と `files:` のトリガを持っている。この決定の範囲外。
