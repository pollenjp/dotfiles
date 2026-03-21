function fish_greeting
  echo "Welcome back"
  echo "Run following command to update fish plugins!"

  set -l msg 'fisher update'

  # msg のlength 分の `-` を表示
  set_color normal
  string repeat -n (string length -- "$msg") -

  set_color yellow
  echo $msg

  # msg のlength 分の `-` を表示
  set_color normal
  string repeat -n (string length -- "$msg") -
end
funcsave fish_greeting

if not type -q fisher
  curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source
end

if type -q fzf_configure_bindings
  # fzf_configure_bindings --help
  #
  # COMMAND            |  DEFAULT KEY SEQUENCE         |  CORRESPONDING OPTION
  # Search Directory   |  Ctrl+Alt+F (F for file)      |  --directory
  # Search Git Log     |  Ctrl+Alt+L (L for log)       |  --git_log
  # Search Git Status  |  Ctrl+Alt+S (S for status)    |  --git_status
  # Search History     |  Ctrl+R     (R for reverse)   |  --history
  # Search Processes   |  Ctrl+Alt+P (P for process)   |  --processes
  # Search Variables   |  Ctrl+V     (V for variable)  |  --variables
  #
  fzf_configure_bindings \
    --directory=alt-shift-f \
    --git_log=alt-shift-l \
    --git_status=alt-shift-s \
    --processes=alt-shift-p
end
