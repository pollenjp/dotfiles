########################
# Alternative Commands #
########################

# CLI ツールを誰が管理しているか。
# マーカーファイルが無ければ従来どおり mise (= 挙動は変わらない)。
# マーカーは Nix の home-manager (nix/home/modules/mise.nix) が配置する。
function _dotfiles_package_manager --description 'Who manages CLI tools (nix or mise)'
  set -l _state_home $XDG_STATE_HOME
  if test -z "$_state_home"
    set _state_home ~/.local/state
  end
  if test -f $_state_home/dotfiles/package-manager
    cat $_state_home/dotfiles/package-manager
  else
    echo mise
  end
end

if not command -q mise
  echo "mise is not installed. Refer to 'https://mise.jdx.dev/'"
else
  set -l _pm (_dotfiles_package_manager)

  # Nix が CLI ツールを持つ環境では、起動毎の config.toml 書き換えと
  # mise install を行わない。言語ランタイム (go/node) の管理は
  # ~/.config/mise/config.toml に残っているものが引き続き担う。
  if test "$_pm" = mise
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
      jq                           latest \
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
        # config.toml がなければテンプレートを初期ファイルとしてコピーする
        if not test -f $mise_config_path
          mkdir -p (dirname $mise_config_path)
          cp ~/dotfiles/.config_tmpl/mise/config.toml $mise_config_path
        end
        if not command grep -q -E "^[\"]?"$_pkg"[\"]? =" $mise_config_path
          sed -i '/\[tools\]/a "'"$_pkg"'" = "'"$_ver"'"' $mise_config_path
        end
      end
    end 9>/tmp/mise_config_lock
  end

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
  if test "$_pm" = mise
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
end
