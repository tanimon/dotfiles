# dotfiles

macOS の開発環境を chezmoi で管理する dotfiles。

## 管理対象

- Shell (zsh, starship, sheldon, zoxide, fzf)
- Editor (vim, helix)
- Terminal (ghostty, tmux)
- Git (gitconfig, gitignore)
- Claude Code (CLAUDE.md, agents, rules, plugins)
- macOS (Brewfile, defaults)
- Dev tools (mise, gh, yazi, zellij)

## Prerequisites

- macOS
- [Homebrew](https://brew.sh)

## Setup

```sh
# Homebrew をインストール（未導入の場合）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# chezmoi で dotfiles を適用
brew install chezmoi
chezmoi init --apply tanimon
```

初回実行時に `profile` (work/personal) と `ghOrg` の入力を求められる。

## License

MIT
