source ~/dotfiles/vim_common/common.vim
source ~/dotfiles/vim_common/clipboard.vim

let os_name = system('uname -o')
if os_name == "Msys\n"
    " Windows
    " normal mode / visual mode
    nnoremap y "*y
    vnoremap y "*y
elseif os_name == "GNU/Linux\n"
    " GNU/Linux
elseif os_name == "Darwin\n"
    " OSX
else
    " Unknown
endif
