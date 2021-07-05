"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Plugins
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Auto-install vim-plug
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

" Plugins will be downloaded under the specified directory.
call plug#begin(expand('~/.vim/plugged'))

Plug 'arcticicestudio/nord-vim'
Plug 'itchyny/lightline.vim'

Plug 'tpope/vim-fugitive'
Plug 'airblade/vim-gitgutter'

Plug 'tpope/vim-surround'
Plug 'tpope/vim-repeat'

Plug 'vimwiki/vimwiki'
Plug 'tbabej/taskwiki'

" LSP
Plug 'prabirshrestha/vim-lsp'
Plug 'mattn/vim-lsp-settings'

" Completion
Plug 'prabirshrestha/asyncomplete.vim'
Plug 'prabirshrestha/asyncomplete-lsp.vim'

Plug 'liuchengxu/vim-which-key'

Plug 'tpope/vim-vinegar'

Plug 'easymotion/vim-easymotion'

Plug 'skanehira/translate.vim'

" Japanese vim doc
Plug 'vim-jp/vimdoc-ja'

" List ends here. Plugins become visible to Vim after this call.
call plug#end()

" Automatically install missing plugins on startup
autocmd VimEnter *
  \  if len(filter(values(g:plugs), '!isdirectory(v:val.dir)'))
  \|   PlugInstall --sync | q
  \| endif


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" General
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Turn off vi compatibility
set nocompatible

" Set to auto read when a file is changed from the outside
set autoread

" With a map leader it's possible to do extra key combinations
" like <leader>w saves the current file
let mapleader = "\<Space>"

" Enable the use of the mouse in normal, visual, insert,
" command line and help modes
set mouse=a

" Show command-line completion candidates
set wildmenu

" Smartcase
set ignorecase
set smartcase

" By default timeoutlen is 1000 ms
set timeoutlen=400

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Appearance
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Use true colors in the terminal
set termguicolors

" Turn on hyblid line number
set number relativenumber

" Find the current line quickly
set cursorline

" Show ruler
set ruler

" Always show the status line
set laststatus=2

" Always show the tab line
set showtabline=2

" Don't show mode info
set noshowmode

" Enables syntax highlighting
syntax on

" Specify color scheme
colorscheme nord

" Configure status line appearance with lightline.vim
let g:lightline = {
      \ 'colorscheme': 'nord',
      \ 'active': {
      \   'left': [ [ 'mode', 'paste' ],
      \             [ 'gitbranch', 'readonly', 'filename', 'modified' ] ]
      \ },
      \ 'component_function': {
      \   'gitbranch': 'FugitiveHead'
      \ },
      \ }


"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Editing mappings
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
" Make <C-a> and <C-x> target only numbers, and deal with them as decimal
set nrformats=

" Indent with 4 spaces
set tabstop=4
set shiftwidth=4
set expandtab

" Show which-key with <leader>
nnoremap <silent> <leader> :WhichKey '<Space>'<CR>


""""
" Editing text and indent
""""
" Show matching parentheses
set showmatch

set shiftround
set smarttab
set autoindent

