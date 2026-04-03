---
title: "feat: Japanese language support in transcript analysis"
type: feat
status: active
date: 2026-03-28
origin: docs/plans/2026-03-28-002-feat-autonomous-harness-engineering-plan.md
---

# feat: Japanese language support in transcript analysis

## Overview

harness-feedback-collector.sh のトランスクリプト解析パターンに日本語キーワードを追加し、日本語でのやり取りからもエラーパターンと問題解決活動を検出できるようにする。

## Problem Frame

現在のgrepパターンは英語キーワードのみ（"error", "failed", "root cause", "the fix" 等）。ユーザーの `settings.json` で `"language": "japanese"` が設定されており、Claude Codeの応答は日本語で行われる。日本語の「エラー」「失敗」「原因」「修正」等のキーワードがトランスクリプトに含まれるが、検出されない。

## Requirements Trace

- R1. Pattern 1（エラー検出）に日本語キーワードを追加
- R2. Pattern 4（問題解決検出）に日本語キーワードを追加
- R3. 既存の英語パターンを壊さない
- R4. grep -i（大文字小文字無視）と互換性を保つ

## Scope Boundaries

- Pattern 2（ファイル書き換え）とPattern 3（Bash失敗）は言語非依存（JSON構造ベース）なので変更不要

## Implementation Units

- [x] **Unit 1: grepパターンへの日本語キーワード追加**

**Files:**
- Modify: `dot_claude/scripts/executable_harness-feedback-collector.sh`

**Approach:**
- Pattern 1: `エラー|失敗|拒否|権限` を追加
- Pattern 4: `原因|回避策|修正|問題は|判明|分かった|解決` を追加
- `grep -c` と `\|` 区切りに日本語を追加するだけで、UTF-8環境では動作する
