# nix/tests/host-summary.nix の作り物 (dotfiles-private の nix/hosts/<user>@<hostname>.nix の形)。自社のグループを選び、
# ③ の道具を 1 つずつ足したホスト
{ mkHome, ... }:
mkHome {
  username = "carol";
  system = "x86_64-linux";
  group = "company";
  wsl = {
    enable = true;
    windowsUserName = "carol";
    windowsFiles.enable = true;
  };
  claude.privateSkills.enable = true;
  modules = [
    {
      dotfiles.ntn.enable = true;
    }
  ];
}
