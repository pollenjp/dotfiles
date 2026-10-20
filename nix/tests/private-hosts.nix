# 本体の lib.privateHosts (nix/lib/private-hosts.nix) が、dotfiles-private の nix/ (ローカル flake の path: の入力) の
# hosts/*.nix からホストを組み立てることを、作り物の hosts/ (fixtures/private-hosts) で評価時に確かめる (ADR 025)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (private-hosts-state) から呼ぶ。
#
# ## 確かめること
#
#   - hosts/ の .nix ごとに 1 ホストができ、名前はファイル名から .nix を除いたもの (名前の @ もそのまま)
#   - .nix でないファイル (README.md) はホストにしない
#   - 各ホストは、ファイルが mkHome に渡した値 (username・mkHome の引数・modules) で組み立てられる
#   - flake = false の input と同じ形 (outPath を持つ attrset) を渡しても同じホストができる
#   - hosts/ が空なら { }
#   - hosts/ が無い (本体の stub。clone の無いマシンでローカル flake が指す先) なら { }
{
  lib,
  pkgs,
  privateHosts,
}:

let
  hosts = privateHosts ./fixtures/private-hosts;
  # git は空のディレクトリを持てないので、hosts/ のディレクトリだけを残して写す
  emptyHosts = privateHosts (
    builtins.path {
      name = "private-hosts-empty";
      path = ./fixtures/private-hosts;
      filter = _: type: type == "directory";
    }
  );
  stub = privateHosts ../private-stub;
  cfg = name: hosts.${name}.config;

  cases = [
    {
      name = "hosts/ の .nix ごとに 1 ホストができ、名前はファイル名から .nix を除いたもの (README.md は拾わない)";
      ok =
        builtins.attrNames hosts == [
          "alice@one"
          "bob@two"
        ];
    }
    {
      name = "alice@one はファイルが渡した username・claude.notion.profile・modules の値で組み立てられる";
      ok =
        (cfg "alice@one").home.username == "alice"
        && (cfg "alice@one").dotfiles.claude.notion.profile == "work"
        && (cfg "alice@one").dotfiles.ccPages.port == 7801;
    }
    {
      name = "bob@two は wsl の引数で組み立てられる";
      ok = (cfg "bob@two").dotfiles.wsl.enable && (cfg "bob@two").dotfiles.wsl.windowsUserName == "bob";
    }
    {
      name = "flake = false の input の形 (outPath を持つ attrset) でも同じホストができる";
      ok =
        builtins.attrNames (privateHosts {
          outPath = ./fixtures/private-hosts;
        }) == builtins.attrNames hosts;
    }
    {
      name = "hosts/ が空なら { }";
      ok = emptyHosts == { };
    }
    {
      name = "hosts/ が無い (本体の stub) なら { }";
      ok = stub == { };
    }
  ];

  failed = builtins.filter (c: !c.ok) cases;
in
assert lib.assertMsg (failed == [ ])
  "private-hosts-state: 合わない項目: ${lib.concatMapStringsSep " / " (c: c.name) failed}";
pkgs.runCommand "private-hosts-state" { } ''
  echo ${lib.escapeShellArg (lib.concatMapStringsSep "\n" (c: "ok   ${c.name}") cases)}
  touch $out
''
