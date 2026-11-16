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
#
# ## 立てたシェルに固有の env を外す包み
#
# bin/herdr-core (と、それへの symlink の bin/hc) は、本物 (libexec/herdr-core/herdr-core) を起こす前に、hc の子に写したくない
# env (starterVars) を外す包み (makeWrapper) にする。hc の core は、立てた hc の process の env を写して動き (Linux では systemd
# の user の transient unit。hc --skill の「Programs get the login session's environment」)、hc の子は core の env で起きるので、
# core を立てたシェルに固有の値が、立て直すまで全部の子に付く。入口で外せば、どこから core が立っても漏れない。
#
#   herdrPaneVars      旧 herdr (TUI) の pane の印。herdr の pane で打った最初の hc (WSL を立ち上げ直した後の hc ls や、pane の
#                      中の hc server restart --fresh) から core が立つと、HERDR_ENV=1 などが hc の子に漏れ、旧 herdr を相手に
#                      する道具 (dotfiles の hook・claude-skills の ticket.sh) が古い herdr を呼ぶ (claude-skills の spec の §1
#                      「漏れていたもの」)
#   misePerDirVars     mise が対話のシェルの cwd ごとに入れる値のうち、子の repo の固定より勝つもの。RUSTUP_TOOLCHAIN は mise の
#                      全体の rust (bootstrap-mise.sh) が入れ、rustup はそれを repo の rust-toolchain.toml より上に置くので、対話の
#                      シェルから立てた core の子が claude-skills の worktree で cargo を打つと、CI と違う版で動く
#
# hc は HERDR_RELEASES_URL (Windows の取得元のフィード) などの HERDR_* も読むので、prefix でまとめず名前で外す。本物の実体は store の
# 中のままなので、`hc update` は今までどおり断り、`hc machine add --install` が写す「今の build」(本物の exe) と、core が自分を起こし
# 直すときの exe も本物のまま。名前で振る舞いは変わらない (どの名前で起こしても hc の CLI) が、argv[0] は包みに渡された名前を継ぐ。
# mise の go の GOROOT や Claude Code の会話の CLAUDECODE なども対話のシェル・会話に固有だが、ここでは外さない (core は login の環境で
# 立て直す。nix/README.md の「hc の core の env と hc の子の PATH」)。
{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
}:

let
  releases = lib.importJSON ./releases.json;
  inherit (releases.core) version;
  # 旧 herdr (TUI) が pane に入れる env。claude-skills の spec §7.4 の 6 (pjp child new が子の claude から外すもの) と、
  # herdr の session の名前 (HERDR_SESSION)・pane を開いた dir (HERDR_STARTUP_CWD。herdr 0.9.5 の pane が持つ)
  herdrPaneVars = [
    "HERDR_ENV"
    "HERDR_PANE_ID"
    "HERDR_TAB_ID"
    "HERDR_WORKSPACE_ID"
    "HERDR_SOCKET_PATH"
    "HERDR_BIN_PATH"
    "HERDR_SESSION"
    "HERDR_STARTUP_CWD"
  ];
  # mise が対話のシェルに入れ、子の repo の固定 (rust-toolchain.toml) より勝つ値 (冒頭の「立てたシェルに固有の env を外す包み」)
  misePerDirVars = [ "RUSTUP_TOOLCHAIN" ];
  starterVars = herdrPaneVars ++ misePerDirVars;
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

  nativeBuildInputs = [ makeWrapper ];

  # 静的リンク (static-pie) の binary を、そのまま置く
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 herdr-core $out/libexec/herdr-core/herdr-core
    makeWrapper $out/libexec/herdr-core/herdr-core $out/bin/herdr-core --inherit-argv0 \
      ${lib.concatMapStringsSep " " (v: "--unset ${v}") starterVars}
    ln -s herdr-core $out/bin/hc
    install -Dm644 LICENSE $out/share/doc/herdr-core/LICENSE
    install -Dm644 THIRD-PARTY-NOTICES $out/share/doc/herdr-core/THIRD-PARTY-NOTICES

    runHook postInstall
  '';

  # 版を照らし、包みが starterVars を外して本物を起こし、ほかの env (hc が読む HERDR_RELEASES_URL も) を残すことを確かめる。
  # env を見るのは、本物の代わりに env を出す script を起こす同じ形の包み (本物は env を出す口を持たないので、包みの起こす先だけを
  # 差し替えて見る。coreutils の env は argv[0] で振る舞いを決める 1 つの binary なので、包みが argv[0] を継ぐと起きない。script を挟む)
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    for name in herdr-core hc; do
      actual=$(HOME=$TMPDIR $out/bin/$name --version)
      echo "$name --version: $actual"
      [[ $actual == "hc ${version}" ]]
    done

    printf '#!%s\nexec env\n' "$(command -v bash)" >"$TMPDIR/print-env"
    chmod +x "$TMPDIR/print-env"
    sed "s|$out/libexec/herdr-core/herdr-core|$TMPDIR/print-env|" $out/bin/herdr-core >"$TMPDIR/env-wrapper"
    chmod +x "$TMPDIR/env-wrapper"
    got=$(env ${
      lib.concatMapStringsSep " " (v: "${v}=leaked") starterVars
    } HC_KEEP=kept HERDR_RELEASES_URL=kept "$TMPDIR/env-wrapper")
    for v in ${lib.concatStringsSep " " starterVars}; do
      if [[ $'\n'"$got"$'\n' == *$'\n'"$v="* ]]; then
        echo "包みが $v を外していない" >&2
        exit 1
      fi
    done
    for kept in HC_KEEP HERDR_RELEASES_URL; do
      if [[ $'\n'"$got"$'\n' != *$'\n'"$kept=kept"$'\n'* ]]; then
        echo "包みが $kept まで外した" >&2
        exit 1
      fi
    done
    echo "包みは ${lib.concatStringsSep "・" starterVars} を外し、ほかの env (HERDR_RELEASES_URL も) は残す"

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
