# nix/tests/private-hosts.nix の作り物 (nix/shared/ の無い dotfiles-private の nix/hosts/<user>@<hostname>.nix)
{ mkHome, ... }:
mkHome {
  username = "carol";
  system = "x86_64-linux";
}
