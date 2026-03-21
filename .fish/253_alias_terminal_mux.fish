################
# tmux         #
################

function tss --description 'tmux start session'
  set -l session_name $argv[1]
  if test -z "$session_name"
    echo "Usage: tss <session_name>"
    return 1
  end
  tmux -f ~/dotfiles/tmux/interactive_shell.tmux.conf new -s $session_name
end

abbr ta 'tmux a -t'
abbr td 'tmux detach -s'
abbr tkill-sess 'tmux kill-session'
abbr tls 'tmux ls'
abbr tls-panes 'tmux list-panes'

function tmux-cwd --description 'Change tmux session directory'
  tmux command-prompt -I "$PWD" -p "New session dir:" "attach -c %1"
end

abbr tchdir tmux-cwd

# multi-agent-shogun aliases (added by first_setup.sh)
function css --description 'attach to shogun tmux session'
  set -l s "shogun-$fish_pid"
  set -l cols (tput cols 2>/dev/null; or echo 80)
  tmux new-session -d -t shogun -s "$s" 2>/dev/null
  and tmux set-option -t "$s" destroy-unattached on 2>/dev/null

  if test "$cols" -lt 80
    tmux new-window -t "$s" -n mobile 2>/dev/null
    tmux attach-session -t "$s:mobile" 2>/dev/null
    or tmux attach-session -t shogun
  else
    tmux attach-session -t "$s" 2>/dev/null
    or tmux attach-session -t shogun
  end
end
function csm --description 'attach to multiagent tmux session'
  set -l s "multi-$fish_pid"
  set -l cols (tput cols 2>/dev/null; or echo 80)
  tmux new-session -d -t multiagent -s "$s" 2>/dev/null
  and tmux set-option -t "$s" destroy-unattached on 2>/dev/null

  if test "$cols" -lt 80
    tmux new-window -t "$s" -n mobile 2>/dev/null
    tmux attach-session -t "$s:mobile" 2>/dev/null
    or tmux attach-session -t multiagent
  else
    tmux attach-session -t "$s" 2>/dev/null
    or tmux attach-session -t multiagent
  end
end

######################
# GNU Screen         #
######################

abbr schdir 'screen -X eval "chdir $PWD"'
abbr slayout 'screen -X eval "layout save default"'
abbr sss 'screen -S'
abbr sls 'screen -ls'
abbr sa 'screen -r'
abbr sd 'screen -d'

function screen-kill-session --description 'Kill a screen session'
  screen -X -S $argv[1] kill
end

abbr skill-sess screen-kill-session

##################
# zellij         #
##################

function z --description 'zellij with favorite shell'
  set -l _shell_path
  if set _shell_path (command -v fish)
    : # do nothing
  else if set _shell_path (command -v zsh)
    : # do nothing
  end

  if test -n "$_shell_path"
    set -x SHELL $_shell_path
  end
  zellij $argv
end
function zss --description 'zellij start session'
  set -l session_name $argv[1]
  if test -z "$session_name"
    echo "Usage: zss <session_name>"
    return 1
  end
  set -l session_line (zellij list-sessions 2>/dev/null | grep $session_name)
  if test -n "$session_line"
    if string match -q '*EXITED*' -- $session_line
      zellij delete-session $session_name
      z -s $session_name
    else
      echo "Already running! Run 'zellij attach $session_name' to attach to it."
    end
  else
    z -s $session_name
  end
end

abbr zls 'zellij list-sessions'
abbr za 'zellij attach'
abbr zkill 'zellij kill-session'
abbr zkill-all 'zellij kill-all-sessions'
abbr zdel 'zellij delete-session'
abbr zdel-all 'zellij delete-all-sessions'
