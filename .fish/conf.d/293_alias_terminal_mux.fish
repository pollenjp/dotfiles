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

abbr z 'SHELL=/usr/bin/fish zellij'

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

abbr zls 'z list-sessions'
abbr za 'z attach'
abbr zkill 'z kill-session'
abbr zkill-all 'z kill-all-sessions'
abbr zdel 'z delete-session'
abbr zdel-all 'z delete-all-sessions'
