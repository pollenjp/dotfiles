# suppress the greeting message
set -g fish_greeting

# Run 'fisher update' only once a day
if not set -q _fisher_updating
  set -l flag ~/.config/fish/.fisher_last_update
  begin
    flock 9
    if not test -f $flag; or test (math (date +%s) - (stat -c %Y $flag 2>/dev/null; or echo 0)) -gt 86400
      # 再起防止 (fisher update の中で再起的に呼ばれるため)
      set -gx _fisher_updating 1
      fisher update
      set -e _fisher_updating
      touch $flag
    end
  end 9>$flag
end

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
