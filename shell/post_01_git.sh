# shellcheck shell=bash

# Funcs

git-fetch-branch() {
  # git fetch branch
  git fetch origin "${1:?}:${1:?}"
}
git-fetch-base() {
  # git fetch the default branch (main/master)
  # You can use this if current branch is not in the default branch
  git-fetch-branch "$(git-get-default-branch)"
}
function git_push_set_upstream() {
  local remote=${1:-origin}
  local git_branch_name
  git_branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ -n ${git_branch_name} ]]; then
    git push --set-upstream "${remote}" "${git_branch_name}"
  fi
}
# if log start with 'WIP', then `git reset --soft` and commit with 'WIP'
function git-commit-WIP() {
  local msg=""
  msg="$(git log -1 --format=%s | tr -d '\n')"
  if [[ ${msg} =~ ^WIP ]]; then
    git reset --soft HEAD~1
    git commit -m "${msg}"
  else
    git commit -m "WIP: temporarily commit"
  fi
}

##############
# alis (git) #
##############

alias f='git fetch'
alias g='git'
alias ga='git add'
alias gap='git add -p'
alias gb='git branch'
alias gc='git commit -v'
alias gca='git commit -v -a'
alias gcam='git commit -v --amend'
alias gcl='git clone --recurse-submodules'
alias gcm='git commit -m'
alias gcp='git commit -p -v'
alias gcpm='git commit -p -m'
alias gf='git fetch --prune'
alias gfp='git fetch --prune && git pull'

# git log
alias gl='git log'
# oneline
alias glo='git log --oneline --decorate'
alias glog='glo --graph'
alias gloga='glog --all'
# custom oneline format (hash, signature, subject)
alias glf="gl --format='%C(auto)%h%Creset %G? %s'"
alias glfg='glf --graph'
alias glfga='glfg --all'
# stat
alias gls='gl --stat'
alias glsp='gls -p'

alias gm='git merge'
alias git-get-default-branch="git remote show origin | head -n 5 | sed -n '/HEAD branch/s/.*: //p'"
alias gop='git checkout -p'
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gpup=git_push_set_upstream
alias gpul='git pull'
alias gpull='git pull'

alias gds='git diff --staged'
alias gg='git grep'
alias gr='git restore'
alias grs='git reset --soft'
alias gs='git status'
alias gst='git stash'
alias gwip=git-commit-WIP
alias w='git switch'
alias gw='git switch'

function c-func() {
  git commit -m "$*"
}
# examples
#   - $ c hello world
#   - $ git add abc.txt
#     $ c !$
alias c='noglob c-func'

function git-fetch-pull-rquest() {
  set -u
  local pr_num="${1}"
  git fetch origin "pull/${pr_num}/head:pr${pr_num}"
}

alias gpr='git-fetch-pull-rquest'
