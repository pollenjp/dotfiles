# kubectl completion for fish

if command -q kubectl
    kubectl completion fish | source
end
