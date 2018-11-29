ZPLUG_HOME=${HOME}/.zplug

source $ZPLUG_HOME/init.zsh

zplug 'zplug/zplug', hook-build:'zplug --self-manage'
zplug "b4b4r07/enhancd", use:init.sh
zplug "mafredri/zsh-async", from:github
zplug "sindresorhus/pure", use:pure.zsh, from:github, as:theme
zplug "motemen/ghq", \
    as:command, \
    from:gh-r, \
    rename-to:ghq

# Run a command after a plugin is installed/updated
# Provided, it requires to set the variable like the following:
# ZPLUG_SUDO_PASSWORD="********"
zplug "jhawthorn/fzy", \
    as:command, \
    rename-to:fzy, \
    hook-build:"make && sudo make install"

# Install plugins if there are plugins that have not been installed
if ! zplug check --verbose; then
    printf "Install? [y/N]: "
    if read -q; then
        echo; zplug install
    fi
fi

# Then, source plugins and add commands to $PATH
zplug load --verbose

autoload -U compinit; compinit
autoload -U promptinit; promptinit
prompt pure

# Disable beep when listing candidates for completion
setopt nolistbeep

# Aliases
alias ls='ls -FG'
alias ll='ls -l'
alias la='ls -la'

export GOPATH=$HOME
export PATH=$PATH:$GOPATH/bin

