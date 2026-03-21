if status is-interactive
# Commands to run in interactive sessions can go here
end

for rc in ~/dotfiles/.fish/*.fish
  source $rc
end
