# 設定グループ (dotfiles.group) と、段・道具の switch の既定を、lib/groups.nix の表と突き合わせて評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (groups-state) から呼ぶ。
#
# ## 確かめること
#
#   - 段の switch の既定: personal・グループを書かないホストは ② ③ とも true、company は ② だけ true、client はどちらも false
#   - 表の各道具の既定が、段の switch を素の値で 4 通り (② ③ の on/off) にしたホストで「その道具の段が全部 on && 段が全部
#     on のときの値」になる (derived = false の道具と ① の道具は、段によらず段が全部 on のときの値)。options.nix の既定の式と
#     表の段がずれたら、ここで落ちる
#   - 表の option が全部ホストの options.dotfiles にあり、bool の option
#   - グループを書かないホストと group = "personal" のホストで、表の全 option の値が同じ (personal は今までの既定のまま)
#   - group.json は version・group・tiers と、表の key を全部持つ tools で、改行で終わる。client では段のある道具が全部 false
#   - 客先で道具を 1 つ足せる (group = "client" と claude.enable = true で、claude だけが on)
#   - windowsClaudeAccounts (Windows の claude-personal・claude-work) は personal だけ既定で on (初回の apply で UAC の確認が出る
#     手順なので、company・client では既定で走らせない)
#   - windowsClaudeDesktop (Windows の Claude Desktop の MSIX) も ② と ③ の両方の道具で、personal だけ既定で on (入れるときに UAC の
#     確認が出る手順なので、company・client では既定で走らせない)
#   - opReasonSshRelay (op-reason の SSH の中継。Windows の runner と WSL の option が同じ名前で引く) は表にあり、どのグループでも
#     既定で off (鍵を使う ssh の通り道を替えるので、入れるホストが書く)
#   - windowsTypeClipboard (Windows の type-clipboard。自作のアプリで、個人の GitHub の repo の Release から入れる) は ③ の道具で、
#     既定は段によらず (derived = false)、どのグループでも off (入れるホストが書く)
#   - linger (systemd の linger。setup の手順 linger が有効にする) は ② の道具で、既定はどのグループでも herdrCore と同じ値。
#     herdrCore.enable = false のホストでは off。client で linger.enable = true だけを書けば、herdrCore は off のまま linger だけ on
#   - 依存の assertion: client で devTracker.enable = true だけを書くと評価で止まり、claude.privateSkills.enable と
#     claude.enable も書けば通る。herdr.hub.enable は herdr.enable と claude.privateSkills.enable が要る
#   - 知らないグループ ("customer") は評価で止まる
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  groups = import ../lib/groups.nix;

  hostWith =
    args:
    mkHome (
      {
        username = "tester";
        inherit system;
      }
      // args
    );
  cfgOf = args: (hostWith args).config;
  optionsOf = args: (hostWith args).options;

  valueOf = cfg: t: lib.getAttrFromPath t.option cfg.dotfiles;
  values = cfg: map (t: valueOf cfg t) groups.tools;

  # 段の switch を素の値で決めたホスト
  combos = [
    {
      aiTools = true;
      personalAccounts = true;
    }
    {
      aiTools = true;
      personalAccounts = false;
    }
    {
      aiTools = false;
      personalAccounts = true;
    }
    {
      aiTools = false;
      personalAccounts = false;
    }
  ];
  comboCfg =
    c:
    cfgOf {
      modules = [
        {
          dotfiles.aiTools.enable = c.aiTools;
          dotfiles.personalAccounts.enable = c.personalAccounts;
        }
      ];
    };
  allOn = comboCfg (builtins.head combos);
  expected =
    c: t: (if t.derived then builtins.all (tier: c.${tier}) t.tiers else true) && valueOf allOn t;
  mismatches = lib.concatMap (
    c:
    let
      cfg = comboCfg c;
    in
    map (t: "${t.key} (② ${lib.boolToString c.aiTools}・③ ${lib.boolToString c.personalAccounts})") (
      builtins.filter (t: valueOf cfg t != expected c t) groups.tools
    )
  ) combos;

  tiersOf = cfg: {
    a = cfg.dotfiles.aiTools.enable;
    p = cfg.dotfiles.personalAccounts.enable;
  };

  unset = cfgOf { };
  personal = cfgOf { group = "personal"; };
  company = cfgOf { group = "company"; };
  client = cfgOf { group = "client"; };

  json = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/group.json".text;
  jsonText = cfg: cfg.home.file.".local/state/dotfiles/group.json".text;

  clientClaude = cfgOf {
    group = "client";
    claude.enable = true;
  };

  # home-manager は assertion が落ちていると config を読んだ時点で throw する ("Failed assertions")
  evaluates = args: (builtins.tryEval (cfgOf args).home.username).success;

  missingOptions = builtins.filter (
    t:
    let
      o = lib.attrByPath t.option null (optionsOf { }).dotfiles;
    in
    !(lib.isOption o && o.type.name == "bool")
  ) groups.tools;

  cases = [
    {
      name = "personal・グループを書かないホストは ② ③ とも true";
      ok =
        tiersOf unset == {
          a = true;
          p = true;
        }
        && tiersOf personal == tiersOf unset;
    }
    {
      name = "company は ② だけ true";
      ok =
        tiersOf company == {
          a = true;
          p = false;
        };
    }
    {
      name = "client は ② ③ とも false";
      ok =
        tiersOf client == {
          a = false;
          p = false;
        };
    }
    {
      name =
        "表の各道具の既定が、段の 4 通りで「段が全部 on && 段が全部 on のときの値」になる"
        + lib.optionalString (mismatches != [ ]) " (ずれ: ${lib.concatStringsSep "・" mismatches})";
      ok = mismatches == [ ];
    }
    {
      name =
        "表の option が全部ホストにあり、bool"
        +
          lib.optionalString (missingOptions != [ ])
            " (無い・bool でない: ${lib.concatMapStringsSep "・" (t: t.key) missingOptions})";
      ok = missingOptions == [ ];
    }
    {
      name = "グループを書かないホストと group = \"personal\" で、表の全 option の値が同じ";
      ok = values unset == values personal;
    }
    {
      name = "group.json は version・group・tiers と表の key を全部持つ tools で、改行で終わる";
      ok =
        let
          j = json company;
        in
        j.version == 1
        && j.group == "company"
        &&
          j.tiers == {
            aiTools = true;
            personalAccounts = false;
          }
        && builtins.attrNames j.tools == lib.sort (a: b: a < b) (map (t: t.key) groups.tools)
        && lib.hasSuffix "\n" (jsonText company);
    }
    {
      name = "client の group.json では、段のある道具が全部 false";
      ok = builtins.all (t: t.tiers == [ ] || (json client).tools.${t.key} == false) groups.tools;
    }
    {
      name = "group = \"client\" と claude.enable = true で、段のある道具は claude だけが on";
      ok = builtins.all (
        t: t.tiers == [ ] || (json clientClaude).tools.${t.key} == (t.key == "claude")
      ) groups.tools;
    }
    {
      name = "windowsClaudeAccounts は personal だけ既定で on (UAC の確認が出る手順なので company・client は off)";
      ok =
        (json personal).tools.windowsClaudeAccounts
        && !(json company).tools.windowsClaudeAccounts
        && !(json client).tools.windowsClaudeAccounts;
    }
    {
      name = "windowsClaudeDesktop は ② と ③ の両方の道具で、personal だけ既定で on (UAC の確認が出る手順なので company・client は off)";
      ok =
        let
          t = builtins.head (builtins.filter (t: t.key == "windowsClaudeDesktop") groups.tools);
        in
        t.tiers == [
          "aiTools"
          "personalAccounts"
        ]
        && t.derived
        && (json unset).tools.windowsClaudeDesktop
        && (json personal).tools.windowsClaudeDesktop
        && !(json company).tools.windowsClaudeDesktop
        && !(json client).tools.windowsClaudeDesktop;
    }
    {
      name = "opReasonSshRelay は表にあり、どのグループでも既定で off (入れるホストが書く)";
      ok = builtins.all (cfg: (json cfg).tools ? opReasonSshRelay && !(json cfg).tools.opReasonSshRelay) [
        unset
        personal
        company
        client
      ];
    }
    {
      name = "windowsTypeClipboard は ③ の道具で、既定は段によらず、どのグループでも off (入れるホストが書く)";
      ok =
        let
          t = builtins.head (builtins.filter (t: t.key == "windowsTypeClipboard") groups.tools);
        in
        t.tiers == [ "personalAccounts" ]
        && !t.derived
        && builtins.all (cfg: !(json cfg).tools.windowsTypeClipboard) [
          unset
          personal
          company
          client
        ];
    }
    {
      name = "linger は ② の道具で、既定は herdrCore.enable に従う (herdrCore を false にすると off。linger だけ書くこともできる)";
      ok =
        let
          t = builtins.head (builtins.filter (t: t.key == "linger") groups.tools);
          noCore = cfgOf { modules = [ { dotfiles.herdrCore.enable = false; } ]; };
          clientLinger = cfgOf {
            group = "client";
            modules = [ { dotfiles.linger.enable = true; } ];
          };
        in
        t.tiers == [ "aiTools" ]
        && t.derived
        && builtins.all (cfg: (json cfg).tools.linger == (json cfg).tools.herdrCore) [
          unset
          personal
          company
          client
        ]
        && !(json noCore).tools.linger
        && (json clientLinger).tools.linger
        && !(json clientLinger).tools.herdrCore;
    }
    {
      name = "client で devTracker.enable = true だけを書くと評価で止まる";
      ok =
        !(evaluates {
          group = "client";
          claude.devTracker.enable = true;
        });
    }
    {
      name = "client でも claude.enable・claude.privateSkills.enable と書けば devTracker.enable = true が通る";
      ok = evaluates {
        group = "client";
        claude = {
          enable = true;
          privateSkills.enable = true;
          devTracker.enable = true;
          notion.profile = "work";
        };
      };
    }
    {
      name = "herdr.hub.enable は herdr.enable と claude.privateSkills.enable が要る";
      ok =
        !(evaluates {
          group = "company";
          modules = [ { dotfiles.herdr.hub.enable = true; } ];
        })
        && evaluates {
          group = "company";
          claude.privateSkills.enable = true;
          modules = [ { dotfiles.herdr.hub.enable = true; } ];
        }
        # personal (hub の既定は on) で herdr だけを外すと止まる
        && !(evaluates {
          modules = [ { dotfiles.herdr.enable = false; } ];
        });
    }
    {
      name = "知らないグループ (\"customer\") は評価で止まる";
      ok = !(builtins.tryEval (cfgOf { group = "customer"; }).dotfiles.group).success;
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "groups-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "groups-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
