# 本体の lib.privateHosts (nix/lib/private-hosts.nix) が、dotfiles-private の nix/ (ローカル flake の path: の入力) の
# hosts/*.nix からホストを組み立て、shared/*.nix の module を全ホストに足すことを、作り物の nix/ (fixtures/private-hosts)
# で評価時に確かめる (ADR 026・030)。
#
# 合わなければ assert で評価が止まり、外れた項目の名前が出る。評価で止まるので、
# CI の `nix flake check --all-systems --no-build` (全 system の評価) でも落ちる。
# flake.nix の checks (private-hosts-state) から呼ぶ。
#
# ## 確かめること
#
#   - hosts/ の .nix ごとに 1 ホストができ、名前はファイル名から .nix を除いたもの (名前の @ もそのまま)
#   - .nix でないファイル (README.md) と、名前が . で始まるファイル (エディタのロックなど) はホストにしない
#   - 各ホストは、ファイルが mkHome に渡した値 (username・mkHome の引数・modules) で組み立てられる
#   - flake = false の input と同じ形 (outPath を持つ attrset) を渡しても同じホストができる
#   - hosts/ に .nix が無いなら { }
#   - hosts/ が無い (本体の stub。clone の無いマシンでローカル flake が指す先) なら { }
#   - path を渡しても store へ写さずに読む (store に書かない評価 (CI の --no-build) でも落ちない)
#   - shared/ の .nix (home-manager の module) は、登録した全ホストに足される (mise の遅延の上書きの list)
#   - ホストのファイルの modules に書いた list は、shared/ の list とつながる (順は module system が決めるので見ない)
#   - shared/ の .nix でないファイル (README.md) と、名前が . で始まるファイル (読めば throw する作り物) は拾わない
#   - shared/ の無い clone のホストも評価が通り、何も足さない。outPath の形で渡しても shared/ が当たる
{
  lib,
  pkgs,
  privateHosts,
}:

let
  # fixture は path のまま渡す (store へ写さない。CI の `nix flake check --no-build` は store に書かずに評価する)
  hosts = privateHosts ./fixtures/private-hosts;
  # .nix の無い hosts/ (git は空のディレクトリを持てないので README.md だけを置いてある)
  emptyHosts = privateHosts ./fixtures/private-hosts-empty;
  stub = privateHosts ../private-stub;
  # hosts/ はあるが shared/ が無い
  noShared = privateHosts ./fixtures/private-hosts-no-shared;
  cfg = name: hosts.${name}.config;
  # 上書きの list の reason (どの module から来た項目か)
  reasons = c: map (o: o.reason) c.dotfiles.mise.releaseAgeOverrides;

  cases = [
    {
      name = "hosts/ の .nix ごとに 1 ホストができ、名前はファイル名から .nix を除いたもの (README.md と . で始まるファイルは拾わない)";
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
      name = "hosts/ に .nix が無ければ { }";
      ok = emptyHosts == { };
    }
    {
      name = "hosts/ が無い (本体の stub) なら { }";
      ok = stub == { };
    }
    {
      name = "shared/ の .nix は登録した全ホストに足される (bob@two の上書きは shared/ の項目だけ)";
      ok = reasons (cfg "bob@two") == [ "全ホスト" ];
    }
    {
      name = "ホストのファイルの modules に書いた list は、shared/ の list とつながる (alice@one は 2 つ。順は見ない)";
      ok =
        let
          r = reasons (cfg "alice@one");
        in
        builtins.length r == 2 && builtins.elem "全ホスト" r && builtins.elem "alice だけ" r;
    }
    {
      name = "shared/ の README.md と . で始まるファイル (読めば throw する) は拾わない";
      ok = (builtins.tryEval (builtins.deepSeq (reasons (cfg "bob@two")) true)).success;
    }
    {
      name = "shared/ の無い clone のホストも評価が通り、上書きは空のリスト";
      ok =
        builtins.attrNames noShared == [ "carol@three" ]
        && noShared."carol@three".config.dotfiles.mise.releaseAgeOverrides == [ ];
    }
    {
      name = "flake = false の input の形 (outPath を持つ attrset) でも shared/ が当たる";
      ok =
        reasons
          (privateHosts {
            outPath = ./fixtures/private-hosts;
          })."bob@two".config == [ "全ホスト" ];
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
