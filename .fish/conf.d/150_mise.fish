# mise activation for fish

if command -q mise
  mise activate fish | source
  mise completion fish | source
end
