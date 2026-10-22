# nix/tests/private-hosts.nix の作り物 (dotfiles-private の nix/hosts/<user>@<hostname>.nix の形)
{ mkHome, ... }:
mkHome {
  username = "alice";
  system = "x86_64-linux";
  claude.notion.profile = "work";
  modules = [
    {
      dotfiles.ccPages.port = 7801;
      # このホストだけの上書き (shared/ の list とつながる)
      dotfiles.mise.releaseAgeOverrides = [
        {
          from = "2026-11-01";
          reason = "alice だけ";
        }
      ];
    }
  ];
}
