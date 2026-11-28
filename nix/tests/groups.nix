# 設定グループ (dotfiles.group。道具の集合) と道具の switch の既定を、lib/groups.nix の表と突き合わせて評価時に確かめる
# (dotfiles-private の docs/adr/109_host_groups_minimum_all_*)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、CI の
# `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。flake.nix の checks (groups-state) から呼ぶ。
#
# ## 確かめること
#
#   - 表の各道具の既定が、環境の組 5 つ (WSL で win/ を配る・WSL で win/ を配らない・WSL で Windows のユーザー名を書かない・WSL でない
#     Linux・macOS) と 2 つのグループのどれでも「グループに入る && 全部の環境の条件 && 全部の効く条件の値」になる (従う道具 (follows) は、
#     従う先の道具の値)。options.nix の既定の式と表がずれたら、ここで落ちる
#   - all を選んだホストは、5 つの組のどれでも世代の derivation (activationPackage の drvPath) まで評価できる (グループの既定から
#     来た値で assertion が起きず、その system に無い package も入らない)
#   - minimum で on の道具は minimum に入る道具 (osCaBundle・cleanup) だけ
#   - 表の option が全部ホストの options.dotfiles にあり、bool の option
#   - グループを書かないホストと group = "minimum" のホストで、表の全 option の値が同じ
#   - group.json は version 2・group・表の key を全部持つ tools だけで、改行で終わる (段の tiers は無い)
#   - 道具を 1 つ足せる (group = "minimum" と claude.enable = true で、claude だけが minimum の外で on)
#   - linger は herdrCore に従う: minimum に herdrCore だけを足すと linger も on、all で herdrCore を外すと off。linger だけを書くこともできる
#   - 依存の assertion は今のまま: minimum で devTracker.enable = true だけを書くと評価で止まり、claude.enable と claude.privateSkills.enable
#     も書けば通る。herdr.hub.enable は herdr.enable と claude.privateSkills.enable が要る (all で herdr だけを外すと止まる)
#   - ホストが素の値で書いた環境の誤り (WSL でないのに wsl.exeExecTrace.enable = true) は、今までどおり評価で止まる
#   - やめたグループの名前 (personal・company・client)・知らないグループ ("customer")・やめた段の switch (aiTools.enable・
#     personalAccounts.enable) は評価で止まる
#   - runnerTools は全部が表の道具か runner だけの道具 (runnerOnlyTools) で、表の runner の印と runner だけの道具の数の和 (18)
#   - runner の groups.json (lib.windowsGroups) は、表の道具と runner だけの道具 (privateRepos) を持つ。privateRepos は minimum で false、
#     all で true。group.json の tools には入らない (上の「表の key を全部持つ tools だけ」。Linux の世代を変えない)
#   - groups.json は version 3 で、runner の止める条件 (requires) は claudePrivateSkills・opReasonSshRelay が privateRepos、herdrHub が
#     windowsClaudeCode・windowsHerdr (並びは名前の順)。わけ (requiresWhy) は同じ組を持ち、文が空でない。privateRepos に頼る道具に herdrHub は
#     無い。止める条件の道具と要る道具は全部 runnerTools にある
#   - herdrHub の runner の側の依存は Linux の既定を変えない: all の Linux のホストで herdr.hub.enable は on、minimum では off (Nix の
#     requires は持たない)
#   - groups.json の skills は、ハブと子の土台の skill 3 つ (pjp-hc-child・pjp-hc-hub・pjp-hc-hub-panel) と hc の pack の入口 (pjp-pack-hc)
#     が Windows は herdrHub、Linux は herdrCore。表の windows の key は runnerTools に、linux の key は表 (tools) にある。linuxSkillOn は herdrCore の値に従い、表に無い
#     skill はいつも true
{
  lib,
  pkgs,
  mkHome,
  system,
  windowsGroups,
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
  toolNamed = key: builtins.head (builtins.filter (t: t.key == key) groups.tools);

  # 環境の組 (グループのほかは書かない)。system はどの組も書く (WSL と Linux の組は x86_64-linux。check の system が macOS でも、
  # WSL の組を macOS で組まない)。system が違う組も評価だけなら、どの system のランナーでも流せる
  envs = {
    wsl-win = {
      system = "x86_64-linux";
      wsl = {
        enable = true;
        windowsUserName = "user";
        windowsFiles.enable = true;
      };
    };
    wsl-runner = {
      system = "x86_64-linux";
      wsl = {
        enable = true;
        windowsUserName = "user";
      };
    };
    wsl-nouser = {
      system = "x86_64-linux";
      wsl.enable = true;
    };
    linux = {
      system = "x86_64-linux";
    };
    darwin = {
      system = "aarch64-darwin";
    };
  };

  # 表から決まる既定: グループに入る && 全部の環境の条件 && 全部の効く条件の値 (従う道具は従う先の値)
  expected =
    group: cfg: isLinux: t:
    if t.follows != null then
      valueOf cfg (toolNamed t.follows)
    else
      groups.inGroup group t
      && builtins.all (groups.envHolds {
        cfg = cfg.dotfiles;
        inherit isLinux;
      }) t.env
      && builtins.all (p: lib.getAttrFromPath p cfg.dotfiles) t.requires;

  combos = lib.concatMap (
    envName:
    map (group: {
      inherit envName group;
      args = envs.${envName} // {
        inherit group;
      };
    }) groups.groupNames
  ) (builtins.attrNames envs);

  mismatches = lib.concatMap (
    c:
    let
      h = hostWith c.args;
      isLinux = lib.hasSuffix "-linux" (c.args.system or system);
    in
    map (t: "${t.key} (${c.group}・${c.envName})") (
      builtins.filter (t: valueOf h.config t != expected c.group h.config isLinux t) groups.tools
    )
  ) combos;

  # home-manager は assertion が落ちていると config を読んだ時点で throw する ("Failed assertions")
  evaluates = args: (builtins.tryEval (cfgOf args).home.username).success;
  throwsOn = v: !(builtins.tryEval (builtins.deepSeq v true)).success;

  # 世代の derivation まで評価できるか (assertion のほか、その system に無い package の誤りも見る。build はしない)
  drvEvaluates =
    args: (builtins.tryEval (builtins.seq (hostWith args).activationPackage.drvPath true)).success;

  allStops = builtins.filter (n: !(drvEvaluates (envs.${n} // { group = "all"; }))) (
    builtins.attrNames envs
  );

  unset = cfgOf { };
  minimum = cfgOf { group = "minimum"; };
  all = cfgOf { group = "all"; };

  json = cfg: builtins.fromJSON cfg.home.file.".local/state/dotfiles/group.json".text;
  jsonText = cfg: cfg.home.file.".local/state/dotfiles/group.json".text;

  onIn = cfg: map (t: t.key) (builtins.filter (t: valueOf cfg t) groups.tools);
  minimumKeys = map (t: t.key) (builtins.filter (t: t.minimum) groups.tools);

  missingOptions = builtins.filter (
    t:
    let
      o = lib.attrByPath t.option null (optionsOf { }).dotfiles;
    in
    !(lib.isOption o && o.type.name == "bool")
  ) groups.tools;

  cases = [
    {
      name =
        "表の各道具の既定が、環境の組 5 つと 2 つのグループで「グループに入る && 環境の条件 && 効く条件」になる"
        + lib.optionalString (mismatches != [ ]) " (ずれ: ${lib.concatStringsSep "・" mismatches})";
      ok = mismatches == [ ];
    }
    {
      name =
        "all を選んだホストは、環境の組 5 つのどれでも世代の derivation まで評価できる"
        + lib.optionalString (allStops != [ ]) " (止まる組: ${lib.concatStringsSep "・" allStops})";
      ok = allStops == [ ];
    }
    {
      name = "minimum で on の道具は minimum に入る道具 (osCaBundle・cleanup) だけ";
      ok =
        onIn minimum == minimumKeys
        &&
          minimumKeys == [
            "osCaBundle"
            "cleanup"
          ];
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
      name = "グループを書かないホストと group = \"minimum\" で、グループは minimum、表の全 option の値が同じ";
      ok = unset.dotfiles.group == "minimum" && values unset == values minimum;
    }
    {
      name = "group.json は version 2・group・表の key を全部持つ tools だけで、改行で終わる";
      ok =
        let
          j = json all;
        in
        builtins.attrNames j == [
          "group"
          "tools"
          "version"
        ]
        && j.version == 2
        && j.group == "all"
        && builtins.attrNames j.tools == lib.sort (a: b: a < b) (map (t: t.key) groups.tools)
        && lib.hasSuffix "\n" (jsonText all);
    }
    {
      name = "group = \"minimum\" と claude.enable = true で、minimum の外の道具は claude だけが on";
      ok =
        onIn (cfgOf {
          group = "minimum";
          claude.enable = true;
        }) == minimumKeys ++ [ "claude" ];
    }
    {
      name = "linger は herdrCore に従う (minimum に herdrCore を足すと on、all で herdrCore を外すと off、linger だけも書ける)";
      ok =
        let
          # herdr-core は Linux のホストだけ (macOS で on にすると assertion で止まる)。評価だけなので、どの system の check でも Linux で組む
          coreOnly = cfgOf {
            system = "x86_64-linux";
            group = "minimum";
            modules = [ { dotfiles.herdrCore.enable = true; } ];
          };
          allNoCore = cfgOf {
            system = "x86_64-linux";
            group = "all";
            modules = [ { dotfiles.herdrCore.enable = false; } ];
          };
          lingerOnly = cfgOf {
            system = "x86_64-linux";
            group = "minimum";
            modules = [ { dotfiles.linger.enable = true; } ];
          };
        in
        (toolNamed "linger").follows == "herdrCore"
        && !minimum.dotfiles.linger.enable
        && coreOnly.dotfiles.linger.enable
        && !allNoCore.dotfiles.linger.enable
        && lingerOnly.dotfiles.linger.enable
        && !lingerOnly.dotfiles.herdrCore.enable;
    }
    {
      name = "minimum で devTracker.enable = true だけを書くと評価で止まる";
      ok =
        !(evaluates {
          group = "minimum";
          claude.devTracker.enable = true;
        });
    }
    {
      name = "minimum でも claude.enable・claude.privateSkills.enable と書けば devTracker.enable = true が通る";
      ok = evaluates {
        group = "minimum";
        claude = {
          enable = true;
          privateSkills.enable = true;
          devTracker.enable = true;
          notion.profile = "work";
        };
      };
    }
    {
      name = "herdr.hub.enable は herdr.enable と claude.privateSkills.enable が要る (all で herdr だけを外すと止まる)";
      ok =
        !(evaluates {
          group = "minimum";
          modules = [ { dotfiles.herdr.hub.enable = true; } ];
        })
        && evaluates {
          group = "minimum";
          claude = {
            enable = true;
            privateSkills.enable = true;
          };
          modules = [
            {
              dotfiles.herdr.enable = true;
              dotfiles.herdr.hub.enable = true;
            }
          ];
        }
        && !(evaluates {
          group = "all";
          modules = [ { dotfiles.herdr.enable = false; } ];
        });
    }
    {
      name = "ホストが素の値で書いた環境の誤り (WSL でないのに exeExecTrace) は、今までどおり評価で止まる";
      ok = !(evaluates { wsl.exeExecTrace.enable = true; });
    }
    {
      name = "やめたグループ (personal・company・client)・知らないグループ・やめた段の switch は評価で止まる";
      ok =
        builtins.all (g: throwsOn (cfgOf { group = g; }).dotfiles.group) [
          "personal"
          "company"
          "client"
          "customer"
        ]
        && !(evaluates {
          modules = [ { dotfiles.aiTools.enable = true; } ];
        })
        && !(evaluates {
          modules = [ { dotfiles.personalAccounts.enable = false; } ];
        });
    }
    {
      name = "runnerTools は全部が表の道具か runner だけの道具で、表の runner の印と runner だけの道具の数の和 (18)";
      ok =
        builtins.all (
          k: builtins.any (t: t.key == k) (groups.tools ++ groups.runnerOnlyTools)
        ) groups.runnerTools
        &&
          builtins.length (builtins.filter (t: t.runner) groups.tools)
          + builtins.length groups.runnerOnlyTools == builtins.length groups.runnerTools
        && builtins.length groups.runnerTools == 18
        && builtins.all (r: builtins.elem r.key groups.runnerTools) groups.runnerOnlyTools
        && builtins.all (r: !(builtins.any (t: t.key == r.key) groups.tools)) groups.runnerOnlyTools;
    }
    {
      name = "runner の groups.json は表の道具と privateRepos を持ち、privateRepos は minimum で false・all で true (group.json には入らない)";
      ok =
        let
          keys = lib.sort (a: b: a < b) (map (t: t.key) (groups.tools ++ groups.runnerOnlyTools));
        in
        builtins.attrNames windowsGroups.groups.minimum.tools == keys
        && builtins.attrNames windowsGroups.groups.all.tools == keys
        && windowsGroups.groups.minimum.tools.privateRepos == false
        && windowsGroups.groups.all.tools.privateRepos
        && !((json all).tools ? privateRepos);
    }
    {
      name = "groups.json は version 3 で、runner の止める条件 (requires) とそのわけ (requiresWhy) を持ち、privateRepos に頼る道具に herdrHub は無い";
      ok =
        windowsGroups.version == 3
        &&
          windowsGroups.requires == {
            claudePrivateSkills = [ "privateRepos" ];
            herdrHub = [
              "windowsClaudeCode"
              "windowsHerdr"
            ];
            opReasonSshRelay = [ "privateRepos" ];
          }
        && lib.mapAttrs (_: builtins.attrNames) windowsGroups.requiresWhy == windowsGroups.requires
        && builtins.all (
          deps: builtins.all (why: builtins.isString why && why != "") (builtins.attrValues deps)
        ) (builtins.attrValues windowsGroups.requiresWhy)
        && !(builtins.elem "herdrHub" (
          builtins.attrNames
            (builtins.head (builtins.filter (r: r.key == "privateRepos") groups.runnerOnlyTools)).requiredBy
        ))
        && builtins.all (k: builtins.elem k groups.runnerTools) (
          builtins.attrNames windowsGroups.requires
          ++ lib.concatLists (builtins.attrValues windowsGroups.requires)
        );
    }
    {
      name = "herdrHub の runner の側の依存は Linux の既定を変えない (all の Linux で herdr.hub.enable は on、minimum では off)";
      ok =
        (toolNamed "herdrHub").requires == [ ]
        && (cfgOf {
          system = "x86_64-linux";
          group = "all";
        }).dotfiles.herdr.hub.enable
        && !(cfgOf {
          system = "x86_64-linux";
          group = "minimum";
        }).dotfiles.herdr.hub.enable;
    }
    {
      name = "groups.json の skills は土台の skill 3 つと hc の pack の入口が Windows は herdrHub・Linux は herdrCore で、key は表にあり、linuxSkillOn は herdrCore に従う";
      ok =
        let
          hubAndChild = {
            linux = [ "herdrCore" ];
            windows = [ "herdrHub" ];
          };
          core = cfgOf {
            system = "x86_64-linux";
            group = "minimum";
            modules = [ { dotfiles.herdrCore.enable = true; } ];
          };
        in
        windowsGroups.skills == {
          pjp-hc-child = hubAndChild;
          pjp-hc-hub = hubAndChild;
          pjp-hc-hub-panel = hubAndChild;
          pjp-pack-hc = hubAndChild;
        }
        && builtins.all (s: builtins.all (k: builtins.elem k groups.runnerTools) s.windows) (
          builtins.attrValues groups.skills
        )
        && builtins.all (s: builtins.all (k: builtins.any (t: t.key == k) groups.tools) s.linux) (
          builtins.attrValues groups.skills
        )
        && groups.linuxSkillOn core.dotfiles "pjp-hc-hub"
        && !(groups.linuxSkillOn minimum.dotfiles "pjp-hc-hub")
        && groups.linuxSkillOn minimum.dotfiles "pjp-nix-flake";
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
