# Git functions and aliases

# Functions

function git_fetch_branch
    git fetch origin "$argv[1]:$argv[1]"
end

function git_fetch_base
    git_fetch_branch (git_get_default_branch)
end

function git_push_set_upstream
    set -l remote (test (count $argv) -ge 1; and echo $argv[1]; or echo origin)
    set -l git_branch_name (git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if test -n "$git_branch_name"
        git push --set-upstream $remote $git_branch_name
    end
end

function git_commit_WIP
    set -l msg (git log -1 --format=%s | tr -d '\n')
    if string match -qr '^WIP' -- $msg
        git reset --soft HEAD~1
        git commit -m "$msg"
    else
        git commit -m "WIP: temporarily commit"
    end
end

function git_branch_cleanup
    set -l main_branch (test (count $argv) -ge 1; and echo $argv[1]; or git_get_default_branch)
    git switch $main_branch
    and git fetch --prune
    and git pull
    and git branch --merged | string match -rv '\*' | string match -rv $main_branch | xargs git branch -d
end

function git_branch_cleanup_force
    set -l main_branch (test (count $argv) -ge 1; and echo $argv[1]; or git_get_default_branch)
    git switch $main_branch
    and git fetch --prune
    and git pull
    and git branch | string match -rv '\*' | string match -rv $main_branch | xargs git branch -D
end

function git_fetch_pull_request
    set -l pr_num $argv[1]
    git fetch origin "pull/$pr_num/head:pr$pr_num"
end

function git_get_default_branch
    git remote show origin 2>/dev/null | head -n 5 | sed -n '/HEAD branch/s/.*: //p'
end

function c-func --description 'git commit with message'
    git commit -m "$argv"
end

##############
# alias (git) #
##############

alias f 'git fetch'
alias g git
alias ga 'git add'
alias gap 'git add -p'
alias gb 'git branch'
alias gc 'git commit -v'
alias gca 'git commit -v -a'
alias gcam 'git commit -v --amend'
alias gcl 'git clone --recurse-submodules'
alias gcm 'git commit -m'
alias gcp 'git commit -p -v'
alias gcpm 'git commit -p -m'
alias gf 'git fetch --prune'
alias gfp 'git fetch --prune && git pull'

# git log
alias gl 'git log'
alias glo 'git log --oneline --decorate'
alias glog 'git log --oneline --decorate --graph'
alias gloga 'git log --oneline --decorate --graph --all'
alias glf "git log --format='%C(auto)%h%Creset %G? %s'"
alias glfg "git log --format='%C(auto)%h%Creset %G? %s' --graph"
alias glfga "git log --format='%C(auto)%h%Creset %G? %s' --graph --all"
alias gls 'git log --stat'
alias glsp 'git log --stat -p'

alias gm 'git merge'
alias gop 'git checkout -p'
alias gp 'git push'
alias gpf 'git push --force-with-lease'
alias gpup git_push_set_upstream
alias gpul 'git pull'
alias gpull 'git pull'

alias gds 'git diff --staged'
alias gg 'git grep'
alias gr 'git restore'
alias grs 'git reset --soft'
alias gs 'git status'
alias gst 'git stash --include-untracked'
alias gstp 'git stash pop'
alias gwip git_commit_WIP
alias w 'git switch'
alias gw 'git switch'
alias c c-func

alias gpr git_fetch_pull_request
