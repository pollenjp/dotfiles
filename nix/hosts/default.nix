# マシン登録簿。1 マシン 1 行で追加する。
#
# home-manager は activate 時に $USER と home.username の不一致で中断するため、
# username は環境変数から取らず明示的に書く。
# (builtins.getEnv は --impure が必要になり `nix flake check` を壊す)
{ mkHome }:

{
  "pollenjp@x86_64-linux" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
  };

  "pollenjp@aarch64-linux" = mkHome {
    username = "pollenjp";
    system = "aarch64-linux";
  };

  "pollenjp@aarch64-darwin" = mkHome {
    username = "pollenjp";
    system = "aarch64-darwin";
  };

  "pollenjp@wsl" = mkHome {
    username = "pollenjp";
    system = "x86_64-linux";
    isWSL = true;
  };

  # 検証専用。実際の $HOME を汚さずに activate を試すためのもの。
  #   HOME=/tmp/hm-sandbox nix run home-manager -- switch --flake .#sandbox
  sandbox = mkHome {
    username = "user";
    system = "x86_64-linux";
    homeDirectory = "/tmp/hm-sandbox";
  };
}
