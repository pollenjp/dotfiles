# 登録の下書きを描く nix/lib/host-draft.nix (nix/scripts/private-host.sh draft が使う) を、評価時に確かめる (ADR 025)。
# 描いた下書きが fixtures/host-draft/ の期待のファイルと 1 字も違わないことを見てから、そのファイルを import して
# 元のホストと drvPath を比べる (描いたものを builtins.toFile で store に置いて import する形は、store に書かない評価
# (CI の `nix flake check --no-build`) で「path … is not valid」になるので使わない)。元のホストの system は x86_64-linux に
# 固定する (期待のファイルに system を書くため。どの system の checks でも評価だけはできる)。
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
#     頭のコメントに元にしたホストと notes を書く。fixtures/host-draft/ の期待のファイルと 1 字も違わない (WSL のホストも)
#   - 期待のファイル (= 描いた下書き) を import したホストは、元のホストと drvPath が同じ。値を 1 つ変えたホストとは違う
#   - 字句にできない値 (関数) は、値を書かずに「# TODO: dotfiles.<path>」の行にする
{
  lib,
  pkgs,
  mkHome,
  system,
}:

let
  draft = import ../lib/host-draft.nix { inherit lib; };

  # 期待の下書き (fixtures/host-draft/<名前>.nix)。名前の @ は path の字句に書けないので文字列で足す
  fixture = file: ./fixtures/host-draft + "/${file}";
  # 元のホストの system。期待のファイルに書くので固定する (どの system の checks でも評価だけはできる)
  hostSystem = "x86_64-linux";

  # 登録簿のホスト + ローカル flake の local (hostsWith が modules に前置するのと同じ形)。port は local の値
  carolWith =
    port:
    mkHome {
      username = "carol";
      system = hostSystem;
      onePassword.enable = true;
      modules = [
        {
          dotfiles.claude.devTracker.enable = true;
          dotfiles.claude.notion.profile = "work";
          dotfiles.ccPages.port = port;
        }
      ];
    };
  carol = carolWith 7801;
  carolValues = draft.collect carol.options.dotfiles;
  carolText = draft.render {
    name = "carol@box";
    username = "carol";
    system = hostSystem;
    base = "carol@generic";
    values = carolValues;
  };
  drvOf = host: host.activationPackage.drvPath;
  importFixture = file: import (fixture file) { inherit mkHome; };

  dave = mkHome {
    username = "dave";
    system = hostSystem;
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
    system = hostSystem;
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
      name = "render は期待のファイル (fixtures/host-draft/carol@box.nix) と 1 字も違わない";
      ok = carolText == builtins.readFile (fixture "carol@box.nix");
    }
    {
      name = "WSL のホストの render も期待のファイル (fixtures/host-draft/dave@box.nix) と 1 字も違わない";
      ok = daveText == builtins.readFile (fixture "dave@box.nix");
    }
    {
      name = "描いた下書き (= 期待のファイル) を import したホストは元のホストと drvPath が同じ";
      ok = drvOf (importFixture "carol@box.nix") == drvOf carol;
    }
    {
      name = "WSL のホストも、描いた下書きを import すると drvPath が同じ";
      ok = drvOf (importFixture "dave@box.nix") == drvOf dave;
    }
    {
      name = "値を 1 つ変えたホスト (port 7802) とは drvPath が違う";
      ok = drvOf (importFixture "carol@box.nix") != drvOf (carolWith 7802);
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
