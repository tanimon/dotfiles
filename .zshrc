eval "$(sheldon source)"

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt hist_ignore_all_dups
setopt hist_no_store
setopt hist_reduce_blanks
setopt inc_append_history
setopt share_history


# Completion
if type brew &>/dev/null; then
    # Enable Homebrew's completions
    FPATH=$(brew --prefix)/share/zsh/site-functions:$FPATH
fi

fpath+=~/.zfunc

autoload -Uz compinit; compinit

ZSH_AUTOSUGGEST_STRATEGY=(history completion)


# Disable beep when listing candidates for completion
setopt nolistbeep


# Enable zmv
autoload -Uz zmv
alias zmv='noglob zmv -W'


# Aliases
alias ls='ls -FG'
alias ll='ls -l'
alias la='ls -la'


# Environment variables
if [[ -f $HOME/.env ]]; then
    source ${HOME}/.env
fi

# Set up fzf key bindings and fuzzy completion
source <(fzf --zsh)

export PATH=$PATH:$HOME/.local/bin

eval "$(/opt/homebrew/bin/mise activate zsh)"

eval "$(starship init zsh)"

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end
