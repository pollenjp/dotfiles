# shellcheck shell=bash

# ghq cd
function cdrepo() {
  if not command -v ghq &>/dev/null; then
    echo "ghq is not installed"
    return 1
  fi
  if not command -v fzf &>/dev/null; then
    echo "fzf is not installed"
    return 1
  fi

  local ghq_list repodir ghq_root
  ghq_list=$(ghq list) \
    && repodir=$(fzf -1 +m <<<"$ghq_list") \
    && ghq_root=$(ghq root) \
    && cd "${ghq_root:?}/${repodir:?}" || return
}
