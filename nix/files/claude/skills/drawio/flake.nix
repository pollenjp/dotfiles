{
  description = "drawio skill の依存 (エクスポート用 drawio + 日本語フォント + 公式 MCP サーバ)";

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
          # drawio のエクスポートは Electron (Chromium) のレンダリングを通るので、
          # SVG 出力であってもフォントが要る。これを渡さないと、ホストに日本語
          # フォントが無い環境 (CI, nix サンドボックス) で豆腐 (□□□) になる。
          #
          # makeFontsConf は /usr/share/fonts などの実環境のフォントを残したまま
          # store のフォントを足すので、ホストの設定を奪わない。
          #
          # NOTE: 可変フォント (NotoSansCJK-VF.otf.ttc) のままで描ける。
          #       plantuml skill が -static を使っているのは OpenJDK が可変
          #       フォントを描けないためで、Chromium にはその制約が無い。
          fontsConf = pkgs.makeFontsConf {
            fontDirectories = [
              pkgs.noto-fonts-cjk-sans # 日本語グリフ
              pkgs.liberation_ttf # drawio の既定フォント Helvetica の代替
            ];
          };
        in
        rec {
          default = drawio;

          # フォントを固定した drawio。
          #
          # nixpkgs の drawio-headless は使わない。あれは xvfb-run を内側に
          # 抱え込んでいて外せず、WSL2 (WSLg) では Xvfb が起動できないため
          # 何も出力せず exit 1 になる (理由は references/troubleshooting.md)。
          # ディスプレイの選択は scripts/drawio-export.sh 側で行う。
          drawio = pkgs.symlinkJoin {
            name = "drawio-with-fonts-${pkgs.drawio.version}";
            paths = [ pkgs.drawio ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram "$out/bin/drawio" --set FONTCONFIG_FILE ${fontsConf}
            '';
            meta = pkgs.drawio.meta // {
              mainProgram = "drawio";
            };
          };

          # 公式 MCP サーバ (@drawio/mcp)。図を draw.io エディタで開く道具で、
          # エクスポートには要らない。登録方法は references/mcp.md。
          #
          # npm の配布物には package-lock.json が入っていないので、lock を
          # 持っている GitHub リポジトリ側から固める。
          drawio-mcp = pkgs.buildNpmPackage (finalAttrs: {
            pname = "drawio-mcp";
            version = "1.5.0";

            src = pkgs.fetchFromGitHub {
              owner = "jgraph";
              repo = "drawio-mcp";
              # タグが打たれていないので rev で固定する。
              # mcp-tool-server/package.json の version が 1.5.0 のコミット。
              rev = "14b318b19cc37b159f841227b9d11fbd18ce18ea";
              hash = "sha256-n0UvgeDAYc8f8VneVa7/vjGNiHHSLTSvx3OZEijEc3c=";
            };
            sourceRoot = "${finalAttrs.src.name}/mcp-tool-server";

            npmDepsHash = "sha256-FACQmYYrzxyyeamwWCmgTU5D85HfCpkPg2q3TXIiyvM=";

            # build script は無い (npm run build を試みると落ちる)。
            dontNpmBuild = true;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            # package.json の copy-shared 相当。上流は pack 時に shared/ から
            # src/ へ複製している。
            postPatch = ''
              cp ../shared/xml-reference.md src/xml-reference.md
              cp ../shared/mermaid-reference.md src/mermaid-reference.md
              cp ../shared/shape-search.js src/shape-search.js
              cp ../shared/icon-search.js src/icon-search.js
            '';

            # npm pack は通さない (prepack が ../shared を触るため)。
            # src/index.js は ../../shared と ../../shape-search を参照し、
            # 無ければ CDN へ取りに行くので、リポジトリの相対配置を保って置く。
            installPhase = ''
              runHook preInstall

              root="$out/lib/drawio-mcp"
              mkdir -p "$root/mcp-tool-server"
              cp -r src vendor package.json node_modules "$root/mcp-tool-server/"
              cp -r ../shared ../shape-search "$root/"

              makeWrapper ${lib.getExe pkgs.nodejs} "$out/bin/drawio-mcp" \
                --add-flags "$root/mcp-tool-server/src/index.js"

              runHook postInstall
            '';

            meta = {
              description = "Official draw.io MCP server (opens diagrams in the draw.io editor)";
              homepage = "https://github.com/jgraph/drawio-mcp";
              license = lib.licenses.asl20;
              mainProgram = "drawio-mcp";
              platforms = lib.platforms.all;
            };
          });
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
            packages = [
              tools.drawio
              tools.drawio-mcp
            ]
            # 実ディスプレイが無い環境 (CI, 素の headless サーバ) 用の仮想
            # ディスプレイ。macOS では不要かつ存在しない。
            ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.xvfb-run;
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
