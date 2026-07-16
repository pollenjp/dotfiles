if status is-interactive
# Commands to run in interactive sessions can go here
end

for rc in ~/.config/fish/fragments/*.fish
  source $rc
end
