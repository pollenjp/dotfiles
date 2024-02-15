# shellcheck shell=bash

################
# alias (tmux) #
################

alias tss='tmux new -s'   # tmux start session
alias ta='tmux a -t'      # tmux attach session
alias td='tmux detach -s' # tmux detach session
alias tkill-sess='tmux kill-session'
alias tls='tmux ls'               # ls sessions
alias tls-panes='tmux list-panes' # ls panes
# Change the current directory for a tmux session, which determines
# the starting dir for new windows/panes:
function tmux-cwd {
  tmux command-prompt -I "$PWD" -p "New session dir:" "attach -c %1"
}
alias tchdir=tmux-cwd

######################
# alias (GNU Screen) #
######################

alias schdir='screen -X eval "chdir $PWD"'
alias slayout='screen -X eval "layout save default"'
# [How to make GNU Screen start a new window at the CURRENT working directory? - Stack Overflow](https://stackoverflow.com/a/1517488/9316234)
alias sss='screen -S'  # screen start session
alias sls='screen -ls' # screen ls sessions
alias sa='screen -r'   # screen attach session
alias sd='screen -d'   # detatch session
function screen-kill-session() {
  screen -X -S "$1" kill
}
alias skill-sess=screen-kill-session

##################
# alias (zellij) #
##################

alias z='SHELL=/usr/bin/zsh zellij'
alias zss='z -s'
alias zls='z list-sessions'
alias za='z attach'
alias zkill-session='z kill-session'
alias zkill-all='z kill-all-sessions'
