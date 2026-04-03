---
title: "fix: Sync darwin/defaults.sh with current macOS system settings"
type: fix
status: completed
date: 2026-03-26
---

# fix: Sync darwin/defaults.sh with current macOS system settings

## Overview

現在の macOS 15.7.4 システム設定を確認し、`darwin/defaults.sh` に記述されている値との差分を解消する。

## Problem Frame

`darwin/defaults.sh` に記述されている `InitialKeyRepeat` の値（25）が、現在のシステム設定（15）と異なる。スクリプトを現在のシステム状態に合わせて更新する。

## Investigation Results

### Settings with values (global defaults `-g`):

| Setting | Current Value | Script Value | Status |
|---------|--------------|-------------|--------|
| `com.apple.mouse.scaling` | 1.5 | 1.5 | ✅ Match |
| `com.apple.trackpad.scaling` | 3 | 3 | ✅ Match |
| `KeyRepeat` | 2 | 2 | ✅ Match |
| `InitialKeyRepeat` | **15** | **25** | ❌ DIFF |
| `AppleShowAllExtensions` | 1 (true) | true | ✅ Match |

### Settings not set (domain/key does not exist):

`com.apple.dock` (autohide, largesize, magnification, tilesize), `com.apple.finder` (_FXShowPosixPathInTitle, AppleShowAllFiles, ShowPathbar, ShowStatusBar, ShowTabView), `com.apple.AppleMultitouchTrackpad Clicking`, `com.apple.controlcenter "NSStatusItem Visible Bluetooth"`, `com.apple.desktopservices DSDontWriteNetworkStores`, `com.apple.menuextra.battery ShowPercent`, `com.apple.menuextra.clock DateFormat`, `com.apple.symbolichotkeys` key 64, `com.apple.universalaccess mouseDriverCursorSize`

> Note: macOS 15 (Sequoia) では多くの設定がSystem Settings UIから管理され、`defaults` コマンドではplistに書き込まれない。`com.apple.dock` および `com.apple.finder` ドメイン自体がユーザーレベルで存在しない。これらの設定はスクリプトの「あるべき状態」を宣言するものとして維持する。

## Scope Boundaries

- `InitialKeyRepeat` の値のみ更新（25 → 15）
- NOT SET の設定は意図的に維持（宣言的な設定スクリプトとして）

## Implementation Units

- [ ] **Unit 1: Update InitialKeyRepeat value**

**Goal:** `InitialKeyRepeat` を現在のシステム値に合わせる

**Files:**
- Modify: `darwin/defaults.sh`

**Approach:**
- 行61の `InitialKeyRepeat` の値を 25 から 15 に変更

**Verification:**
- スクリプト内の値がシステム設定値（15）と一致すること
