# shellcheck shell=bash

if command -v manpath &>/dev/null; then
  tmp=$(manpath -g)
  export MANPATH="${MANPATH}:${tmp}"
fi

export HISTSIZE=10000
export SAVEHIST=10000
export HISTFILE=~/.shell_history

export SUDO_EDITOR=vim

bin_path="${HOME}/.local/bin"
case ":${PATH}:" in
  *:"${bin_path}":*) ;;
  *)
    export PATH="${bin_path}:$PATH"
    ;;
esac

if command -v bindkey &>/dev/null; then
  bindkey -v
fi
