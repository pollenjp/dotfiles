# nix/tests/private-hosts.nix の作り物 (dotfiles-private の nix/hosts/<user>@<hostname>.nix の形)
{ mkHome, ... }:
mkHome {
  username = "bob";
  system = "x86_64-linux";
  wsl = {
    enable = true;
    windowsUserName = "bob";
  };
  # Dev Tracker を使わないマシン (使うなら notion.profile が要り、無いと評価のたびに警告が出る)
  claude.devTracker.enable = false;
}
