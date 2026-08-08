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
