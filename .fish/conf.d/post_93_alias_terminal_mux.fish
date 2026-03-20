################
# alias (tmux) #
################

function tss --description 'tmux start session'
    set -l session_name $argv[1]
    if test -z "$session_name"
        echo "Usage: tss <session_name>"
        return 1
    end
    tmux -f ~/dotfiles/tmux/interactive_shell.tmux.conf new -s $session_name
end

alias ta 'tmux a -t'
alias td 'tmux detach -s'
alias tkill-sess 'tmux kill-session'
alias tls 'tmux ls'
alias tls-panes 'tmux list-panes'

function tmux-cwd --description 'Change tmux session directory'
    tmux command-prompt -I "$PWD" -p "New session dir:" "attach -c %1"
end

alias tchdir tmux-cwd

######################
# alias (GNU Screen) #
######################

alias schdir 'screen -X eval "chdir $PWD"'
alias slayout 'screen -X eval "layout save default"'
alias sss 'screen -S'
alias sls 'screen -ls'
alias sa 'screen -r'
alias sd 'screen -d'

function screen-kill-session --description 'Kill a screen session'
    screen -X -S $argv[1] kill
end

alias skill-sess screen-kill-session

##################
# alias (zellij) #
##################

alias z 'SHELL=/usr/bin/fish zellij'

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

alias zls 'z list-sessions'
alias za 'z attach'
alias zkill 'z kill-session'
alias zkill-all 'z kill-all-sessions'
alias zdel 'z delete-session'
alias zdel-all 'z delete-all-sessions'
