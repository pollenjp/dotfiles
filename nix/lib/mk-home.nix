# homeConfiguration を組み立てるヘルパ。
# hosts/default.nix から 1 マシン 1 行で呼ぶ。
{ inputs }:

{
  username,
  system,
  # macOS だけ home の親ディレクトリが異なる
  homeDirectory ?
    if inputs.nixpkgs.lib.hasSuffix "darwin" system then "/Users/${username}" else "/home/${username}",
  isWSL ? false,
  modules ? [ ],
}:

inputs.home-manager.lib.homeManagerConfiguration {
  pkgs = inputs.nixpkgs.legacyPackages.${system};
  extraSpecialArgs = { inherit inputs; };
  modules = [
    ../home
    {
      home = { inherit username homeDirectory; };
      dotfiles.isWSL = isWSL;
    }
  ]
  ++ modules;
}
