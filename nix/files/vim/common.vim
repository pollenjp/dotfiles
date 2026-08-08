set number
"set relativenumber
set cursorline
"set cursorcolumn
set colorcolumn=120
" https://qiita.com/mitsuru793/items/2d464f30bd091f5d0fef#vim%E3%81%AE%E3%82%A4%E3%83%B3%E3%83%87%E3%83%B3%E3%83%88%E3%82%AA%E3%83%97%E3%82%B7%E3%83%A7%E3%83%B3

"####################################################################################################
set expandtab         " tabキーを押すとスペースが入力される
set tabstop     =4    " 画面上で表示する1つのタブの幅
set softtabstop =4    " いくつの連続した空白を1回で削除できるようにするか
set shiftwidth  =4    " 自動インデントでのインデントの長さ
set autoindent        " 改行した時に自動でインデントします
"set smartindent       " {があると次の行は自動で1段深く自動インデントしてくれる
set nosmartindent
" [ファイルの拡張子によって、vimに自動でインデント幅を変えてもらおう！ - Qiita](https://qiita.com/mitsuru793/items/2d464f30bd091f5d0fef#vim%E3%81%AE%E3%82%A4%E3%83%B3%E3%83%87%E3%83%B3%E3%83%88%E3%82%AA%E3%83%97%E3%82%B7%E3%83%A7%E3%83%B3)

"############################################################
"  Horizantal Scroll
set nowrap
map <C-L> 20zl " Scroll 20 characters to the right
map <C-H> 20zh " Scroll 20 characters to the left
"############################################################
" - [【Vim】タブ、空白、改行を可視化する | blog.remora.cx](http://blog.remora.cx/2011/08/display-invisible-characters-on-vim.html)
"   - listで表示される文字のフォーマットを指定する
"   - tab:»-
"     -“タブ”の表示を決定する。値は 2 文字で指定し、タブがスペース 8 文字に当たる場合、“»-------”などと表示される。
"   - trail:-
"     - 行末に続くスペースを表す表示。
"   - eol:↲
"     - 改行記号を表す表示。
"   - extends:»
"     - ウィンドウの幅が狭くて右に省略された文字がある場合に表示される。
"   - precedes:«
"     - extends と同じで左に省略された文字がある場合に表示される。
"   - nbsp:%
"     - 不可視のスペースを表す表示。ただし、この記号の通りに表示されるのは“&nbsp;”、
"     つまり、ノーブレークスペースに限られており、ほかの不可視スペース
"     (画像に挙げた &#x200b;、&#xfeff;、などなど)には効果がない。
set list
set listchars=tab:»-,trail:-,eol:↲,extends:»,precedes:«,nbsp:%
"########################################
" - 改行文字とタブ文字の色設定（NonTextが改行、SpecialKeyがタブ）
"   - [vim set color for listchars tabs and spaces - Stack Overflow](https://stackoverflow.com/questions/24232354/vim-set-color-for-listchars-tabs-and-spaces)
"     - `NonText`
"       - eol, extends, precedes
"     - `SpecialKey`
"       - nbsp, tab, trail
"   - [Xterm256 color names for console Vim - Vim Tips Wiki - FANDOM powered by Wikia](http://vim.wikia.com/wiki/Xterm256_color_names_for_console_Vim)
"      - `ctermfg`で使える番号一覧が見れます。
"   - [可視化させたＴＡＢ文字の色を指定 - MinamoBlog　～ゲームと日常にトキメキを～](http://d.hatena.ne.jp/Minamo/20081124/1227553857)
hi NonText    ctermfg=59
hi SpecialKey ctermfg=59
"hi NonText    ctermbg=None ctermfg=235 guibg=NONE guifg=None
"hi SpecialKey ctermbg=None ctermfg=235 guibg=NONE guifg=None


"############################################################
set hlsearch
nnoremap <F3> :noh<CR>  " ハイライトを消す
"############################################################
set clipboard+=unnamedplus  "こいつを追加したらビジュアルモードでの選択からのヤンクが上手く行かなくなった
set tags=tags;  "親ディレクトリを再帰的にサーチ
set display=lastline
set showmatch
set matchtime=1
"set pumheight=10
"https://qiita.com/hachi8833/items/7beeee825c11f7437f54
"############################################################
set wildmenu " コマンドモードの補完
set history=5000 " 保存するコマンド履歴の数
"############################################################
" Automatically append closing characters
" https://qiita.com/shingargle/items/dd1b5510a0685837504a
"inoremap { {}<Left>
inoremap {<Enter> {}<Left><CR><ESC><S-o>
"inoremap ( ()<ESC>i
inoremap (<Enter> ()<Left><CR><ESC><S-o>
"########################################
"variable highlight
" autocmd CursorMoved * exe printf('match IncSearch /\V\<%s\>/', escape(expand('<cword>'), '/\'))

"####################################################################################################
"  - Screen Dynamic Title
"    - [Automatically set screen title | Vim Tips Wiki | FANDOM powered by Wikia](http://vim.wikia.com/wiki/Automatically_set_screen_title)
auto BufEnter * let &titlestring = hostname() . "/" . expand("%:p")


"--------------------------------------------------------------------------------
"--------------------------------------------------------------------------------
"===============================================================================
" [Vimの便利な画面分割＆タブページと、それを更に便利にする方法 - Qiita](https://qiita.com/tekkoc/items/98adcadfa4bdc8b5a6ca)
"  - Split / Vertically Split
nnoremap s <Nop>
"=======================================
" 分割したウィンドウ間を移動する
" 画面分割で ↓ / ↑ / → / ← に移動
nnoremap sj <C-w>j
nnoremap sk <C-w>k
nnoremap sl <C-w>l
nnoremap sh <C-w>h
"=======================================
" 分割したウィンドウそのものを移動する
" toggle vertical/horizontal split
nnoremap sJ <C-w>J
nnoremap sK <C-w>K
nnoremap sL <C-w>L
nnoremap sH <C-w>H
"=======================================
" カレントウィンドウの大きさを変える
"=======================================
" タブページ関連
" - 新規タブ
" - 次のタブに切替
" - 前のタブに切替
" - ウィンドウを閉じる
" - バッファを閉じる
nnoremap st :<C-u>tabnew<CR>
nnoremap sn gt
nnoremap sp gT
nnoremap sq :<C-u>q<CR>
nnoremap sQ :<C-u>bd<CR>
"=======================================
nnoremap sr <C-w>r
nnoremap s= <C-w>=
nnoremap sw <C-w>w
nnoremap so <C-w>_<C-w>|
nnoremap sO <C-w>=
nnoremap sN :<C-u>bn<CR>
nnoremap sP :<C-u>bp<CR>
nnoremap sT :<C-u>Unite tab<CR>
nnoremap ss :<C-u>sp<CR>
nnoremap sv :<C-u>vs<CR>
nnoremap sb :<C-u>Unite buffer_tab -buffer-name=file<CR>
nnoremap sB :<C-u>Unite buffer -buffer-name=file<CR>

"===============================================================================
" [Vim Is The Perfect IDE](https://coderoncode.com/tools/2017/04/16/vim-the-perfect-ide.html)
" [vim-plugin NERDTree で開発効率をアップする！ - Qiita](https://qiita.com/zwirky/items/0209579a635b4f9c95ee)
map <C-n> :NERDTreeToggle<CR>
map <C-m> :TagbarToggle<CR>


"===============================================================================
" カンマコマンドモード
" https://qiita.com/rita_cano_bika/items/2ae9c8304f8f12b1b443
" 「,」を打ってから各キーを打つと各コマンドを実行
let mapleader=","
" 「,r」：.vimrcのリロード
noremap <Leader>r :source ~/.vimrc<CR>:noh<CR>
" 「,n」：行番号表示／非表示
noremap <Leader>n :<C-u>:setlocal number!<CR>
" 「,c」：カーソルラインの表示／非表示
noremap <Leader>c :<C-u>:setlocal cursorline!<CR>
" 「,C」：カーソルカラムの表示／非表示
noremap <Leader>C :<C-u>:setlocal cursorcolumn!<CR>

"===============================================================================
"" インサートモードに入った時にカーソル行(列)の色を変更する
"augroup vimrc_change_cursorline_color
"  autocmd!
"  " インサートモードに入った時にカーソル行の色をブルーグリーンにする
"  autocmd InsertEnter * highlight CursorLine ctermbg=24 guibg=#005f87 | highlight CursorColumn ctermbg=24 guibg=#005f87
"  " インサートモードを抜けた時にカーソル行の色を黒に近いダークグレーにする
"  autocmd InsertLeave * highlight CursorLine ctermbg=236 guibg=#ffffff | highlight CursorColumn ctermbg=236 guibg=#ffffff
"augroup END


"===============================================================================
"  - 自動コメント記号の挿入をreject
augroup auto_comment_off
    "https://cloudpack.media/10353
    autocmd!
    autocmd BufEnter * setlocal formatoptions-=r
    autocmd BufEnter * setlocal formatoptions-=o
augroup END

"===============================================================================
"参考: http://qiita.com/ymiyamae/items/06d0f5ce9c55e7369e1f
if has("autocmd")
  "ファイルタイプの検索を有効にする
  filetype plugin on
  "ファイルタイプに合わせたインデントを利用
  filetype indent on
  "sw=softtabstop, sts=shiftwidth, ts=tabstop, et=expandtabの略
  augroup indenttypeset
    autocmd FileType zsh          setlocal sw=4 sts=4 ts=4 et
    autocmd FileType python       setlocal sw=4 sts=4 ts=4 et
    autocmd FileType conf         setlocal sw=4 sts=4 ts=4 et
    autocmd FileType php          setlocal sw=4 sts=4 ts=4 et
    autocmd FileType scala        setlocal sw=4 sts=4 ts=4 et
    autocmd FileType json         setlocal sw=4 sts=4 ts=4 et
    autocmd FileType html         setlocal sw=4 sts=4 ts=4 et
    autocmd FileType scss         setlocal sw=4 sts=4 ts=4 et
    autocmd FileType sass         setlocal sw=4 sts=4 ts=4 et
    autocmd FileType java         setlocal sw=4 sts=4 ts=4 et

    autocmd FileType html         setlocal sw=2 sts=2 ts=2 et
    "autocmd FileType c            setlocal sw=2 sts=2 ts=2 et
    "autocmd FileType cpp          setlocal sw=2 sts=2 ts=2 noexpandtab
    autocmd FileType markdown     setlocal sw=2 sts=2 ts=2 et
    autocmd FileType ruby         setlocal sw=2 sts=2 ts=2 et
    autocmd FileType javascript   setlocal sw=2 sts=2 ts=2 et
    "autocmd FileType js           setlocal sw=2 sts=2 ts=2 et
    autocmd FileType json         setlocal sw=2 sts=2 ts=2 et
    autocmd FileType css          setlocal sw=2 sts=2 ts=2 et
    autocmd FileType yaml         setlocal sw=2 sts=2 ts=2 et
  augroup END
endif

"===============================================================================
"  - Detect File Extention
"    - https://vim-jp.org/vimdoc-ja/filetype.html#ftdetect
"  - ftpluging
"    - http://vim.wikia.com/wiki/Keep_your_vimrc_file_clean
"let b:did_ftplugin = 1
filetype plugin on
filetype plugin indent on

augroup eachfileset
  autocmd!
  "autocmd BufRead,BufNewFile *           setfiletype neobundle
  autocmd BufRead,BufNewFile  *.py        setlocal filetype=python
  "autocmd BufRead,BufNewFile  *.md        setfiletype markdown
  autocmd BufRead,BufNewFile  *.cpp       setlocal filetype=cpp
  autocmd BufRead,BufNewFile  *.java      setlocal filetype=java
  autocmd BufRead,BufNewFile  *.html.erb  setlocal filetype=html
  autocmd BufRead,BufNewFile  *.conf      setlocal filetype=conf
  autocmd BufRead,BufNewFile  Makefile    setlocal filetype=make
  autocmd BufRead,BufNewFile  *.asm       setlocal filetype=asm
  "au BufRead,BufNewFile *.erb setfiletype html;
augroup END


" `:source ~/.vimrc` するとBufRead等しないためautocmdが走らず`setlocal filetype`が実行されない.
" 故にindentなどがデフォルト値に戻ってしまう.
" そこで以下の用に `:source ~/.vimrc` するごとに再度`setlocal filetype`を実行する.
if &filetype == "python"
    setlocal filetype=python
elseif &filetype== "cpp"
    setlocal filetype=cpp
elseif &filetype == "java"
    setlocal filetype=java
elseif &filetype == "html"
    setlocal filetype=html
elseif &filetype == "make"
    setlocal filetype=make
elseif &filetype == "conf"
    setlocal filetype=conf
elseif &filetype == "asm"
    setlocal filetype=asm
endif
