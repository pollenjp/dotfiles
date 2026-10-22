# nix/tests/private-hosts.nix の作り物 (dotfiles-private の nix/shared/*.nix の形。登録した全ホストに足す home-manager の module)
{
  dotfiles.mise.releaseAgeOverrides = [
    {
      from = "2026-10-22";
      zeroDays = 3;
      reason = "全ホスト";
    }
  ];
}
