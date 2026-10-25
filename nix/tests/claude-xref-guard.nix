# files/claude/hooks/xref-guard.sh が ~/.claude/hooks/ に置かれることを、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-xref-guard-state) から呼ぶ。
#
# ## 確かめること
#
#   - hook は ~/.claude/hooks/xref-guard.sh に、repo の script から実行できるファイルとして置かれる (option は無く、
#     どのホストにも置く。登録は bootstrap-claude-hook.sh)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  cfg =
    (mkHome {
      username = "tester";
      inherit system;
    }).config;

  hook = cfg.home.file.".claude/hooks/xref-guard.sh" or null;

  cases = [
    {
      name = "hook は ~/.claude/hooks/xref-guard.sh に置かれる";
      ok = hook != null;
    }
    {
      name = "hook は repo の script から、実行できるファイルとして置かれる";
      ok =
        hook != null && hook.executable && "${hook.source}" == "${../files/claude/hooks/xref-guard.sh}";
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-xref-guard-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-xref-guard-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
