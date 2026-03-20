########################
# Alternative Commands #
########################

if command -q mise
    set -l mise_config_path ~/.config/mise/config.toml

    if test -f $mise_config_path
        set -l pkg_names \
            usage \
            watchexec \
            cargo-binstall \
            ghq \
            "cargo:bat" \
            "cargo:fd-find" \
            "cargo:exa" \
            "cargo:procs" \
            "cargo:ripgrep" \
            go \
            node \
            zellij

        set -l pkg_versions \
            latest \
            latest \
            latest \
            latest \
            latest \
            latest \
            latest \
            latest \
            latest \
            latest \
            v24 \
            latest

        # Use flock for concurrency safety (same as bash/zsh version)
        set -l lock_file /tmp/mise_config_lock
        touch $lock_file

        begin
            flock -x 3
            for i in (seq 1 (count $pkg_names))
                set -l pkg $pkg_names[$i]
                set -l version $pkg_versions[$i]
                if not command grep -q -E "^[\"]?$pkg[\"]? =" $mise_config_path
                    sed -i "/\[tools\]/a \"$pkg\" = \"$version\"" $mise_config_path
                end
            end
        end 3>$lock_file

        # Set up alternative command aliases
        if command -q bat
            alias cat bat
        end
        if command -q exa
            alias ls exa
        end
        if command -q rg
            alias grep rg
        end
    end
else
    echo "mise is not installed"
end
