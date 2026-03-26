#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname)" != "Darwin" ]; then
    echo "Not macOS!"
    exit 1
fi

# タップでクリックを有効化
defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true

# Show bluetooth in the menu bar
defaults write com.apple.controlcenter "NSStatusItem Visible Bluetooth" -bool true

# Automatically hide or show the Dock
defaults write com.apple.dock autohide -bool true

# Dock 拡大: 大
defaults write com.apple.dock largesize -float 128
defaults write com.apple.dock magnification -bool true

# Dock サイズ: 小
defaults write com.apple.dock tilesize -int 16

# Avoid creating `.DS_Store` files on network volumes
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true

# Show hidden files in Finder
defaults write com.apple.finder AppleShowAllFiles -bool true

# Show path bar in Finder
defaults write com.apple.finder ShowPathbar -bool true

# Show status bar in Finder
defaults write com.apple.finder ShowStatusBar -bool true

# Show Tab bar in Finder
defaults write com.apple.finder ShowTabView -bool true

# Display battery level in the menu bar (macOS 12+ controlcenter)
defaults -currentHost write com.apple.controlcenter BatteryShowPercentage -bool true

# Increase mouse speed
defaults write -g com.apple.mouse.scaling 1.5

# Spotlight検索のショートカットを無効化 (要ログアウト)
defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add 64 "{ enabled = 0; value = { parameters = (32, 49, 1048576); type = standard; }; }"

# Increase trackpad speed
defaults write -g com.apple.trackpad.scaling 3

# キーのリピート速度を上げる
defaults write -g KeyRepeat -int 2

# キーリピート入力認識までの時間を短くする
defaults write -g InitialKeyRepeat -int 15

# カーソルを2.0倍のサイズに設定 (要ログアウト)
defaults write com.apple.universalaccess mouseDriverCursorSize -float 2.0

# Show files with all extensions
defaults write -g AppleShowAllExtensions -bool true

for app in "Dock" \
    "Finder" \
    "ControlCenter"; do
    killall "${app}" &>/dev/null || true
done
