# この PC (dave@box) のホストの定義と値の全部 (dotfiles の ADR 025)。ホストの名前はファイル名から .nix を除いたもの。
# ローカル flake (~/dotfiles/flake.nix) の local はこのホストには当たらない。値を変えるときはこのファイルを直す。
{ mkHome, ... }:
mkHome {
  username = "dave";
  system = "x86_64-linux";
  wsl = {
    enable = true;
    windowsFiles.enable = true;
    windowsUserName = "dave";
  };
  onePassword.enable = true;
  claude.devTracker.enable = false;
}
