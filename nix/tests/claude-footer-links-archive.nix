# files/claude/hooks/footer-links-archive.sh (Stop フックの入口) と footer-links-archive.mjs (本体) が ~/.claude/hooks/ に
# 置かれることを、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-footer-links-archive-state) から呼ぶ。振る舞いは footer-links-archive.test.mjs と
# footer-links-archive-gate.test.sh の側で見る。
#
# ## 確かめること
#
#   - 入口は ~/.claude/hooks/footer-links-archive.sh に、repo の script から実行できるファイルとして置かれる (option は無く、
#     どのホストにも置く。登録は bootstrap-claude-hook.sh)
#   - 本体は同じ dir の footer-links-archive.mjs に、repo のファイルから置かれる (入口は自分の dir の本体を起こす)
#   - home.packages に nodejs を足さない (hook は PATH の mise の node を使い、home の閉包に node を入れない)
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

  entry = cfg.home.file.".claude/hooks/footer-links-archive.sh" or null;
  body = cfg.home.file.".claude/hooks/footer-links-archive.mjs" or null;
  isNode = p: (p.pname or (builtins.parseDrvName (p.name or "")).name) == "nodejs";

  cases = [
    {
      name = "入口は ~/.claude/hooks/footer-links-archive.sh に、repo の script から実行できるファイルとして置かれる";
      ok =
        entry != null
        && entry.executable
        && "${entry.source}" == "${../files/claude/hooks/footer-links-archive.sh}";
    }
    {
      name = "本体は ~/.claude/hooks/footer-links-archive.mjs に、repo のファイルから置かれる";
      ok = body != null && "${body.source}" == "${../files/claude/hooks/footer-links-archive.mjs}";
    }
    {
      name = "home.packages に nodejs を足さない";
      ok = !builtins.any isNode cfg.home.packages;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-footer-links-archive-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-footer-links-archive-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
