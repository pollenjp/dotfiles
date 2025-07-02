# shellcheck shell=bash

########################
# Alternative Commands #
########################

if command -v mise &>/dev/null; then
  pkgs=(
    ghq
    # bat command (cat alternative)
    cargo:bat
    # fd command (fd-find) (find alternative)
    cargo:fd-find
    # exa command (ls alternative)
    cargo:exa
    # procs command (ps alternative)
    cargo:procs
    # rg command (ripgrep) (grep alternative)
    cargo:ripgrep
  )
  #shellcheck disable=2016
  mise_use_script='mise use -g "$1" &>/dev/null'
  printf "%s\n" "${pkgs[@]}" | xargs -P0 -I{} bash -c "$mise_use_script" _ {}

  if command -v bat &>/dev/null; then alias cat='bat'; fi
  if command -v exa &>/dev/null; then alias ls='exa'; fi
  if command -v rg &>/dev/null; then alias grep='rg'; fi
fi
