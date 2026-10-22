# home/options.nix の dotfiles.mise.{minimumReleaseAge,releaseAgeOverrides} と、そこから作られる
# ~/.local/state/dotfiles/mise-release-age.json (home/modules/mise-release-age.nix) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (mise-release-age-state) から呼ぶ。
#
# ## 確かめること
#
#   - minimumReleaseAge の既定は "9d"、releaseAgeOverrides の既定は空のリスト。mise-release-age.json は
#     {"minimumReleaseAge": <値>, "releaseAgeOverrides": [<項目>]} で、改行で終わる。nix/scripts/bootstrap-mise.sh がこれを読む
#   - 項目は from だけ書けば、zeroDays は 1、reason は "" で JSON に入る。JSON の項目の欄は from・zeroDays・reason の 3 つ
#   - 2 つの module (dotfiles-private の nix/shared/ とホストのファイルなど) に書いた list はつながる
#     (順は module system が決めるので見ない。bootstrap-mise.sh は順に依らない)
#   - 書式は評価で止まる: from は暦にある YYYY-MM-DD (形の違う 2026-1-2・無い日の 2026-02-30・閏年でない 2025-02-29・
#     13 月と 0 月は止まり、閏年の 2024-02-29 は通る)。from は省けない。zeroDays は 1 以上。minimumReleaseAge は
#     日の単位 (<数>d) だけ。知らない欄 (until など) は止まる
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
  withOverrides = items: configWith [ { dotfiles.mise.releaseAgeOverrides = items; } ];

  state = cfg: cfg.home.file.".local/state/dotfiles/mise-release-age.json".text;
  json = cfg: builtins.fromJSON (state cfg);
  # 評価で止まるか。型の誤りは、値を読んだとき (JSON を作るとき) に throw になる
  rejects = cfg: !(builtins.tryEval (state cfg)).success;

  a = {
    from = "2026-10-22";
    zeroDays = 3;
    reason = "修正版を入れる";
  };
  b = {
    from = "2026-11-01";
    zeroDays = 1;
    reason = "このホストだけ";
  };

  byDefault = configWith [ ];

  cases = [
    {
      name = "minimumReleaseAge の既定は 9d、releaseAgeOverrides の既定は空のリスト";
      ok =
        byDefault.dotfiles.mise.minimumReleaseAge == "9d"
        && byDefault.dotfiles.mise.releaseAgeOverrides == [ ];
    }
    {
      name = "既定の mise-release-age.json は minimumReleaseAge が 9d・releaseAgeOverrides が空で、改行で終わる";
      ok =
        json byDefault == {
          minimumReleaseAge = "9d";
          releaseAgeOverrides = [ ];
        }
        && lib.hasSuffix "\n" (state byDefault);
    }
    {
      name = "from だけの項目は zeroDays = 1・reason = \"\" で JSON に入る";
      ok =
        (json (withOverrides [ { from = "2026-10-22"; } ])).releaseAgeOverrides == [
          {
            from = "2026-10-22";
            zeroDays = 1;
            reason = "";
          }
        ];
    }
    {
      name = "3 つの欄を書いた項目はそのまま入り、minimumReleaseAge も JSON に入る";
      ok =
        json (configWith [
          {
            dotfiles.mise = {
              minimumReleaseAge = "14d";
              releaseAgeOverrides = [ a ];
            };
          }
        ]) == {
          minimumReleaseAge = "14d";
          releaseAgeOverrides = [ a ];
        };
    }
    {
      # 順は module system が決める (後ろの module の定義が先に来る)。bootstrap-mise.sh は順に依らない
      name = "2 つの module に書いた list はつながる (両方の項目が 1 つずつ入る)";
      ok =
        let
          items =
            (json (configWith [
              { dotfiles.mise.releaseAgeOverrides = [ a ]; }
              { dotfiles.mise.releaseAgeOverrides = [ b ]; }
            ])).releaseAgeOverrides;
        in
        builtins.length items == 2 && builtins.elem a items && builtins.elem b items;
    }
    {
      name = "閏年の 2024-02-29 は通る";
      ok = !(rejects (withOverrides [ { from = "2024-02-29"; } ]));
    }
    {
      name = "from が暦にある YYYY-MM-DD でなければ評価で止まる (2026-1-2・2026-02-30・2025-02-29・2026-13-01・2026-00-10)";
      ok =
        builtins.all
          (
            from:
            rejects (withOverrides [
              { inherit from; }
            ])
          )
          [
            "2026-1-2"
            "2026-02-30"
            "2025-02-29"
            "2026-13-01"
            "2026-00-10"
          ];
    }
    {
      name = "from の無い項目は評価で止まる";
      ok = rejects (withOverrides [ { zeroDays = 3; } ]);
    }
    {
      name = "zeroDays が 0 なら評価で止まる";
      ok = rejects (withOverrides [
        {
          from = "2026-10-22";
          zeroDays = 0;
        }
      ]);
    }
    {
      name = "minimumReleaseAge が日の単位 (<数>d) でなければ評価で止まる (1w・9)";
      ok = builtins.all (age: rejects (configWith [ { dotfiles.mise.minimumReleaseAge = age; } ])) [
        "1w"
        "9"
      ];
    }
    {
      name = "知らない欄 (until) は評価で止まる";
      ok = rejects (withOverrides [
        {
          from = "2026-10-22";
          until = "2026-10-29";
        }
      ]);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "mise-release-age-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "mise-release-age-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
