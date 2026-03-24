########################
# Alternative Commands #
########################

if not command -q mise
  echo "mise is not installed. Refer to 'https://mise.jdx.dev/'"
else
  set -l mise_config_path ~/.config/mise/config.toml
  set -l pkgs \
    cargo-binstall               latest \
    cargo:bat                    latest \
    cargo:eza                    latest \
    cargo:fd-find                latest \
    cargo:procs                  latest \
    cargo:ripgrep                latest \
    fzf                          latest \
    ghq                          latest \
    github:fish-shell/fish-shell latest \
    go                           latest \
    node                         v24 \
    starship                     latest \
    usage                        latest \
    watchexec                    latest \
    zellij                       latest

  # Check array length
  # Since package names and versions are managed in pairs, the number of elements must be even
  if test (math (count $pkgs) % 2) -ne 0
    echo "Error: 'pkgs' array length must be even." >&2
    exit 1
  end

  # Use flock for concurrency safety (same as bash/zsh version)
  begin
    flock -x 9
    for i in (seq 1 2 (count $pkgs))
      set -l _pkg $pkgs[$i]
      set -l _ver $pkgs[(math $i + 1)]
      if not command grep -q -E "^[\"]?"$_pkg"[\"]? =" $mise_config_path
        sed -i '/\[tools\]/a "'"$_pkg"'" = "'"$_ver"'"' $mise_config_path
      end
    end
  end 9>/tmp/mise_config_lock

  # Set up alternative command aliases
  if command -q bat
    abbr cat bat
  end
  if command -q eza
    abbr ls eza
  end
  if command -q rg
    abbr grep rg
  end
  if command -q fzf
    abbr fuz fzf
  end

  mise activate fish | source
  mise completion fish | source

  # Run 'mise install' only once a day
  if not set -q _mise_installing
    set -l flag ~/.config/mise/.mise_last_install
    begin
      flock 9
      if not test -f $flag; or test (math (date +%s) - (stat -c %Y $flag 2>/dev/null; or echo 0)) -gt 86400
        # 再起防止 (mise install の中で再起的に呼ばれるため)
        set -gx _mise_installing 1
        mise install
        set -e _mise_installing
        touch $flag
      end
    end 9>$flag
  end
end
