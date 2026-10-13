{
  description = "pjp-d3js skill の依存 (node + d3・Observable Plot・linkedom + resvg + 日本語フォント)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  # この skill は store へコピーされる (read-only) ので、flake.lock は必ず
  # 一緒に commit する。lock が無いと nix がその場で書こうとして失敗する。
  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # dotfiles/nix/flake.nix と同じ範囲。
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = lib.genAttrs systems;

      packagesFor = pkgs: rec {
        default = node-modules;

        # d3・Observable Plot・linkedom の node_modules。
        #
        # package-lock.json の integrity で 1 つずつ取るので npmDepsHash を持たない。
        # 版を上げるときは lock を作り直すだけでよい (SKILL.md の「版」)。
        #
        # skill のディレクトリは store へコピーされて読み取り専用になるので、
        # node_modules を skill の中に作ることはできない。scripts/lib/render.mjs が
        # PJP_D3JS_NODE_MODULES (下の devShell が渡す) からここを読む。
        node-modules = pkgs.importNpmLock.buildNodeModules {
          # package.json と package-lock.json だけを渡す。skill のディレクトリごと
          # 渡すと、SKILL.md を直しただけで作り直しになる。
          npmRoot = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./package.json
              ./package-lock.json
            ];
          };
          inherit (pkgs) nodejs;
        };
      };
    in
    {
      packages = forAllSystems (system: packagesFor nixpkgs.legacyPackages.${system});

      # scripts/*.sh は、PJP_D3JS_NODE_MODULES が無ければここへ入り直す。
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          tools = packagesFor pkgs;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.nodejs
              # SVG -> PNG (目で確かめる用)。Chromium を起こすより軽い。
              pkgs.resvg
            ];

            # chart module の "d3" などを解決する先 (scripts/lib/render.mjs)。
            PJP_D3JS_NODE_MODULES = "${tools.node-modules}/node_modules";

            # resvg に渡す日本語フォント。resvg は fontconfig を読まないので、
            # ディレクトリを --use-fonts-dir で直に渡す。可変フォント
            # (NotoSansCJK-VF) のままで太字も描ける (2026-10-12 に確かめた)。
            PJP_D3JS_FONTS_DIR = "${pkgs.noto-fonts-cjk-sans}/share/fonts";
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
