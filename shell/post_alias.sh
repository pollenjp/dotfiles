# shellcheck shell=bash

alias f='cd ..'
alias ff='cd ../..'
alias fff='cd ../../..'
alias ffff='cd ../../../..'
alias e='exit'
alias show_ports_netstat="netstat -tulpn"
alias show_ports_ss="ss -ltnp"

#############
# echo PATH #
#############

# ```
# echo "${PATH//:/'\n'}"
# ``
alias echo-PATH='echo ''"${PATH//:/'"'\n'"'}"'

# ```
# tr : '\n' <<<"$PATH"
# ``
alias echo-PATH-tr='tr : '"'\n'"' <<<"$PATH"'

# ```
# grep -o '[^:]*' <<<"$PATH"
# ``
alias echo-PATH-grep="grep -o ""'[^:]*'"' <<<"$PATH"'

alias ep=echo-PATH-tr

# If `ssh-copy-id` is not installed, use this instead.
# ssh_send_key_to_remote user@hostname
function ssh-copy-id-custom () {
    set -e
    pubkey_file=~/.ssh/id_ed25519.pub
    ssh_host=$1
    set +e
    xargs -I{} ssh "${ssh_host}" "echo {} >> .ssh/authorized_keys" < "${pubkey_file}"
}
if command -v compdef &> /dev/null; then
    compdef ssh-copy-id-custom=ssh-copy-id
fi

function datetime-format() {
    # separator
    local sep="${1:--}"
    printf "%s" "$(date '+%Y'"${sep}"'%m'"${sep}"'%d'"${sep}"'%H%M%S')"
}

alias cp='cp -i'
#  -i, --interactive
#    prompt before overwrite
alias mv='mv -i'
alias vi='vim'
alias LESS='less -imMSR'

case "${OSTYPE}" in
    darwin*) # macos
        alias ls="ls -G"
        alias ll='ls -alhF'
        alias l='ls -a -CF1'
        ;;
    linux*)
        alias ls='ls -F --color=auto --show-control-chars'
        alias ll='ls -alhF --group-directories-first'
        alias la='ls -A'
        alias l='ls -a -CF1 --group-directories-first'
        ;;
    msys*) # windows
        alias ls='ls -F --color=auto --show-control-chars'
        alias ll='ls -alhF --group-directories-first'
        alias la='ls -A'
        alias l='ls -a -CF1 --group-directories-first'
        ;;
    *)
esac

alias ssh-agent-start='exec ssh-agent $SHELL'
