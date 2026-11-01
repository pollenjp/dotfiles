# home/options.nix の dotfiles.ntn.keyring と、そこから作られる ~/.local/state/dotfiles/ntn.json
# (home/modules/ntn.nix) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (ntn-state) から呼ぶ。
#
# ## 確かめること
#
#   - keyring の既定は null で、ntn.json は {"keyring": null} (null も書く) で、改行で終わる。
#     nix/scripts/bootstrap-ntn.sh がこれを読み、null なら ntn の config.json に触らない
#   - keyring = false / true は ntn.json にそのまま入る
#   - 真偽値でも null でもない値 ("false" の文字列) は評価で止まる
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

  state = cfg: cfg.home.file.".local/state/dotfiles/ntn.json".text;
  json = cfg: builtins.fromJSON (state cfg);
  # 評価で止まるか。型の誤りは、値を読んだとき (JSON を作るとき) に throw になる
  rejects = cfg: !(builtins.tryEval (state cfg)).success;

  byDefault = configWith [ ];

  cases = [
    {
      name = "keyring の既定は null";
      ok = byDefault.dotfiles.ntn.keyring == null;
    }
    {
      name = "既定の ntn.json は {\"keyring\": null} で、改行で終わる";
      ok = json byDefault == { keyring = null; } && lib.hasSuffix "\n" (state byDefault);
    }
    {
      name = "keyring = false の ntn.json は {\"keyring\": false}";
      ok = json (configWith [ { dotfiles.ntn.keyring = false; } ]) == { keyring = false; };
    }
    {
      name = "keyring = true の ntn.json は {\"keyring\": true}";
      ok = json (configWith [ { dotfiles.ntn.keyring = true; } ]) == { keyring = true; };
    }
    {
      name = "真偽値でも null でもない値 (\"false\" の文字列) は評価で止まる";
      ok = rejects (configWith [ { dotfiles.ntn.keyring = "false"; } ]);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "ntn-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "ntn-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
