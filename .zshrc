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

# Enable Terraform's completions
autoload -U +X bashcompinit && bashcompinit
complete -o nospace -C /usr/local/bin/terraform terraform

#zstyle ':completion:*' auto-description 'specify: %d'
#zstyle ':completion:*' completer _expand _complete _correct _approximate
#zstyle ':completion:*' format 'Completing %d'
#zstyle ':completion:*' group-name ''
#zstyle ':completion:*' menu select=2
#eval "$(dircolors -b)"
#zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
#zstyle ':completion:*' list-colors ''
#zstyle ':completion:*' list-prompt %SAt %p: Hit TAB for more, or the character to insert%s
#zstyle ':completion:*' matcher-list '' 'm:{a-z}={A-Z}' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=* l:|=*'
#zstyle ':completion:*' menu select=long
#zstyle ':completion:*' select-prompt %SScrolling active: current selection at %p%s
#zstyle ':completion:*' use-compctl false
#zstyle ':completion:*' verbose true
#
#zstyle ':completion:*:*:kill:*:processes' list-colors '=(#b) #([0-9]#)*=0=01;31'
#zstyle ':completion:*:kill:*' command 'ps -u $USER -o pid,%cpu,tty,cputime,cmd'


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

[[ -f ~/.fzf.zsh ]] && source ~/.fzf.zsh

export PATH=$PATH:$HOME/.local/bin

export VOLTA_HOME="$HOME/.volta"
export PATH="$VOLTA_HOME/bin:$PATH"

eval "$(/opt/homebrew/bin/mise activate zsh)"

eval "$(starship init zsh)"
