# home/options.nix の dotfiles.cursorAgent.enable と、そこから作られる ~/.local/state/dotfiles/cursor-agent.json
# (home/modules/cursor-agent.nix) を、評価時に確かめる。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (cursor-agent-state) から呼ぶ。
#
# ## 確かめること
#
#   - enable の既定は false で、cursor-agent.json は {"enable": false} で、改行で終わる。
#     nix/scripts/bootstrap-mise.sh がこれを読み、false なら cursor-agent を入れない
#   - enable = true の cursor-agent.json は {"enable": true}
#   - on でも off でも、home-manager は mise の conf.d に cursor-agent の宣言を置かない (宣言は版を決めた
#     bootstrap-mise.sh が書く。前は files.nix が latest の宣言を全ホストに置いていた)
#   - 真偽値でない値 ("true" の文字列) は評価で止まる
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

  state = cfg: cfg.home.file.".local/state/dotfiles/cursor-agent.json".text;
  json = cfg: builtins.fromJSON (state cfg);
  # 評価で止まるか。型の誤りは、値を読んだとき (JSON を作るとき) に throw になる
  rejects = cfg: !(builtins.tryEval (state cfg)).success;
  # home-manager が置くファイルのうち、mise の conf.d の cursor-agent の宣言 (名前を問わない)
  confDecls =
    cfg:
    builtins.filter (t: lib.hasInfix "mise/conf.d/" t && lib.hasInfix "cursor-agent" t) (
      map (f: f.target) (builtins.attrValues cfg.home.file)
    );

  byDefault = configWith [ ];
  enabled = configWith [ { dotfiles.cursorAgent.enable = true; } ];

  cases = [
    {
      name = "enable の既定は false";
      ok = byDefault.dotfiles.cursorAgent.enable == false;
    }
    {
      name = "既定の cursor-agent.json は {\"enable\": false} で、改行で終わる";
      ok = json byDefault == { enable = false; } && lib.hasSuffix "\n" (state byDefault);
    }
    {
      name = "enable = true の cursor-agent.json は {\"enable\": true}";
      ok = json enabled == { enable = true; };
    }
    {
      name = "on でも off でも、home-manager は mise の conf.d に cursor-agent の宣言を置かない";
      ok = confDecls byDefault == [ ] && confDecls enabled == [ ];
    }
    {
      name = "真偽値でない値 (\"true\" の文字列) は評価で止まる";
      ok = rejects (configWith [ { dotfiles.cursorAgent.enable = "true"; } ]);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "cursor-agent-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "cursor-agent-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
