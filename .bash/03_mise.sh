# shellcheck shell=bash

# shellcheck disable=SC1090
if command -v mise &>/dev/null; then
  # https://mise.jdx.dev/installing-mise.html#shells
  eval "$(mise activate bash)"

  # completion
  # https://mise.jdx.dev/installing-mise.html#autocompletion
  mise use -g usage >/dev/null 2>&1
  mkdir -p ~/.local/share/bash-completion/completions
  mise completion bash --include-bash-completion-lib > ~/.local/share/bash-completion/completions/mise
fi
