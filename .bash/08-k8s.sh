#!/usr/bin/env bash
# shellcheck shell=bash

if command -v kubectl &> /dev/null; then
    source <(kubectl completion bash)
fi

alias k=kubectl
complete -o default -F __start_kubectl k
