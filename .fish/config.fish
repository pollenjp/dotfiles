# Fish shell configuration
# Load all conf.d files in order

for rc in ~/dotfiles/.fish/conf.d/*.fish
    source $rc
end

# User-specific config
if test -f ~/.common_shellrc.fish
    source ~/.common_shellrc.fish
end
