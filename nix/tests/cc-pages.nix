# home/options.nix の dotfiles.ccPages.port から作られるもの (home/modules/cc-pages.nix) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (cc-pages-state) から呼ぶ。
#
# ## 確かめること
#
#   - 既定 (null) では ~/.config/cc-pages/config.toml を置かない (手で書いた config.toml とぶつからない)
#   - port を書くと、config.toml の addr が 127.0.0.1:<port> になる (daemon も cc-pages new もこれを読む)
#   - 1〜65535 の外は評価で止まる (0 だと cc-pages は空いている port を選び、返すリンクが合わない)
#   - port を変えると cc-pages.service の unit ファイルが変わる。home-manager の switch (sd-switch) は
#     unit ファイルが変わった service だけを再起動するので、daemon が新しい port で上がり直す。
#     unit ファイルは Linux でしか作られないので、この項目は Linux だけ
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    modules:
    (mkHome {
      username = "tester";
      inherit system modules;
    }).config;
  withPort = port: configWith [ { dotfiles.ccPages.port = port; } ];

  configToml = ".config/cc-pages/config.toml";
  unitOf = cfg: "${cfg.xdg.configFile."systemd/user/cc-pages.service".source}";
  rejects = port: !(builtins.tryEval (withPort port).dotfiles.ccPages.port).success;

  byDefault = configWith [ ];
  port7778 = withPort 7778;

  cases = [
    {
      name = "既定では ~/.config/cc-pages/config.toml を置かない";
      ok = !(builtins.hasAttr configToml byDefault.home.file);
    }
    {
      name = "port を書くと config.toml の addr が 127.0.0.1:<port> になる";
      ok =
        builtins.fromTOML (port7778.home.file.${configToml}.text or "") == { addr = "127.0.0.1:7778"; };
    }
    {
      name = "1〜65535 の外は評価で止まる";
      ok = rejects 0 && rejects 65536;
    }
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    {
      name = "port を変えると cc-pages.service の unit ファイルが変わる (switch で再起動される)";
      ok = unitOf port7778 != unitOf (withPort 7779);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "cc-pages-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "cc-pages-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
