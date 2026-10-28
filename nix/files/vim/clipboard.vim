""""""""""
" zellij "
""""""""""

function! SaveToClipboardFile(args)
  let args_list = []
  if !empty(a:args)
    let arg_list = split(a:args, '\v\s+')
  endif

  let register_name = '"'
  let filename = '~/clipboard.txt'

  if len(args_list) == 0
    " do nothing
  elseif len(args_list) == 1
    let register_name = args_list[0]
  elseif len(args_list) == 2
    let register_name = args_list[0]
    let filename = args_list[1]
  else
    echo 'Invalid arguments'
    echo 'Usage: ZellijSave [register] [filename]'
    return
  endif

  let register_content = getreg(register_name)
  let file = expand(filename)

  let cmd = printf('echo "%s" > %s', register_content, file)
  call system(cmd)

  echo 'Clipboard saved to ' . file
endfunction
command! -nargs=* ClipRegister :call SaveToClipboardFile(<q-args>)

""""""""""
" OSC 52 "
""""""""""

" OSC 52 で手元の端末の clipboard へ書く (Vim 9.2 同梱の osc52 package)
if has('clipboard_provider')
  " herdr は OSC 52 の読み出しに答えないので、"+p で待たない。packadd より前に置く
  let g:osc52_disable_paste = 1
  " herdr 0.9.1 は DA1 に 52 を載せず自動の検出が通らないので、herdr の中では検出を飛ばす
  if $HERDR_ENV ==# '1'
    let g:osc52_force_avail = 1
  endif
  packadd osc52
  set clipmethod+=osc52
  " register を付けない yank (yy・y{motion}・visual の y) だけ clipboard へ送る。dd・x・"ay は送らない
  augroup osc52_yank
    autocmd!
    autocmd TextYankPost * if v:event.operator ==# 'y' && v:event.regname ==# '' && v:clipmethod !=# 'none'
          \ | call setreg('+', v:event.regcontents, v:event.regtype) | endif
  augroup END
endif
