# Fish shell configuration
# Load all conf.d files in order

for rc in ~/dotfiles/.fish/conf.d/*.fish
  source $rc
end
