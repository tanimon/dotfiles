---
status: accepted
date: 2026-10-31
---

# lint ツールの版の正本をリポジトリの `mise.toml` にし、ローカルと CI の両方がそこから読む

lint が使うツール(shellcheck・shfmt・actionlint・zizmor・just・yq)の版を、リポジトリ直下の `mise.toml` にだけ書く。CI は `.github/actions/setup-lint` が `jdx/mise-action` で `mise.toml` から job ごとに要るツールだけを入れ、ローカルは mise がリポジトリの中でその版に切り替える。CI の版を `setup-lint` に手で書き、ローカルは Homebrew の版が上がり続ける 2 系統のままだと、同じファイルがローカルでは通り CI で落ちる(#448。shellcheck はローカル 0.11.0・CI は runner 同梱の 0.9.0 で、SC2015 の判定が違った)。`setup-lint` の版は Renovate の対象外で、手で上げない限り古いまま残る。正本を 1 つにして Renovate の標準の mise manager に上げさせれば、ずれる経路そのものが無くなる。

[ADR 0013](0013-ci-jobs-stay-static-checked-against-justfile.md) の「ツールの導入は `setup-lint` に集約する」はそのまま残る。変わるのは lint ツールの版を書く場所で、`setup-lint` から `mise.toml` に移る。

## Considered Options

- **CI の版だけを `setup-lint` で固定し、ローカルとの差は残す**(#448 の案 2) — 却下。runner イメージの更新で CI の結果が変わることは防げるが、ローカルで通って CI で落ちる事故は防げない。shfmt はこの形のまま、ローカル 3.14.1・CI 3.11.0 でずれていた。
- **何もせず、ローカルとの差を既知の事項として文書に書く**(#448 の案 3) — 却下。BSD/GNU の差と違い、版の差は固定して消せる。
- **`setup-lint` を正本のまま、ローカルの版が違えば警告する recipe を足す** — 却下。ずれに気づけるだけで、揃える作業は毎回人に残る。
- **`setup-lint` が自分で `mise.toml` を読み、今の curl で入れる** — 却下。外部の action は増えないが、TOML の解析とダウンロードを自前で持つ。mise(aqua)はチェックサムも検証する。
- **ローカルの lint ツールを `darwin/Brewfile` に残す** — 却下。リポジトリの外では mise の shim が Homebrew 版に処理を譲るので動きはするが、同じツールに Homebrew と mise の 2 つの導入元ができる。グローバルの mise 設定(`dot_config/mise/config.toml`)に `"latest"` で載せ、導入元を mise にそろえる。グローバル側を固定しないのは、Renovate が同じツールを 2 箇所で別々に上げることになるため。

## Consequences

- `mise.toml` は `.chezmoiignore` に入れる。入れないと `~/mise.toml` に配置され、ホーム全体の版を固定する。
- `mise.toml` は tools だけを持つので、`mise trust` は要らない(mise 2026.10.17 で、untrusted のままリポジトリの中の版が有効になることを確かめた)。env・hook・task を足すと mise は信頼を求めてエラーで止まるので、黙って別の版に落ちはしない。リポジトリの中で `mise install` を実行すると、副作用としてそのディレクトリを信頼済みにする。
- Renovate が版を上げた後、未導入の版の shim は自動で導入を試み、できなければ失敗する。Homebrew 版に黙って落ちはしない(導入を止めた状態で実測した)。
- shellcheck と yq は runner にも入っているので、`setup-lint` は just と同じく常に入れる。input にすると、要求し忘れた job が runner の版で黙って走る。actionlint は workflow の `run:` を PATH 上の shellcheck にかけるので、actionlint の job もこれで固定した版を使う。`setup-lint` は導入の後、入れた各ツールが `mise.toml` の版の shim に解決されることを確かめ、そうでなければ落ちる(`mise.toml` に無い名前を `mise install` すると最新版が黙って入るため)。
- mise 本体の版は `setup-lint` の `jdx/mise-action` の入力に書く。Renovate の github-actions manager はこの入力を読まないので、`renovate.json` の regex の customManager で上げる。
- `security-alerts.yml` の sweep job も just を curl で直接入れるのをやめ、`setup-lint` を使う。
- `darwin/Brewfile` から行を消しても、既存のマシンに入っている Homebrew 版は消えない。グローバルの mise に入れてから、手で `brew uninstall` する。
- ツールが無いときに黙って skip する箇所(pre-commit の hook、`just shellcheck`)は残る。mise の shims が PATH に無い文脈では skip する。この決定の範囲外(#608)。
