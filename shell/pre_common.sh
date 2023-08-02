# shellcheck shell=bash

export HISTSIZE=10000
export SAVEHIST=10000
export HISTFILE=~/.shell_history

export SUDO_EDITOR=vim

local_bin_path="${HOME}/.local/bin"
# shellcheck disable=SC2295
if [[ -d "${local_bin_path}" ]]\
&& [[ -n "${PATH##*${local_bin_path}}" ]]\
&& [[ -n "${PATH##*${local_bin_path}:*}" ]]; then
    export PATH="${local_bin_path}:${PATH}"
fi

if command -v bindkey &> /dev/null; then
    bindkey -v
fi
