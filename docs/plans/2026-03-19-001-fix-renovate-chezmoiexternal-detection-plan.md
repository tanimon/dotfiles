# Fix: Renovate が .chezmoiexternal.toml の依存関係を認識しない

## 問題

Renovate の Dependency Dashboard (issue #15) に `.chezmoiexternal.toml` の依存関係が表示されない。`mise` と `npm` の依存関係のみ検出されている。

## 根本原因

`renovate.json` の `customManagers` で `managerFilePatterns` フィールドを使用しているが、パターンが正規表現デリミタ `/` で囲まれていない。

Renovate は `managerFilePatterns`（旧 `fileMatch`）において:
- `/` で囲まれたパターン → **正規表現**として解釈
- それ以外 → **minimatch glob** として解釈

現在の設定 `"\\.chezmoiexternal\\.toml$"` は glob として解釈され、`\` や `$` がリテラル文字として扱われるためマッチしない。

参考: https://docs.renovatebot.com/string-pattern-matching/

## 修正

`renovate.json` の `managerFilePatterns` を正しい glob パターンに変更:

```diff
- "managerFilePatterns": ["\\.chezmoiexternal\\.toml$"],
+ "managerFilePatterns": ["/\\.chezmoiexternal\\.toml$/"],
```

`/` デリミタで囲むことで Renovate が正規表現として解釈する。glob（minimatch）はデフォルトでドットファイルにマッチしないため、正規表現アプローチが確実。

## 検証

- Renovate の Dependency Dashboard (issue #15) で `regex` マネージャーの検出結果を確認
- `blader/Claudeception` と `nikvdp/cco` の 2 つの依存関係が表示されること
