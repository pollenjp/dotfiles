{ ... }:

{
  imports = [
    ./options.nix
    ./modules/packages.nix
    ./modules/files.nix
    ./modules/git.nix
    ./modules/ssh.nix
    ./modules/starship.nix
    ./modules/mise.nix
    ./modules/shell-common.nix
    ./modules/fish.nix
    ./modules/bash.nix
    ./modules/claude.nix
  ];

  # 初回導入時の home-manager リリースに固定する。
  # DO NOT CHANGE — 変更するとステートフルな移行が発生する。
  # home-manager release notes を読まずに上げないこと。
  #
  # 有効値の一覧は次で確認できる:
  #   nix eval .#homeConfigurations.sandbox.options.home.stateVersion.type.description
  home.stateVersion = "26.11";

  # home-manager CLI 自身を profile に入れる
  programs.home-manager.enable = true;
}
