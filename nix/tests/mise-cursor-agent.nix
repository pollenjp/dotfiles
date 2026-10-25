# mise の cursor-agent (Cursor の CLI) の宣言 (nix/files/mise/conf.d/cursor-agent.toml。home/modules/files.nix が
# ~/.config/mise/conf.d/cursor-agent.toml に置く) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (mise-cursor-agent-state) から呼ぶ。
#
# ## 確かめること
#
#   - home は ~/.config/mise/conf.d/cursor-agent.toml に repo のファイルを置く
#   - ファイルは TOML として読め、tools.cursor-agent には version (latest)・bin_path (bin)・postinstall だけがある
#     (registry と変えたいところだけで、url などの registry の値は書き写さない)
#   - postinstall は文字列で、bin/cursor-agent に ../dist-package/cursor-agent を張る。表の形
#     ({ run = …, when = "always" }) は mise 2026.10.0 からで、読めない mise では conf.d ごと読めず mise 全体が止まる
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  file = ../files/mise/conf.d/cursor-agent.toml;
  home =
    (mkHome {
      username = "tester";
      inherit system;
    }).config;
  placed = home.xdg.configFile."mise/conf.d/cursor-agent.toml" or null;
  tool = (builtins.fromTOML (builtins.readFile file)).tools.cursor-agent;

  cases = [
    {
      name = "home は ~/.config/mise/conf.d/cursor-agent.toml に repo のファイルを置く";
      ok = placed != null && toString placed.source == toString file;
    }
    {
      name = "tools.cursor-agent には version・bin_path・postinstall だけがある (registry の値は書き写さない)";
      ok =
        builtins.attrNames tool == [
          "bin_path"
          "postinstall"
          "version"
        ];
    }
    {
      name = "version は latest、bin_path は bin";
      ok = tool.version == "latest" && tool.bin_path == "bin";
    }
    {
      name = "postinstall は文字列で、bin/cursor-agent に ../dist-package/cursor-agent を張る (表の形は mise 2026.10.0 から)";
      ok =
        builtins.isString tool.postinstall
        && lib.hasInfix "ln -sfn ../dist-package/cursor-agent" tool.postinstall
        && lib.hasInfix "$MISE_TOOL_INSTALL_PATH/bin/cursor-agent" tool.postinstall;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "mise-cursor-agent-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "mise-cursor-agent-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
