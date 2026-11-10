# home/options.nix の dotfiles.herdrCore.enable と、それが入れる herdr-core (home/modules/herdr-core.nix・pkgs/herdr-core) と、
# 版と sha256 の 1 か所 (pkgs/herdr-core/releases.json) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (herdr-core-state) から呼ぶ。package の build (公式の Linux 版を落として `hc --version` を照らす) は
# checks の herdr-core-test (Linux だけ)。
#
# ## 確かめること
#
#   - releases.json の形: app と core の版は X.Y.Z、generation は 1 以上の整数、sha256 は app の windows-x86_64 と、core の
#     linux-aarch64・linux-x86_64・windows-x86_64 の 4 つで、どれも 64 桁の小文字の hex (Install-HerdrApp.ps1 と CI も読む)
#   - Linux では既定で入る: home.packages に releases.json の core の版の herdr-core があり、~/.local/bin/herdr-core と hc が
#     その bin/herdr-core へのリンクで、前からあるファイルを置き換える (force)。リンクを張る前 (writeBoundary の後・linkGeneration
#     の前) に、前に写したふつうのファイルを消す activation がある (中身が同じだと home-manager は置き換えないため)
#   - Linux の package は、その system の公式の版つき URL (core/<版>/herdr-core-linux-<arch>.tar.gz) を、releases.json の
#     sha256 で落とす
#   - enable = false なら、package もリンクも置かない
#   - macOS では既定で入らない。enable = true にすると assertion で評価が止まる (公式の Linux 版しか入れない)。module の
#     assertion は Linux でだけ通り、message は Linux のホストだけと言う
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  releases = lib.importJSON ../pkgs/herdr-core/releases.json;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;

  configWith =
    modules:
    (mkHome {
      username = "tester";
      inherit system modules;
    }).config;

  herdrCores = cfg: builtins.filter (p: (p.pname or "") == "herdr-core") cfg.home.packages;
  link = cfg: name: cfg.home.file.".local/bin/${name}" or null;

  version = v: builtins.isString v && builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" v != null;
  hex = v: builtins.isString v && builtins.match "[0-9a-f]{64}" v != null;

  byDefault = configWith [ ];
  disabled = configWith [ { dotfiles.herdrCore.enable = false; } ];

  # module を直に読んだときの assertion (home-manager は落ちた assertion があると config を読む時点で throw するので、ここで見る)
  moduleAssertions =
    (import ../home/modules/herdr-core.nix {
      config.dotfiles.herdrCore.enable = true;
      inherit lib pkgs;
    }).config.content.assertions;

  shapeCases = [
    {
      name = "releases.json の app と core の版は X.Y.Z";
      ok = version releases.app.version && version releases.core.version;
    }
    {
      name = "releases.json の core の generation は 1 以上の整数";
      ok = builtins.isInt releases.core.generation && releases.core.generation >= 1;
    }
    {
      name = "module の assertion は Linux でだけ通り、message は Linux のホストだけと言う";
      ok = builtins.all (
        a: a.assertion == isLinux && lib.hasInfix "Linux のホストだけ" a.message
      ) moduleAssertions;
    }
    {
      name = "releases.json の sha256 は app の windows-x86_64 と core の 3 つの target で、どれも 64 桁の小文字の hex";
      ok =
        builtins.attrNames releases.app.sha256 == [ "windows-x86_64" ]
        &&
          builtins.attrNames releases.core.sha256 == [
            "linux-aarch64"
            "linux-x86_64"
            "windows-x86_64"
          ]
        && builtins.all hex (
          builtins.attrValues releases.app.sha256 ++ builtins.attrValues releases.core.sha256
        );
    }
  ];

  linuxCases =
    let
      pkg = builtins.head (herdrCores byDefault);
      bin = "${pkg}/bin/herdr-core";
      target = if system == "aarch64-linux" then "linux-aarch64" else "linux-x86_64";
      isLink =
        cfg: name:
        (link cfg name) != null && toString (link cfg name).source == bin && (link cfg name).force;
    in
    [
      {
        name = "Linux では既定で入る";
        ok = byDefault.dotfiles.herdrCore.enable;
      }
      {
        name = "home.packages に releases.json の core の版の herdr-core が 1 つある";
        ok = builtins.length (herdrCores byDefault) == 1 && pkg.version == releases.core.version;
      }
      {
        name = "~/.local/bin/herdr-core と hc は bin/herdr-core へのリンクで、前からあるファイルを置き換える (force)";
        ok = isLink byDefault "herdr-core" && isLink byDefault "hc";
      }
      {
        name = "リンクを張る前に、前に写したふつうのファイルを消す activation がある (writeBoundary の後・linkGeneration の前)";
        ok =
          let
            a = byDefault.home.activation.herdrCoreLinks or null;
          in
          a != null
          && a.after == [ "writeBoundary" ]
          && a.before == [ "linkGeneration" ]
          && lib.hasInfix ''run rm -f "$f"'' a.data
          && lib.hasInfix "! -L $f" a.data;
      }
      {
        name = "package は、この system の公式の版つき URL を releases.json の sha256 で落とす";
        ok =
          pkg.src.urls == [
            "https://releases.herdr.dev/core/${releases.core.version}/herdr-core-${target}.tar.gz"
          ]
          && pkg.src.outputHash == releases.core.sha256.${target};
      }
      {
        name = "enable = false なら、package もリンクも、消す activation も置かない";
        ok =
          herdrCores disabled == [ ]
          && link disabled "herdr-core" == null
          && link disabled "hc" == null
          && !(disabled.home.activation ? herdrCoreLinks);
      }
    ];

  darwinCases = [
    {
      name = "macOS では既定で入らない";
      ok = !byDefault.dotfiles.herdrCore.enable && herdrCores byDefault == [ ];
    }
    {
      # home-manager は落ちた assertion があると config を読む時点で throw する (Failed assertions)
      name = "macOS で enable = true にすると assertion で評価が止まる";
      ok =
        !(builtins.tryEval (configWith [ { dotfiles.herdrCore.enable = true; } ]).dotfiles.herdrCore.enable)
        .success;
    }
  ];

  cases = shapeCases ++ (if isLinux then linuxCases else darwinCases);

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "herdr-core-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "herdr-core-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
