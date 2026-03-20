# General aliases

alias f 'cd ..'
alias ff 'cd ../..'
alias fff 'cd ../../..'
alias ffff 'cd ../../../..'
alias e exit
alias show_ports_netstat 'netstat -tulpn'
alias show_ports_ss 'ss -ltnp'
alias H head

# return today's date in YYYY-MM-DD format
alias today "date '+%Y-%m-%d'"

#############
# echo PATH #
#############

function echo-PATH --description 'Display PATH entries one per line'
    for p in $PATH
        echo $p
    end
end

alias ep echo-PATH

####################
# VSCode workspace #
####################

function touch-vscode-workspace --description 'Create a VSCode workspace file'
    set -l workspace_name $argv[1]
    if test -z "$workspace_name"
        set workspace_name workspace
    end
    set -l workspace_file "$workspace_name.code-workspace"
    if test -f $workspace_file
        echo "File already exists: $workspace_file"
        return 1
    end
    echo '{
  "folders": [
    {
      "path": "."
    }
  ],
  "settings": {}
}' >$workspace_file
end

alias ws 'touch-vscode-workspace (basename (pwd))'

#######
# SSH #
#######

function ssh-copy-id-custom --description 'Copy SSH key to remote host'
    set -l pubkey_file ~/.ssh/id_ed25519.pub
    set -l ssh_host $argv[1]
    xargs -I{} ssh $ssh_host "echo {} >> .ssh/authorized_keys" <$pubkey_file
end

function datetime-format --description 'Print current datetime'
    set -l sep $argv[1]
    if test -z "$sep"
        set sep -
    end
    printf "%s" (date "+%Y{$sep}%m{$sep}%d{$sep}%H%M%S")
end

alias cp 'cp -i'
alias mv 'mv -i'
alias vi vim
alias LESS 'less -imMSR'
alias watch 'watch '

# Platform-specific ls aliases (only if exa not aliased)
switch (uname)
    case Darwin
        alias ls 'command ls -G'
        alias ll 'ls -alhF'
        alias l 'ls -a -CF1'
    case Linux
        alias ls 'command ls -F --color=auto --show-control-chars'
        alias ll 'ls -alhF --group-directories-first'
        alias la 'ls -A'
        alias l 'ls -a -CF1 --group-directories-first'
end

alias ssh-agent-start 'exec ssh-agent $SHELL'

function hatch-env-find-python --description 'Find python in hatch env'
    echo (hatch env find $argv)/bin/python
end
