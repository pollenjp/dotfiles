if status is-interactive
# Commands to run in interactive sessions can go here
end

for rc in ~/dotfiles/.fish/*.fish
  source $rc
end

set -l common_shellrc "$HOME/.common_shellrc.fish"
if not test -f "$common_shellrc"
  touch "$common_shellrc"
end
source "$common_shellrc"
