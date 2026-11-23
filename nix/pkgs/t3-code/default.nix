# T3 Code の CLI (t3) の runtime。nixpkgs に無いので、公式の配布物 (GitHub の release の t3-<版>-linux-<arch>.tar.gz) を、版と
# system ごとの sha256 で固定して取る。home/modules/t3-code.nix が、これを t3 の公式の installer と同じ置き場所
# (~/.t3/runtime/versions/<版>/) へ写す。
#
# store に置いたまま起こさないのは、t3 の service の launcher (`t3 __service-launcher`) が `~/.t3/runtime/versions/<activeVersion>/t3 serve`
# を起こし、unit の ExecStart も同じ場所を指す作りだから (t3 0.1.11 の bootService.ts・pinnedRuntime)。置き場所を変えると、t3 が service を
# 「current でない」と読んで `t3 up`・`t3 connect` が unit を書き換える。
#
# 配布物は 1 本の dir (t3-<版>-linux-<arch>/) で、中身は t3 (Bun で 1 本にまとめた実行ファイル)・client/・lib/ (libatomic)・node_modules/
# (native の addon を含む)・resource-monitor/。公式の installer が置く runtime と同じ中身 (0.1.11 で比べた。違いは installer が足す
# .install-complete だけ)。patchelf も strip もしない (実行ファイルの後ろの中身を書き換えると壊れうる。公式も手を入れない)。そのため
# ELF の interpreter は /lib64/ld-linux-x86-64.so.2 のままで、NixOS では nix-ld (programs.nix-ld.enable) が要る。
#
# sha256 は GitHub の release の asset の digest (gh api repos/pingdotgg/t3code/releases/tags/v<版> の .assets[].digest) と同じ。版の上げ方は
# nix/README.md の「T3 Code」(Windows の win/t3-code/Install-T3Code.ps1 の -Version と揃える)。
{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
  version = "0.1.11";
  # system → 配布物の arch と、その sha256
  assets = {
    x86_64-linux = {
      arch = "x64";
      sha256 = "2b691c07f5bcb5adea4a863d5324aae7db21bd6d82280cec7787836dcaa013e1";
    };
    aarch64-linux = {
      arch = "arm64";
      sha256 = "7d90a5af032fe0988a616403e0f51a6cb68eff7ed7a84bc40999cc3997dffd71";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset = assets.${system} or (throw "t3-code ${version}: ${system} の配布物は無い (Linux だけ)");
in
stdenvNoCC.mkDerivation {
  pname = "t3-code";
  inherit version;

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/t3-${version}-linux-${asset.arch}.tar.gz";
    inherit (asset) sha256;
  };

  sourceRoot = "t3-${version}-linux-${asset.arch}";

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontPatchShebangs = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/t3-code
    cp -R . $out/share/t3-code/runtime

    runHook postInstall
  '';

  # 起こしては確かめない (build の sandbox には /lib64 の loader が無い)。runtime の形 (実行できる t3 と、t3 が読む dir) だけを見る
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    r=$out/share/t3-code/runtime
    [[ -f $r/t3 && -x $r/t3 ]]
    for d in client lib node_modules resource-monitor; do
      [[ -d $r/$d ]]
    done
    [[ -f $r/client/index.html ]]
    [[ ! -e $r/.install-complete ]]
    echo "t3-code ${version}: runtime の形を確かめた ($r)"

    runHook postInstallCheck
  '';

  passthru = {
    # store の中の runtime の dir (home/modules/t3-code.nix が ~/.t3/runtime/versions/<版>/ へ写す元)
    runtimeSubdir = "share/t3-code/runtime";
  };

  meta = {
    description = "T3 Code の CLI と server の runtime (pingdotgg/t3code の公式の配布物)";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "t3";
  };
}
