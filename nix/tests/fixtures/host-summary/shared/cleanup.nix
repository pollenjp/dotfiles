# nix/tests/host-summary.nix の作り物 (dotfiles-private の nix/shared/*.nix の形。登録した全ホストに足す module)。
# 要約が、ここで決めた値を「dotfiles-private の nix/shared/」と出すかを見る
{
  dotfiles.cleanup.enable = false;
}
