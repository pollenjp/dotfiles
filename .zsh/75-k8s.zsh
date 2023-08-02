# shellcheck shell=zsh

[[ $commands[kubectl] ]] && source <(kubectl completion zsh)

alias k=kubectl
