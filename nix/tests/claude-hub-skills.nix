# modules/claude.nix が置く、ハブと子の土台の skill (lib/groups.nix の skills の表にある skill。dotfiles-private の ADR 124) を確かめる。
# flake.nix の checks (claude-hub-skills) から呼ぶ。
#
# ## 確かめること
#
#   評価時 (assert。CI の `nix flake check --all-systems --no-build` でも落ちる)
#     - 表の skill は全部 nix/files/claude/skills/<名前>/SKILL.md にある
#     - claude-skills を使わないホスト (claude.privateSkills.enable = false) で hc が入る (herdrCore) なら、表の skill を全部
#       ~/.claude/skills/<名前> に張り、claude-base-skills.tsv は書かない
#     - herdrCore が off なら (macOS の既定も)、表の skill は張らない。表に無い skill (pjp-nix-flake) は、どの組でも張る
#     - claude-skills を使うホストでは、表の skill を ~/.claude/skills/ に張らず、~/.local/state/dotfiles/claude-base-skills.tsv に
#       「名前<TAB>store のパス」の行を名前の順で書く (パスは名前で終わる store のパス。bootstrap-claude-skills.sh が、claude-skills に
#       同じ名前が無ければ張る)。herdrCore が off なら表は空 (前に張った土台のリンクを、bootstrap-claude-skills.sh が外す)
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  groups = import ../lib/groups.nix;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  names = builtins.attrNames groups.skills;

  configWith =
    {
      privateSkills,
      herdrCore,
    }:
    (mkHome {
      username = "tester";
      inherit system;
      group = "minimum";
      claude = {
        enable = true;
        privateSkills.enable = privateSkills;
      };
      modules = [ { dotfiles.herdrCore.enable = herdrCore; } ];
    }).config;

  files = cfg: cfg.home.file;
  linked = cfg: name: (files cfg) ? ".claude/skills/${name}";
  tsv = cfg: (files cfg).".local/state/dotfiles/claude-base-skills.tsv".text or null;

  missing = builtins.filter (
    n: !(builtins.pathExists (../files/claude/skills + "/${n}/SKILL.md"))
  ) names;

  publicCore = configWith {
    privateSkills = false;
    herdrCore = true;
  };
  publicNoCore = configWith {
    privateSkills = false;
    herdrCore = false;
  };
  privateCore = configWith {
    privateSkills = true;
    herdrCore = true;
  };
  privateNoCore = configWith {
    privateSkills = true;
    herdrCore = false;
  };

  rows = lib.splitString "\n" (lib.removeSuffix "\n" (tsv privateCore));
  rowOk =
    name: row:
    let
      cols = lib.splitString "\t" row;
    in
    builtins.length cols == 2
    && builtins.elemAt cols 0 == name
    && lib.hasPrefix builtins.storeDir (builtins.elemAt cols 1)
    && lib.hasSuffix "-${name}" (builtins.elemAt cols 1);

  cases = [
    {
      name =
        "表の skill は全部 nix/files/claude/skills/<名前>/SKILL.md にある"
        + lib.optionalString (missing != [ ]) " (無い: ${lib.concatStringsSep "・" missing})";
      ok = missing == [ ];
    }
    {
      name = "claude-skills を使わず hc が入るホストは、表の skill を全部張り、claude-base-skills.tsv を書かない";
      ok = !isLinux || (builtins.all (linked publicCore) names && tsv publicCore == null);
    }
    {
      name = "herdrCore が off なら表の skill は張らず、表に無い skill はどの組でも張る";
      ok =
        !(builtins.any (linked publicNoCore) names)
        && builtins.all (cfg: linked cfg "pjp-nix-flake") [
          publicCore
          publicNoCore
          privateCore
          privateNoCore
        ];
    }
    {
      name = "claude-skills を使うホストは、表の skill を張らずに claude-base-skills.tsv に名前と store のパスを名前の順で書く";
      ok =
        !(builtins.any (linked privateCore) names)
        && (
          !isLinux
          || (
            builtins.length rows == builtins.length names
            && builtins.all (x: x) (lib.zipListsWith rowOk names rows)
          )
        );
    }
    {
      name = "claude-skills を使い herdrCore が off のホストは、claude-base-skills.tsv が空";
      ok = tsv privateNoCore == "" && !(builtins.any (linked privateNoCore) names);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-hub-skills: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-hub-skills" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
