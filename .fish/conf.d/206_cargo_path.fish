# Rust/Cargo environment

if test -f ~/.cargo/env.fish
    source ~/.cargo/env.fish
else if test -d ~/.cargo/bin
    fish_add_path --prepend ~/.cargo/bin
end
