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

      # 登録簿に載せないマシン用の入口。
      #
      # flake は git の**追跡済みファイル**しか見ないので、リポジトリ内に
      # gitignore したホスト定義を置いても評価されない。代わりにリポジトリの外へ
      # 自分用の flake を置き、そこからこれを呼ぶ:
      #
      #   inputs.dotfiles.url = "git+file:///home/pollenjp/dotfiles?dir=nix";
      #   outputs = { dotfiles, ... }: {
      #     homeConfigurations."tmp" = dotfiles.lib.mkHome { ... };
      #   };
      #
      # 詳細は README 「登録簿に載せずにマシンを足す」を参照。
      lib = { inherit mkHome; };

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
      #   nix run ~/dotfiles#home-manager -- switch --flake ~/dotfiles#pollenjp@wsl
      #
      # `nix run home-manager` (レジストリ経由) ではなくこちらを使うこと。
      # レジストリ版は nixpkgs 同梱の別バージョンで、flake.lock で固定した
      # home-manager モジュールとバージョンがずれる可能性がある。
      # NOTE: rec の中では属性名 home-manager が input を影にするため、
      #       input 側は inputs. 経由で参照する。
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          home-manager = inputs.home-manager.packages.${system}.default;
          default = home-manager;

          # 閉包を SBOM 化して脆弱性データベース (OSV / GHSA / NVD) と照合する
          # 道具 (ADR 006)。flake-lock-age と同じく他のリポジトリからも呼べる:
          #
          #   nix run 'github:pollenjp/dotfiles?dir=nix#closure-scan' -- report
          #
          # sbomnix は焼き込まない。スキャナの版は「対象 flake の pin された
          # nixpkgs」から取る決めなので、script 側の nix shell --inputs-from に
          # 任せる (焼き込むと dotfiles の pin が他リポジトリにも効いてしまう)。
          closure-scan = pkgs.writeShellApplication {
            name = "closure-scan";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gawk
            ];
            text = builtins.readFile ./scripts/closure-scan.sh;
          };

          # flake.lock の pin を「公開から N 日以上経った revision」に限る道具。
          # 他のリポジトリからも呼べるように出している (dotfiles 専用ではない):
          #
          #   nix run 'github:pollenjp/dotfiles?dir=nix#flake-lock-age' -- check
          #
          # nix 自身は runtimeInputs に入れない。呼び出し側の nix
          # (Determinate 版など) をそのまま使わせる。
          flake-lock-age = pkgs.writeShellApplication {
            name = "flake-lock-age";
            # closure-scan を PATH へ入れるのは、store の app として update を
            # 叩いたときも完了時のスキャンを差し込めるようにするため
            # (チェックアウトから叩いたときは隣の closure-scan.sh を使う)。
            runtimeInputs = [
              pkgs.coreutils
              pkgs.curl
              pkgs.gnused
              pkgs.gnugrep
              closure-scan
            ];
            text = builtins.readFile ./scripts/flake-lock-age.sh;
          };
        }
      );

      # `nix run <flake>#<名前>` の入口。
      apps = forAllSystems (system: {
        flake-lock-age = {
          type = "app";
          program = "${self.packages.${system}.flake-lock-age}/bin/flake-lock-age";
          meta.description = "flake.lock の pin に最小経過日数を課す";
        };
        closure-scan = {
          type = "app";
          program = "${self.packages.${system}.closure-scan}/bin/closure-scan";
          meta.description = "閉包を SBOM 化して OSV / GHSA / NVD と照合する";
        };
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
