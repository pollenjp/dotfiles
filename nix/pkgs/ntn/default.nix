# Notion の CLI (ntn)。nixpkgs に無いので、公式の配布物を版と system ごとの sha256 で固定して入れる。
#
# 配布物は https://ntn.dev/releases/v<版>/ntn-<target>.tar.gz で、sha256 は隣の .sha256 の値 (公式の install script
# `curl -fsSL https://ntn.dev | bash` が落として照らすものと同じ)。Linux は musl の静的な binary、macOS は署名済みの
# binary で、そのまま bin/ntn に置く (nix/pkgs/upstream/mise.nix と同じ形)。tar の中身は ntn と LICENSE.md (MIT)・
# README.md だけ。LICENSE.md は share/doc に写す。
#
# 補完 (bash / fish / zsh) は、install した ntn に `ntn completions <shell>` で出させる。clap の動的な補完で、TAB の
# たびに埋め込んだ $out/bin/ntn を呼ぶ。
#
# `ntn update` では上がらない (store の binary は書き換えられない)。版は依存の更新が上げる: version のすぐ上の
# `# release-source:` の行 (印) を読んで、公開から 7 日 (nix/release-age.nix の minimumReleaseAgeDays) たった版を選び、
# いつもの更新の PR で version と 3 つの sha256 を、それぞれの .sha256 と照らしてから書く。印の {version}・{target} は
# この derivation の version と、system ごとの塊の target。series=major は、0.x でも minor 上げ (0.23 → 0.24) を取る印。
# 印の行は文字列を変えない (依存の更新が読む形)。印が使えないとき・急ぐときに手で上げる手順は nix/README.md の
# 「ntn (Notion CLI) を Nix で入れる」。
{
  lib,
  stdenvNoCC,
  fetchurl,
  installShellFiles,
}:

let
  # release-source: latest=https://ntn.dev/latest.txt url=https://ntn.dev/releases/v{version}/ntn-{target}.tar.gz sha256={url}.sha256 series=major
  version = "0.23.25";
  # system → 配布物の target と、その .sha256 の値 (https://ntn.dev/releases/v<version>/ntn-<target>.tar.gz.sha256)
  assets = {
    x86_64-linux = {
      target = "x86_64-unknown-linux-musl";
      sha256 = "99faf81af403553b66d0f06a466ba6ba6b0e2708fb6b8f1eac2cf7ad1d5db47f";
    };
    aarch64-linux = {
      target = "aarch64-unknown-linux-musl";
      sha256 = "8379954cdb82a3c60866a18923da5f43a3358a6c8c698c085cc2905e7255a927";
    };
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      sha256 = "53196c36f98fbf94f56837dd5997872b51baf5226824c3cbd8cf7dc1f966ea5c";
    };
  };
  system = stdenvNoCC.hostPlatform.system;
  asset = assets.${system} or (throw "ntn ${version}: ${system} の配布物は無い");
in
stdenvNoCC.mkDerivation {
  pname = "ntn";
  inherit version;

  src = fetchurl {
    url = "https://ntn.dev/releases/v${version}/ntn-${asset.target}.tar.gz";
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

    install -Dm755 ntn $out/bin/ntn
    install -Dm644 LICENSE.md $out/share/doc/ntn/LICENSE.md
    # ntn は設定を ~/.config/notion から読むので、HOME を build の一時ディレクトリへ向けて打つ
    export HOME=$TMPDIR
    installShellCompletion --cmd ntn \
      --bash <($out/bin/ntn completions bash) \
      --fish <($out/bin/ntn completions fish) \
      --zsh <($out/bin/ntn completions zsh)

    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    actual=$(HOME=$TMPDIR $out/bin/ntn --version)
    echo "ntn --version: $actual"
    [[ $actual == "ntn ${version}" ]]

    runHook postInstallCheck
  '';

  meta = {
    description = "Notion CLI (ntn.dev の配布物の build 済みの binary)";
    homepage = "https://developers.notion.com/cli/get-started/overview";
    license = lib.licenses.mit;
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "ntn";
  };
}
