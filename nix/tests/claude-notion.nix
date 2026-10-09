# home/options.nix の dotfiles.claude.notion.{profile,routes,override} から作られる
# ~/.local/state/dotfiles/claude-notion.json の中身と warnings を、評価時に確かめる。
#
#   - 既定は {"override":{},"profile":null,"routes":{}}
#   - 値を入れると、そのまま JSON に入る (キーの意味は claude-skills の resolver が持つ)
#   - devTracker.enable (既定 true) で profile が null なら warnings が出る。routes や override
#     だけあっても出る (profile が無いと、規則に当たらない repo と repo の外で止まるため)
#   - profile があれば warnings は出ない。devTracker.enable = false なら profile が null でも出ない
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (claude-notion-state) から呼ぶ。
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  configWith =
    claude:
    (mkHome {
      username = "tester";
      inherit system claude;
    }).config;

  stateOf = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/claude-notion.json".text;
  warnsAboutProfile = cfg: builtins.any (lib.hasInfix "dotfiles.claude.notion.profile") cfg.warnings;

  byDefault = configWith { };
  filled = configWith {
    notion = {
      profile = "personal";
      routes = {
        "pollenjp/*" = "work";
      };
      override = {
        work = {
          devTracker.linkFromRepo = true;
        };
      };
    };
  };

  # profile を選ばないまま、routes か override だけを入れたマシン
  onlyRoutes = configWith {
    notion.routes = {
      "pollenjp/*" = "work";
    };
  };
  onlyOverride = configWith {
    notion.override = {
      work = {
        devTracker.linkFromRepo = true;
      };
    };
  };

  # Dev Tracker を使わないマシン (profile は null のまま)
  noTracker = configWith { devTracker.enable = false; };

  cases = [
    {
      name = "既定の JSON は profile が null、routes と override が空";
      ok =
        stateOf byDefault == {
          profile = null;
          routes = { };
          override = { };
        };
    }
    {
      name = "値を入れると profile・routes・override がそのまま入る";
      ok =
        stateOf filled == {
          profile = "personal";
          routes = {
            "pollenjp/*" = "work";
          };
          override = {
            work = {
              devTracker = {
                linkFromRepo = true;
              };
            };
          };
        };
    }
    {
      name = "profile が null なら warnings が出る";
      ok = warnsAboutProfile byDefault;
    }
    {
      name = "profile があれば warnings は出ない";
      ok = !(warnsAboutProfile filled);
    }
    {
      name = "profile が null なら、routes や override だけあっても warnings が出る";
      ok = warnsAboutProfile onlyRoutes && warnsAboutProfile onlyOverride;
    }
    {
      name = "devTracker.enable = false なら、profile が null でも warnings は出ない";
      ok = !(warnsAboutProfile noTracker);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "claude-notion-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "claude-notion-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
