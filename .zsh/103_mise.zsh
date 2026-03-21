# shellcheck disable=SC1090
if command -v mise &>/dev/null; then
  # https://mise.jdx.dev/installing-mise.html#shells
  eval "$(mise activate zsh)"

  # completion
  # https://mise.jdx.dev/installing-mise.html#autocompletion
  mise completion zsh >"${zsh_user_custom_fpath}/_mise"
fi
