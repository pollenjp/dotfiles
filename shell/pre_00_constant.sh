# shellcheck shell=bash

export HISTSIZE=10000
export SAVEHIST=10000
export HISTFILE=~/.shell_history

export SUDO_EDITOR=vim

if command -v manpath &>/dev/null; then
  tmp=$(manpath -g)
  export MANPATH="${MANPATH}:${tmp}"
fi
