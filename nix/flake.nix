{
  description = "pollenjp dotfiles managed by Nix home-manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      # nixpkgs と home-manager のリリース不一致は home-manager の最頻破壊要因なので
      # 必ず follows で揃える
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }@inputs:
    let
      inherit (nixpkgs) lib;

      # x86_64-darwin (Intel Mac) は含めない。
      # nixpkgs 26.11 でサポートが打ち切られており、評価時点で
      # "Nixpkgs 26.11 has dropped support for x86_64-darwin." で落ちる。
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

      mkHome = import ./lib/mk-home.nix { inherit inputs; };
    in
    {
      homeConfigurations = import ./hosts { inherit mkHome; };

      # `nix flake check` は homeConfigurations を評価しない (well-known output ではない)。
      # activationPackage を checks へ再エクスポートして初めて検証対象になる。
      # 各 system には、その system 向けの設定だけを載せる。
      checks = forAllSystems (
        system:
        lib.mapAttrs' (name: cfg: lib.nameValuePair "home-${name}" cfg.activationPackage) (
          lib.filterAttrs (_: cfg: cfg.pkgs.stdenv.hostPlatform.system == system) self.homeConfigurations
        )
      );

      # 初回ブートストラップ用。
      #
      # programs.home-manager.enable が CLI を profile へ入れるのは
      # **初回の activate が成功した後**なので、1 回目は home-manager コマンドが
      # まだ存在しない。そこで flake から直接実行できるようにしておく:
      #
      #   nix run ~/dotfiles/nix#home-manager -- switch --flake ~/dotfiles/nix#pollenjp@wsl
      #
      # `nix run home-manager` (レジストリ経由) ではなくこちらを使うこと。
      # レジストリ版は nixpkgs 同梱の別バージョンで、flake.lock で固定した
      # home-manager モジュールとバージョンがずれる可能性がある。
      # NOTE: rec の中では属性名 home-manager が input を影にするため、
      #       input 側は inputs. 経由で参照する。
      packages = forAllSystems (system: rec {
        home-manager = inputs.home-manager.packages.${system}.default;
        default = home-manager;
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.shfmt
              pkgs.shellcheck
              pkgs.nixfmt
              home-manager.packages.${system}.default
            ];
          };
        }
      );
    };
}
