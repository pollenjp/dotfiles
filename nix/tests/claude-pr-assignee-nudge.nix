# files/claude/hooks/pr-assignee-nudge.sh が ~/.claude/hooks/ に置かれることを、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-pr-assignee-nudge-state) から呼ぶ。
#
# ## 確かめること
#
#   - hook は ~/.claude/hooks/pr-assignee-nudge.sh に、repo の script から実行できるファイルとして置かれる (option は
#     無く、どのホストにも置く。登録は bootstrap-claude-hook.sh)
#   - hook が名指しする skill pjp-gh-pr-create も ~/.claude/skills/ に置かれる (skill が無いと hook は黙る)
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

  hook = cfg.home.file.".claude/hooks/pr-assignee-nudge.sh" or null;
  skill = cfg.home.file.".claude/skills/pjp-gh-pr-create" or null;

  cases = [
    {
      name = "hook は ~/.claude/hooks/pr-assignee-nudge.sh に置かれる";
      ok = hook != null;
    }
    {
      name = "hook は repo の script から、実行できるファイルとして置かれる";
      ok =
        hook != null
        && hook.executable
        && "${hook.source}" == "${../files/claude/hooks/pr-assignee-nudge.sh}";
    }
    {
      name = "skill pjp-gh-pr-create は ~/.claude/skills/pjp-gh-pr-create に置かれる";
      ok = skill != null && "${skill.source}" == "${../files/claude/skills/pjp-gh-pr-create}";
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-pr-assignee-nudge-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-pr-assignee-nudge-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
