# herdr-core (hc)。herdr-app の terminal と agent を持つ core で、herdr-app が SSH でつなぐ machine (server) の側にも要る
# (machine の terminal は remote の core が持つ。手元の core が SSH で remote の `herdr-core connect` を起動する)。
# Linux のホストへは home/modules/herdr-core.nix が入れ、Windows へは win/herdr-app/Install-HerdrApp.ps1 が入れる。
#
# nixpkgs の herdr-core は使わない (dotfiles の nixpkgs の固定にまだ無く、版も Windows の core とずれる)。公式の Linux 版
# (static-pie の単体の binary) を、Windows の core と同じ版で入れる。同じ版なら、Windows の herdr-app・hc が machine として
# つなぐときに写し直しを聞かれない。
#
# 版と sha256 は隣の releases.json (Windows の Install-HerdrApp.ps1 と CI の check-herdr-app-version.sh も読む 1 か所)。
# 配布物は https://releases.herdr.dev/core/<版>/herdr-core-<target>.tar.gz で、sha256 は公式の core/<版>/manifest.json の値と
# 同じ。tar の中身は最上位に herdr-core・LICENSE (Apache-2.0)・THIRD-PARTY-NOTICES だけ。bin/herdr-core と、その symlink の
# bin/hc を置く (公式の install.sh・`hc machine add --install` と同じ名前)。
#
# store に置いた core は、`hc update` が「nix のもの」として断る (実行ファイルの実体の置き場所に /nix/store/ を含む。herdr-core の
# client.rs の manager_of)。版は releases.json を上げる PR で、Windows と一緒に上げる (win/README.md の「固定した版を上げる」)。
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  releases = lib.importJSON ./releases.json;
  inherit (releases.core) version;
  # system → 配布物の target (releases.json の core.sha256 の名前。公式の manifest の targets の名前と同じ)
  targets = {
    x86_64-linux = "linux-x86_64";
    aarch64-linux = "linux-aarch64";
  };
  system = stdenvNoCC.hostPlatform.system;
  target = targets.${system} or (throw "herdr-core ${version}: ${system} には入れない (Linux だけ)");
in
stdenvNoCC.mkDerivation {
  pname = "herdr-core";
  inherit version;

  src = fetchurl {
    url = "https://releases.herdr.dev/core/${version}/herdr-core-${target}.tar.gz";
    sha256 = releases.core.sha256.${target};
  };

  # tar の中身はディレクトリを持たず最上位に並ぶので、展開した場所をそのまま使う
  sourceRoot = ".";

  # 静的リンク (static-pie) の binary を、そのまま置く
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 herdr-core $out/bin/herdr-core
    ln -s herdr-core $out/bin/hc
    install -Dm644 LICENSE $out/share/doc/herdr-core/LICENSE
    install -Dm644 THIRD-PARTY-NOTICES $out/share/doc/herdr-core/THIRD-PARTY-NOTICES

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    for name in herdr-core hc; do
      actual=$(HOME=$TMPDIR $out/bin/$name --version)
      echo "$name --version: $actual"
      [[ $actual == "hc ${version}" ]]
    done

    runHook postInstallCheck
  '';

  meta = {
    description = "herdr-core (hc): herdr-app の terminal と agent を持つ core (releases.herdr.dev の build 済みの binary)";
    homepage = "https://github.com/herdrdev/herdr-core";
    license = lib.licenses.asl20;
    platforms = builtins.attrNames targets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "hc";
  };
}
