# home-manager の設定の入口 (lib/mk-home.nix がマシンごとに読む)。options.nix と modules/ の各 module を
# import し、stateVersion を固定する。
{ ... }:

{
  imports = [
    ./options.nix
    ./modules/packages.nix
    ./modules/files.nix
    ./modules/git.nix
    ./modules/ssh.nix
    ./modules/agent-link.nix
    ./modules/starship.nix
    ./modules/shell-common.nix
    ./modules/os-ca-bundle.nix
    ./modules/fish.nix
    ./modules/bash.nix
    ./modules/claude.nix
    ./modules/cc-pages.nix
    ./modules/dev-tracker-inbox.nix
    ./modules/windows-files.nix
    ./modules/exe-exec-trace.nix
    ./modules/cleanup.nix
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
