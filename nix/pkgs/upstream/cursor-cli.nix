# nixpkgs の猶予の例外 (一部・upstream から。nix/release-age.nix の exceptions.fromUpstream) で入れる cursor-cli (ADR 032)。
#
# Cursor が downloads.cursor.com で配る build 済みの配布物 (agent-cli-package.tar.gz) を sha256 で固定して取る。中身は
# 公式のインストーラ (cursor.com/install) が入れるものと同じ配布物。hash は Homebrew の cask (Casks/c/cursor-cli.rb) が
# 2026.10.22-27dcf5f に上げた commit (5815fd3) の値で、同じ方法で取った 2026.10.01 の値は、nixpkgs の cursor-cli が
# 自分で取った hash と 3 つとも同じだった。
#
# 組み方は nixpkgs の cursor-cli (pkgs/by-name/cu/cursor-cli) と同じ (Linux は autoPatchelf。share/cursor-agent に置き、
# bin/cursor-agent を張る)。version は nixpkgs と同じ形 (0-unstable-<日付>) にし、nixpkgs の版が追いついたら消し時の
# 警告が出るようにする。unfree なので、home の nixpkgs.config.allowUnfreePackages (modules/packages.nix) で許す
# (lib/release-age.nix は upstream の package を home の pkgs で組む)。
#
# この例外は eMudhra の中間 CA の侵害 (CVE-2026-111943) の対応。cursor-cli は同梱の node で TLS を張り、node は自前の
# 証明書の束を持つ (OS の束を直しても変わらない)。install の後に同梱の node の版を見て、修正の入った版 (22.23.4・
# 24.22.1・26.12.1 以上。2026-10-21 公開) でなければ build を止める。
#
# 版を上げる・消すときは nix/release-age.nix の項目と合わせる (version が違うと評価で止まる)。
{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
}:

let
  release = "2026.10.22-27dcf5f";
  version = "0-unstable-2026-10-22";
  # system → 配布物の <os>/<arch> と sha256 (Homebrew の cask の x86_64_linux・arm64_linux・arm)
  assets = {
    x86_64-linux = {
      path = "linux/x64";
      sha256 = "85296944e4600a83c4b764f578d1502bf9c416db200d33a593e8f3ecabfdc294";
    };
    aarch64-linux = {
      path = "linux/arm64";
      sha256 = "22a36df9720830668ccd4d707e5190204ab9c8a0efb2f068cc914895f804d3ec";
    };
    aarch64-darwin = {
      path = "darwin/arm64";
      sha256 = "2f5b0a3dd5fb951cecffac813867d8a08d810e59837d59fd5f12d69b922398d7";
    };
  };
  system = stdenv.hostPlatform.system;
  asset = assets.${system} or (throw "cursor-cli ${release}: ${system} の配布物は無い");
in
stdenv.mkDerivation {
  pname = "cursor-cli";
  inherit version;

  src = fetchurl {
    url = "https://downloads.cursor.com/lab/${release}/${asset.path}/agent-cli-package.tar.gz";
    inherit (asset) sha256;
  };

  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    zlib
  ];

  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
    stdenv.cc.cc.lib
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/cursor-agent
    cp -r * $out/share/cursor-agent/
    ln -s $out/share/cursor-agent/cursor-agent $out/bin/cursor-agent

    runHook postInstall
  '';

  # 同梱の node が eMudhra の修正の入った版か (launcher の cursor-agent は、隣の node で動く)
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    node=$out/share/cursor-agent/node
    if [[ ! -x $node ]]; then
      echo "同梱の node が無い: $node" >&2
      exit 1
    fi
    actual=$($node --version)
    echo "同梱の node: $actual"
    v=''${actual#v}
    major=''${v%%.*}
    case $major in
      22) min=22.23.4 ;;
      24) min=24.22.1 ;;
      26) min=26.12.1 ;;
      *) if ((major > 26)); then min=$v; else min=""; fi ;;
    esac
    # min <= v なら、この 2 行は版の順に並んでいる (sort -C は並んでいれば 0)
    if [[ -z $min ]] || ! printf '%s\n' "$min" "$v" | sort -C -V; then
      echo "同梱の node $actual は、eMudhra の修正の入った版 (22.23.4・24.22.1・26.12.1 以上) ではない" >&2
      exit 1
    fi

    runHook postInstallCheck
  '';

  meta = {
    description = "Cursor CLI (downloads.cursor.com の build 済みの配布物 ${release})";
    homepage = "https://cursor.com/cli";
    license = lib.licenses.unfree;
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "cursor-agent";
  };
}
