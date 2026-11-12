# home/modules/claude.nix が ~/.claude/statusline-command.sh に置く status line の script を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-statusline-state) から呼ぶ。出力の形 (📄top を出す・出さない) は
# statusline-command.test.sh (statusline-command-test) の側で見る。
#
# ## 確かめること
#
#   - files/claude/statusline-command.sh の @ccPagesPort@ を cc-pages の port で埋めたものを、実行できるファイルとして置き、
#     @ccPagesPort@ は残らない
#   - 📄top の URL は、既定 (null) で cc-pages の既定の http://localhost:7777/s/ を、dotfiles.ccPages.port を書くとその port の
#     /s/ を指す (footer の cc-page の規則と同じ port)
#   - port のほかは repo の script と同じ
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

  file = cfg: cfg.home.file.".claude/statusline-command.sh";
  footerRules =
    cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/claude-footer-links.json".text;
  ccPageRuleUrl =
    cfg: (lib.findFirst (rule: lib.hasPrefix "http://localhost:" rule.url) null (footerRules cfg)).url;

  byDefault = configWith [ ];
  port7780 = configWith [ { dotfiles.ccPages.port = 7780; } ];
  source = builtins.readFile ../files/claude/statusline-command.sh;

  cases = [
    {
      name = "@ccPagesPort@ を埋めて、実行できるファイルとして置く";
      ok = builtins.all (cfg: (file cfg).executable && !lib.hasInfix "@ccPagesPort@" (file cfg).text) [
        byDefault
        port7780
      ];
    }
    {
      name = "既定 (null) では 📄top が cc-pages の既定の http://localhost:7777/s/ を指す";
      ok = lib.hasInfix "http://localhost:7777/s/" (file byDefault).text;
    }
    {
      name = "dotfiles.ccPages.port を書くと、その port の /s/ を指し、footer の cc-page の規則と同じ port になる";
      ok =
        lib.hasInfix "http://localhost:7780/s/" (file port7780).text
        && !lib.hasInfix "localhost:7777" (file port7780).text
        && lib.hasPrefix "http://localhost:7780/" (ccPageRuleUrl port7780);
    }
    {
      name = "port のほかは repo の script と同じ";
      ok =
        lib.hasInfix "@ccPagesPort@" source
        && (file byDefault).text == builtins.replaceStrings [ "@ccPagesPort@" ] [ "7777" ] source;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-statusline-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-statusline-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
