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

# Brewfile のパッケージを入れる
brew bundle install --file="$(chezmoi source-path)/darwin/Brewfile"

# brew で入った道具(mise・nono・apm・gh・sheldon など)を使う after スクリプトを走らせる
chezmoi apply
```

初回実行時に `profile` (work/personal) と `ghOrg` の入力を求められる。

`chezmoi apply` は brew を呼ばない。apply の中で `brew bundle` を走らせると既定で入れ済みのパッケージまで upgrade され、その失敗で apply が途中で止まるため。Brewfile を変えた後は、dotfiles のリポジトリで `just brew-install` を実行する(未導入のパッケージだけを入れ、upgrade はしない)。upgrade は必要なときに `brew upgrade` で行う。

## License

MIT
