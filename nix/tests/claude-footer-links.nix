# home/modules/claude.nix が作る ~/.local/state/dotfiles/claude-footer-links.json (settings.json の
# footerLinksRegexes に写す値) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-footer-links-state) から呼ぶ。正規表現の当たり方は
# claude-footer-links.test.mjs (claude-footer-links-test) の側で見る。
#
# ## 確かめること
#
#   - 中身は files/claude/footer-links.json の @ccPagesPort@ を cc-pages の port で埋めたもので、
#     @ccPagesPort@ は残らない
#   - cc-page の規則は 1 つで、url と pattern が http://localhost:<port>/p/ を指す。port は既定 (null) で
#     cc-pages の既定の 7777、dotfiles.ccPages.port を書くとその値
#   - port を変えると cc-page の規則だけが変わり、チケットと PR の規則は変わらない
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

  text = cfg: cfg.home.file.".local/state/dotfiles/claude-footer-links.json".text;
  rules = cfg: builtins.fromJSON (text cfg);
  isCcPage = rule: lib.hasPrefix "http://localhost:" rule.url;
  ccPageRules = cfg: builtins.filter isCcPage (rules cfg);
  otherRules = cfg: builtins.filter (rule: !isCcPage rule) (rules cfg);

  # cc-page の規則が 1 つだけで、url と pattern がその port の http://localhost:<port>/p/ を指す
  pointsTo =
    port: cfg:
    let
      found = ccPageRules cfg;
      origin = "http://localhost:${toString port}/p/";
    in
    builtins.length found == 1
    && lib.hasPrefix origin (builtins.head found).url
    && lib.hasPrefix origin (builtins.head found).pattern;

  byDefault = configWith [ ];
  port7780 = withPort 7780;

  cases = [
    {
      name = "@ccPagesPort@ は残らない";
      ok = builtins.all (cfg: !lib.hasInfix "@ccPagesPort@" (text cfg)) [
        byDefault
        port7780
      ];
    }
    {
      name = "既定 (null) では cc-page の規則が cc-pages の既定の http://localhost:7777/p/ を指す";
      ok = pointsTo 7777 byDefault;
    }
    {
      name = "dotfiles.ccPages.port を書くと cc-page の規則がその port を指す";
      ok = pointsTo 7780 port7780;
    }
    {
      name = "port を変えると cc-page の規則だけが変わり、チケットと PR の規則は変わらない";
      ok =
        ccPageRules byDefault != ccPageRules port7780
        && otherRules byDefault == otherRules port7780
        && otherRules byDefault != [ ];
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-footer-links-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-footer-links-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
