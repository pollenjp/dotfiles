# ghq cd
function cdrepo --description 'cd to ghq repository'
  if not command -v ghq &>/dev/null
    echo "ghq is not installed"
    return 1
  end
  if not command -v fzf &>/dev/null
    echo "fzf is not installed"
    return 1
  end

  set -l repodir (ghq list | fzf -1 +m) \
    && cd (ghq root)/$repodir
end
