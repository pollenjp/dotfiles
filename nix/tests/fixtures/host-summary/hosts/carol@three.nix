# nix/tests/host-summary.nix の作り物 (dotfiles-private の nix/hosts/<user>@<hostname>.nix の形)。グループを minimum にし、
# 使う道具を 1 つずつ足したホスト (WSL で win/ を配る)
{ mkHome, ... }:
mkHome {
  username = "carol";
  system = "x86_64-linux";
  group = "minimum";
  wsl = {
    enable = true;
    windowsUserName = "carol";
    windowsFiles.enable = true;
    windowsFiles.ntn.enable = true;
  };
  claude = {
    enable = true;
    privateSkills.enable = true;
  };
  modules = [
    {
      dotfiles.ntn.enable = true;
    }
  ];
}
