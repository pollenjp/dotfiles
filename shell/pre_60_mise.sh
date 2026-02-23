# shellcheck shell=bash

########################
# Alternative Commands #
########################

if command -v mise &>/dev/null; then
  pkgs=(
    # ---
    usage
    latest
    # ---
    # mise watch
    watchexec
    latest
    # ---
    cargo-binstall
    latest
    # ---
    ghq
    latest
    # ---
    # 'bat' is 'cat' alternative
    cargo:bat
    latest
    # ---
    # 'fd' is 'find' alternative
    cargo:fd-find
    latest
    # ---
    # 'exa' is 'ls' alternative
    cargo:exa
    latest
    # ---
    # 'procs' is 'ps' alternative
    cargo:procs
    latest
    # ---
    # 'rg' is 'grep' alternative
    cargo:ripgrep
    latest
    # ---
    go
    latest
    # ---
    node
    v24
  )
  if (( ${#pkgs[@]} % 2 != 0 )); then
    echo "Error: 'pkgs' array length must be even." >&2
    exit 1
  fi
  mise_config_path=~/.config/mise/config.toml

  # 複数シェルを同時起動した時に競合するため lock を取る
  exec 3<> /tmp/mise_config_lock  # open file as '3' descriptor
  flock -x 3                      # lock

  # if zsh, set 0-origin array
  [ -n "$ZSH_VERSION" ] && setopt KSH_ARRAYS
  for ((i=0; i<${#pkgs[@]}; i+=2)); do
    pkg="${pkgs[i]}"
    version="${pkgs[i+1]}"
    if ! grep -q -E "^[\"]?${pkg}[\"]? =" "${mise_config_path:?}"; then
      sed -i '/\[tools\]/a '"\"${pkg}\" = \"${version}\"" "${mise_config_path}"
      # echo "\"${pkg}\" = \"${version}\""
    fi
  done
  # unset 0-origin array
  [ -n "$ZSH_VERSION" ] && unsetopt KSH_ARRAYS

  flock -u 3 # unlock
  exec 3>&-  # close file descriptor

  if command -v bat &>/dev/null; then alias cat='bat'; fi
  if command -v exa &>/dev/null; then alias ls='exa'; fi
  if command -v rg &>/dev/null; then alias grep='rg'; fi
else
  echo "mise is not installed"
fi
