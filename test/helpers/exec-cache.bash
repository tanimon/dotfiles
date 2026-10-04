# test が作る実行ファイル(stub・fixture adapter)を、内容が同じなら 1 つの inode に寄せる、bats suite 用の helper。
#
# Endpoint Security 製品が入った macOS では、新しく作られたファイルの初回 exec に 1 ファイルあたり 1〜2 秒の
# 待ちが入る(shebang やサンドボックスの有無によらない)。test ごとに stub を書き直すと、その待ちが
# test 数 × stub 数だけ積もる。待ちは inode ごとに 1 回なので、同じ inode を hardlink で指せば 2 回目以降の exec は待たない。
# 待ちの無い環境では、helper は単に stub を置くだけになる。
# APFS の clone(cp -c)は別 inode なので効かない。
#
# symlink ではなく hardlink にするのは、sed -i で stub を書き換える test があるため。
# sed -i はリネームで置き換えるので hardlink なら cache 側に触れずにリンクだけが外れ、mode も保たれる。
#
# cache は 555 にしてあるので、install_exec を通さずに stub へ直接書き込むと(`cat >"$STUBS/x"`)
# cache を書き換えずに Permission denied で失敗する。上書きは install_exec か rm してから行う。
#
# 1 つの test でしか exec しない stub は、cache を通しても待ちが 1 回で変わらないので直接書いてよい。
# install_exec が置いたことの無いパスなら、直接書いても cache には触れない。

# install_exec DEST: stdin の内容を実行ファイルとして DEST に置く
install_exec() {
    local dest=$1 cache="$BATS_RUN_TMPDIR/exec-cache" tmp key
    mkdir -p "$cache"
    tmp=$(mktemp "$cache/.tmp.XXXXXX")
    cat >"$tmp"
    key=$(shasum -a 256 "$tmp" | cut -d' ' -f1)
    if [ -e "$cache/$key" ]; then
        rm -f "$tmp"
    else
        chmod 555 "$tmp"
        mv -f "$tmp" "$cache/$key"
    fi
    rm -f "$dest"
    ln "$cache/$key" "$dest"
}
