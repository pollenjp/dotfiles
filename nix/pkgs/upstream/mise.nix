# nixpkgs の猶予の例外 (一部・upstream から。nix/release-age.nix の exceptions.fromUpstream) で入れる mise (ADR 032)。
#
# jdx/mise の GitHub の release にある build 済みの binary (Linux は静的リンクの musl 版) と補完を、GitHub が asset
# ごとに出す digest (sha256) で固定して取る。中身は公式の installer (mise.run) が入れるものと同じ配布物で、信頼の
# 置き場所は jdx/mise の GitHub の release (tar.xz の digest は、release の SHASUMS256.txt の値とも同じ)。
#
# nixpkgs の mise (pkgs/by-name/mi/mise) と同じく、bin/mise・man・bash/fish/zsh の補完と、self-update を止める印
# (lib/mise/.disable-self-update) を置く。nixpkgs の build がしているテストは無く、install の後に --version だけを見る。
# tar.xz の share/fish/vendor_conf.d/mise-activate.fish は入れない (activate は home-manager の programs.mise がする。
# 入れると fish で 2 回になる)。2026.10.17 の補完は `mise __complete_word__` を直に呼ぶので、nixpkgs の版のような
# usage の差し替えは要らない。
#
# 版を上げる・消すときは nix/release-age.nix の項目と合わせる (version が違うと評価で止まる)。
{
  lib,
  stdenvNoCC,
  fetchurl,
  installShellFiles,
}:

let
  version = "2026.10.17";
  release = "https://github.com/jdx/mise/releases/download/v${version}";
  # system → release の tar.xz と、その digest (gh api repos/jdx/mise/releases/tags/v<version> の assets[].digest)
  assets = {
    x86_64-linux = {
      name = "linux-x64-musl";
      sha256 = "da0d9ace5d5b3321e391f15fbf8b53fcd65b9024e673ea51c5515189e5810416";
    };
    aarch64-linux = {
      name = "linux-arm64-musl";
      sha256 = "566e04044756bfb5bf2ddd4d3d16172f5f4979e02d88cef7fbac726f9f59cf5f";
    };
    aarch64-darwin = {
      name = "macos-arm64";
      sha256 = "8eb476e56f680a9347ce29346768d84174f631a37e0317759e2e2a565830ca5d";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset = assets.${system} or (throw "mise ${version}: ${system} の配布物は無い");
  completion =
    shell: sha256:
    fetchurl {
      url = "${release}/mise.${shell}";
      inherit sha256;
    };
in
stdenvNoCC.mkDerivation {
  pname = "mise";
  inherit version;

  src = fetchurl {
    url = "${release}/mise-v${version}-${asset.name}.tar.xz";
    inherit (asset) sha256;
  };

  nativeBuildInputs = [ installShellFiles ];

  # 静的リンク (Linux) と署名済み (macOS) の binary を、そのまま置く
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/mise $out/bin/mise
    installManPage man/man1/mise.1
    installShellCompletion --cmd mise \
      --bash ${completion "bash" "b2ef33deebe8ffd9e09c395474f2ab0be6ae7d0457399d3f7907ab12d070c33d"} \
      --fish ${completion "fish" "b25af38db9a3f5159edc2337f1790e792b63970e52a5a609b5378ffe4e2d61f8"} \
      --zsh ${completion "zsh" "ad713c3e5198f658a725ecd53f61d587488319586944d844c591148435477b0f"}
    mkdir -p $out/lib/mise
    touch $out/lib/mise/.disable-self-update

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    actual=$(HOME=$TMPDIR $out/bin/mise --version)
    echo "mise --version: $actual"
    [[ $actual == "${version} "* ]]

    runHook postInstallCheck
  '';

  meta = {
    description = "Front-end to your dev env (jdx/mise の release の build 済みの binary)";
    homepage = "https://mise.jdx.dev";
    changelog = "https://github.com/jdx/mise/releases/tag/v${version}";
    license = lib.licenses.mit;
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "mise";
  };
}
