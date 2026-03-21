# shellcheck shell=bash

# ghq cd
function cdrepo() {
  local ghq_list repodir ghq_root
  ghq_list=$(ghq list) \
    && repodir=$(fzf -1 +m <<<"$ghq_list") \
    && ghq_root=$(ghq root) \
    && cd "${ghq_root:?}/${repodir:?}" || return
}
