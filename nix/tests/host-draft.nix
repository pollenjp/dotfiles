# 登録の下書きを描く nix/lib/host-draft.nix (nix/scripts/private-host.sh draft が使う) を、評価時に確かめる (ADR 025)。
# 描いた下書きを builtins.toFile で store に置いて import し直し、元のホストと drvPath を比べる (IFD は使わない)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (host-draft-state) から呼ぶ。
#
# ## 確かめること
#
#   - collect は、mkHome の引数・modules (ローカル flake の local) で定義した dotfiles の option を、既定と同じ値
#     (devTracker.enable = true) も含めて path の辞書順で集め、定義していない option は集めない
#   - collect は、既定が別の option から決まるもの (wsl.onePassword.windowsUserName) を集めない。改名した旧名
#     (wsl.onePassword.enable) で書いた値は、新しい名前 (onePassword.enable) で集める
#   - render は、wsl・onePassword・claude を mkHome の引数の組に (組の値が 1 つなら 1 行で)、ほかを modules に描き、
#     頭のコメントに元にしたホストと notes を書く。決めた形と 1 字も違わない
#   - 描いた下書きを import し直したホストは、元のホストと drvPath が同じ (WSL のホストも)。値を 1 つ変えると違う
#   - 字句にできない値 (関数) は、値を書かずに「# TODO: dotfiles.<path>」の行にする
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  draft = import ../lib/host-draft.nix { inherit lib; };

  # 登録簿のホスト + ローカル flake の local (hostsWith が modules に前置するのと同じ形)
  carol = mkHome {
    username = "carol";
    inherit system;
    onePassword.enable = true;
    modules = [
      {
        dotfiles.claude.devTracker.enable = true;
        dotfiles.claude.notion.profile = "work";
        dotfiles.ccPages.port = 7801;
      }
    ];
  };
  carolValues = draft.collect carol.options.dotfiles;
  carolText = draft.render {
    name = "carol@box";
    username = "carol";
    inherit system;
    base = "carol@generic";
    values = carolValues;
  };
  carolWant = ''
    # この PC (carol@box) のホストの定義と値の全部 (dotfiles の ADR 025)。ホストの名前はファイル名から .nix を除いたもの。
    # ローカル flake (~/dotfiles/flake.nix) の local はこのホストには当たらない。値を変えるときはこのファイルを直す。
    # 下書きは dotfiles の nix/scripts/private-host.sh draft が描いた (元にしたホスト: carol@generic とローカル flake の local)。
    { mkHome, ... }:
    mkHome {
      username = "carol";
      system = "${system}";
      onePassword.enable = true;
      claude = {
        devTracker.enable = true;
        notion.profile = "work";
      };
      modules = [
        {
          dotfiles.ccPages.port = 7801;
        }
      ];
    }
  '';
  reimport = text: import (builtins.toFile "draft.nix" text) { inherit mkHome; };
  drvOf = host: host.activationPackage.drvPath;

  dave = mkHome {
    username = "dave";
    inherit system;
    wsl = {
      enable = true;
      windowsUserName = "dave";
      windowsFiles.enable = true;
    };
    onePassword.enable = true;
    claude.devTracker.enable = false;
  };
  daveValues = draft.collect dave.options.dotfiles;
  daveText = draft.render {
    name = "dave@box";
    username = "dave";
    inherit system;
    values = daveValues;
  };

  # 改名した旧名 (dotfiles.wsl.onePassword.enable) で書いた local
  erin = mkHome {
    username = "erin";
    inherit system;
    wsl = {
      enable = true;
      windowsUserName = "erin";
    };
    claude.devTracker.enable = false;
    modules = [ { dotfiles.wsl.onePassword.enable = true; } ];
  };
  erinPaths = map (v: lib.concatStringsSep "." v.path) (draft.collect erin.options.dotfiles);

  todoText = draft.render {
    name = "frank@box";
    username = "frank";
    inherit system;
    values = [
      {
        path = [
          "claude"
          "notion"
          "profile"
        ];
        value = x: x;
      }
    ];
  };

  cases = [
    {
      name = "collect は定義した option を既定と同じ値も含めて path の辞書順で集める";
      ok =
        map (v: lib.concatStringsSep "." v.path) carolValues == [
          "ccPages.port"
          "claude.devTracker.enable"
          "claude.notion.profile"
          "onePassword.enable"
        ];
    }
    {
      name = "collect の値は評価した値";
      ok =
        map (v: v.value) carolValues == [
          7801
          true
          "work"
          true
        ];
    }
    {
      name = "collect は既定が別の option から決まる wsl.onePassword.windowsUserName を集めない";
      ok =
        !(builtins.elem "wsl.onePassword.windowsUserName" (
          map (v: lib.concatStringsSep "." v.path) daveValues
        ));
    }
    {
      name = "collect は旧名 wsl.onePassword.enable で書いた値を onePassword.enable で集める";
      ok =
        builtins.elem "onePassword.enable" erinPaths && !(builtins.elem "wsl.onePassword.enable" erinPaths);
    }
    {
      name = "render は決めた形と 1 字も違わない";
      ok = carolText == carolWant;
    }
    {
      name = "描いた下書きを import し直したホストは元のホストと drvPath が同じ";
      ok = drvOf (reimport carolText) == drvOf carol;
    }
    {
      name = "WSL のホストも、描いて import し直すと drvPath が同じ";
      ok = drvOf (reimport daveText) == drvOf dave;
    }
    {
      name = "値を 1 つ変えた下書きは drvPath が違う";
      ok = drvOf (reimport (builtins.replaceStrings [ "7801" ] [ "7802" ] carolText)) != drvOf carol;
    }
    {
      name = "字句にできない値 (関数) は値を書かずに TODO の行にする";
      ok =
        lib.hasInfix "# TODO: dotfiles.claude.notion.profile" todoText
        && !(lib.hasInfix "profile =" todoText);
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "host-draft-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "host-draft-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
