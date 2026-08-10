# マシン登録簿。1 マシン 1 行で追加する。
#
# home-manager は activate 時に $USER と home.username の不一致で中断するため、
# username は環境変数から取らず明示的に書く。
# (builtins.getEnv は --impure が必要になり `nix flake check` を壊す)
#
# mkHome に渡せるもの:
#   username        Linux/macOS 側のユーザー名 (必須)
#   system          x86_64-linux / aarch64-linux / aarch64-darwin (必須)
#   homeDirectory   既定は /home/<username> (darwin は /Users/<username>)
#   isWSL           WSL 上のマシンか
#   onePassword     1Password の SSH agent を使うか (git の署名設定が切り替わる)
#   windowsUserName WSL + 1Password のときだけ必要。ホスト側 Windows のユーザー名
{ mkHome }:

{
  "pollenjp@x86_64-linux" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    onePassword = true;
  };

  "pollenjp@aarch64-linux" = mkHome {
    username = "pollenjp";
    system = "aarch64-linux";
    onePassword = true;
  };

  "pollenjp@aarch64-darwin" = mkHome {
    username = "pollenjp";
    system = "aarch64-darwin";
    onePassword = true;
  };

  # WSL + ホスト側 Windows の 1Password。
  # git の署名は Windows 側の op-ssh-sign-wsl.exe を経由する。
  "pollenjp@wsl" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    isWSL = true;
    onePassword = true;
    # ホスト側 Windows のユーザー名。1Password の op-ssh-sign のパス
    # (/mnt/c/Users/<名前>/AppData/...) の組み立てに使う。
    #
    # 値は WSL 上で次を実行すると判る:
    #   pwsh.exe -NoProfile -Command '$env:USERNAME'
    # (pwsh.exe が無ければ powershell.exe でも同じ)
    #
    # Nix の評価は純粋なのでこのコマンドを評価時に実行することはできない。
    # (getEnv や --impure は nix flake check を壊す)。よってここに直接書く。
    windowsUserName = "polle";
  };

  # WSL だがホスト側に 1Password が無いマシン。
  # git の署名設定は一切書き出されない (署名なしで commit できる)。
  # windowsUserName も要らない。
  "pollenjp@wsl-no-1password" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    isWSL = true;
    onePassword = false;
  };

  # 検証専用。実際の $HOME を汚さずに activate を試すためのもの。
  #   HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox
  sandbox = mkHome {
    username = "user";
    system = "x86_64-linux";
    homeDirectory = "/tmp/hm-sandbox";
  };
}
