# ghq cd
function cdrepo --description 'cd to ghq repository'
  set -l repodir (ghq list | fzf -1 +m) \
    && cd (ghq root)/$repodir
end
