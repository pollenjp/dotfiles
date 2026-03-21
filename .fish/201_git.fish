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

abbr f 'git fetch'
abbr g git
abbr ga 'git add'
abbr gap 'git add -p'
abbr gb 'git branch'
abbr gc 'git commit -v'
abbr gca 'git commit -v -a'
abbr gcam 'git commit -v --amend'
abbr gcl 'git clone --recurse-submodules'
abbr gcm 'git commit -m'
abbr gcp 'git commit -p -v'
abbr gcpm 'git commit -p -m'
abbr gf 'git fetch --prune'
abbr gfp 'git fetch --prune && git pull'

# git log
abbr gl 'git log'
abbr glo 'git log --oneline --decorate'
abbr glog 'git log --oneline --decorate --graph'
abbr gloga 'git log --oneline --decorate --graph --all'
abbr glf "git log --format='%C(auto)%h%Creset %G? %s'"
abbr glfg "git log --format='%C(auto)%h%Creset %G? %s' --graph"
abbr glfga "git log --format='%C(auto)%h%Creset %G? %s' --graph --all"
abbr gls 'git log --stat'
abbr glsp 'git log --stat -p'

abbr gm 'git merge'
abbr gop 'git checkout -p'
abbr gp 'git push'
abbr gpf 'git push --force-with-lease'
abbr gpup git_push_set_upstream
abbr gpul 'git pull'
abbr gpull 'git pull'

abbr gds 'git diff --staged'
abbr gg 'git grep'
abbr gr 'git restore'
abbr grs 'git reset --soft'
abbr gs 'git status'
abbr gst 'git stash --include-untracked'
abbr gstp 'git stash pop'
abbr gwip git_commit_WIP
abbr w 'git switch'
abbr gw 'git switch'
abbr c c-func

abbr gpr git_fetch_pull_request
