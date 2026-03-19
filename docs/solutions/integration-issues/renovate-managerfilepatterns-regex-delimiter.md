---
title: "Renovate managerFilePatterns requires / delimiters for regex patterns"
problem_type: integration-issues
severity: medium
modules: [renovate, chezmoi]
symptoms:
  - "Renovate Dependency Dashboard shows no regex manager dependencies"
  - "customManagers regex patterns silently fail to match files"
  - "fileMatch patterns stop working after migration to managerFilePatterns"
tags:
  - renovate
  - chezmoiexternal
  - managerFilePatterns
  - fileMatch
  - regex
  - glob
  - minimatch
date: 2026-03-19
---

# Renovate managerFilePatterns requires / delimiters for regex patterns

`managerFilePatterns` (renamed from `fileMatch`) silently treats undelimited patterns as minimatch globs instead of regex, causing custom regex managers to match zero files.

## Problem

Renovate の Dependency Dashboard に `.chezmoiexternal.toml` の git-refs 依存関係が表示されなかった。`mise` と `npm` の依存関係のみ検出され、`customManagers` で定義した regex マネージャーが機能していなかった。

## Investigation

### 1. 正規表現パターン自体は正しかった

`matchStrings` の正規表現を node-re2（Renovate が使用する RE2 バインディング）でテストしたところ、`.chezmoiexternal.toml` の内容から 2 件の依存関係が正しく抽出された。

### 2. `managerFilePatterns` のパターン解釈が問題だった

Renovate のドキュメント ([String Pattern Matching](https://docs.renovatebot.com/string-pattern-matching/)) によると:

> If the string provided is not a regex pattern then it will be treated as a glob pattern and parsed using the minimatch library.

「regex pattern」として認識されるには、**パターンを `/` デリミタで囲む必要がある**。

| パターン形式 | 解釈 |
|---|---|
| `/\.foo$/` (デリミタあり) | **正規表現** (RE2) |
| `\.foo$` (デリミタなし) | **minimatch glob** |

### 3. glob としての解釈が破壊的だった

`"\\.chezmoiexternal\\.toml$"` が glob として解釈されると:
- `\` は minimatch のエスケープ文字として消費される
- `$` はリテラル文字として扱われる
- さらに minimatch はデフォルトでドットファイル（`.` で始まるファイル）にマッチしない

結果としてファイルに一切マッチせず、regex マネージャーが無効化された。

### 4. 旧 `fileMatch` との動作差異

旧フィールド名 `fileMatch` は正規表現のみをサポートしていた。`managerFilePatterns` への改名時に glob サポートが追加され、デリミタなしパターンの解釈が変わった。既存の `fileMatch` 設定は自動マイグレーションされるが、パターン解釈の変更は適用されない。

## Root Cause

`managerFilePatterns` のパターン `"\\.chezmoiexternal\\.toml$"` に `/` デリミタがなく、Renovate が minimatch glob として解釈していた。

## Solution

パターンを `/` デリミタで囲んで正規表現として明示する:

```diff
- "managerFilePatterns": ["\\.chezmoiexternal\\.toml$"],
+ "managerFilePatterns": ["/\\.chezmoiexternal\\.toml$/"],
```

### 検証方法

node-re2 による直接テスト:

```javascript
import RE2 from "re2";
const content = fs.readFileSync(".chezmoiexternal.toml", "utf8");
const pattern = String.raw`url\s*=\s*"https://github\.com/(?<depName>[^"]+?)(?:\.git)?"\s+#\s*renovate:\s*branch=(?<currentValue>\S+)\s+ref\s*=\s*"(?<currentDigest>[a-f0-9]{40})"`;
const re = new RE2(pattern, "gs");
// → 2 matches: blader/Claudeception, nikvdp/cco
```

## Prevention

- `managerFilePatterns` で正規表現を使う場合は、必ず `/pattern/` 形式にする
- Renovate ドキュメントの `customManagers` コード例を参照する際、パターンが `/` で囲まれているか確認する
- `fileMatch` から `managerFilePatterns` に移行する場合、パターン解釈の変更に注意する
- Renovate Dependency Dashboard でカスタムマネージャーの依存関係が表示されることを検証する

## Related

- [Managing script-only GitHub repos with Renovate SHA pinning](chezmoi-external-script-repo-with-renovate-sha-pinning.md) — 同じ regex custom manager の初期設定ドキュメント（コード例を本修正に合わせて更新済み）
- PR #26: https://github.com/tanimon/dotfiles/pull/26
- Renovate String Pattern Matching: https://docs.renovatebot.com/string-pattern-matching/
