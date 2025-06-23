# shellcheck shell=bash

alias f='cd ..'
alias ff='cd ../..'
alias fff='cd ../../..'
alias ffff='cd ../../../..'
alias e='exit'
alias show_ports_netstat="netstat -tulpn"
alias show_ports_ss="ss -ltnp"

# return today's date in YYYY-MM-DD format
alias today="date '+%Y-%m-%d'"

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

####################
# VSCode workspace #
####################

touch-vscode-workspace() {
  local workspace_name="${1:-workspace}"
  if [[ -z "${workspace_name}" ]]; then
    echo "Usage: touch-vscode-workspace <workspace_name>"
    return 1
  fi
  local workspace_file="${workspace_name}.code-workspace"
  if [[ -f "${workspace_file}" ]]; then
    echo "File already exists: ${workspace_file}"
    return 1
  fi
  cat <<__EOF__ >"${workspace_file}"
{
  "folders": [
    {
      "path": "."
    }
  ],
  "settings": {}
}
__EOF__
}

alias ws='touch-vscode-workspace "$(basename "$(pwd)")"'

#######
# SSH #
#######

# If `ssh-copy-id` is not installed, use this instead.
# ssh_send_key_to_remote user@hostname
function ssh-copy-id-custom() {
  set -e
  pubkey_file=~/.ssh/id_ed25519.pub
  ssh_host=$1
  set +e
  xargs -I{} ssh "${ssh_host}" "echo {} >> .ssh/authorized_keys" <"${pubkey_file}"
}
if command -v compdef &>/dev/null; then
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
  *) ;;
esac

alias ssh-agent-start='exec ssh-agent $SHELL'

# 末尾のスペースによって補完を有効化
alias watch='watch '

function hatch-env-find-python() {
  echo "$(hatch env find "${@+"$1"}")"/bin/python
}
