source $ZPLUG_HOME/init.zsh

zplug 'zplug/zplug', hook-build:'zplug --self-manage'
zplug "b4b4r07/enhancd", use:init.sh

# インストール・アップデート後に実行されるフック
# この場合は以下のような設定が別途必要
# ZPLUG_SUDO_PASSWORD="********"
zplug "jhawthorn/fzy", \
    as:command, \
    rename-to:fzy, \
    hook-build:"make && sudo make install"

