{
  description = "plantuml skill の依存 (PlantUML + 日本語フォント)";

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

      packagesFor =
        pkgs:
        let
          # PlantUML は Java (AWT) で文字を組むので、フォントが無い環境では
          # 日本語が豆腐 (□□□) になる。
          #
          # **-static でなければならない。** noto-fonts-cjk-sans が配るのは可変
          # フォント NotoSansCJK-VF.otf.ttc で、OpenJDK はこれを描画できず豆腐に
          # なる。図の生成自体は成功しエラーも警告も出ないので気付きにくい。
          # -static は NotoSansCJK-Regular.ttc を持つので描ける。
          # drawio skill が可変フォントのままなのは Chromium にその制約が無いため。
          #
          # makeFontsConf は /usr/share/fonts などの実環境のフォントを残したまま
          # store のフォントを足すので、ホストの設定を奪わない。
          fontsConf = pkgs.makeFontsConf {
            fontDirectories = [
              pkgs.noto-fonts-cjk-sans-static # 日本語グリフ
              pkgs.dejavu_fonts # PlantUML が既定で使う欧文フォント
            ];
          };
        in
        rec {
          default = plantuml;

          # フォントを固定した plantuml。
          #
          # nixpkgs の plantuml は JDK と graphviz を抱えていて GRAPHVIZ_DOT まで
          # 設定済みなので、ここで足すのはフォントだけでよい。jar を落とす手順も
          # graphviz の apt install も要らない。
          plantuml = pkgs.symlinkJoin {
            name = "plantuml-with-fonts-${pkgs.plantuml.version}";
            paths = [ pkgs.plantuml ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram "$out/bin/plantuml" --set FONTCONFIG_FILE ${fontsConf}
            '';
            meta = pkgs.plantuml.meta // {
              mainProgram = "plantuml";
            };
          };
        };
    in
    {
      packages = forAllSystems (system: packagesFor nixpkgs.legacyPackages.${system});

      # scripts/*.sh は、PATH に道具が無ければここへ入り直す。
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          tools = packagesFor pkgs;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = [ tools.plantuml ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
