# dotfiles-private (private な repo) の nix/ から、登録した PC のホストを組み立てる (ADR 026)。
#
# ローカル flake (~/dotfiles/flake.nix) の雛形が、dotfiles-private の clone の nix/ を path: の入力
# (flake = false) に取り、`dotfiles.lib.privateHosts dotfiles-private` で呼ぶ。public な本体の input には
# しない (ADR 015 / 016) ので、本体の flake はこれを自分では呼ばない。
#
#   nix/hosts/<user>@<hostname>.nix   1 実機 1 ファイル。ホストの名前はファイル名から .nix を除いたもの
#   nix/shared/*.nix                  登録した全ホストに足す home-manager の module (mise の遅延の上書きなど。TKT-323)
#
# hosts/ の各ファイルは、登録簿 (hosts/default.nix) の 1 エントリと同じく mkHome を受け取って呼ぶ関数:
#
#   { mkHome, ... }:
#   mkHome {
#     username = "…";
#     system = "x86_64-linux";
#     claude.notion.profile = "…";
#     modules = [ { dotfiles.ccPages.port = …; } ];
#   }
#
# ファイルがその PC の値の全部を持つので、ローカル flake の local は当てない (素の mkHome を渡す)。ただし shared/ の
# module は、各ホストのファイルが mkHome に渡す modules の前に足す (名前の順)。脆弱性への対応のように、登録した全 PC に
# 効かせたい値を 1 か所に書くため。shared/ とホストのファイルの両方に書いた list の option はつながる (順は module
# system が決める)。list でない option に両方で違う値を書くと、優先度を付けない限り評価が止まる。shared/ に書く
# option は全 PC の本体が持つものだけにする (本体が古い PC では option が無く、その PC の評価が止まる)。
#
# hosts/ が無い・空なら { } (clone の無いマシンは本体の空の stub (nix/private-stub) を指す)。shared/ が無ければ何も足さない。
# 読むのは hosts/ と shared/ の .nix だけで、ほかのファイル (README.md など) と名前が . で始まるファイルは拾わない。
{ lib, mkHome }:

# privateNix: dotfiles-private の nix/。path か、outPath を持つ attrset (flake = false の input)。
# path は文字列にせず path のまま辿る (文字列にすると store へ写すことになり、store に書かない評価
# (`nix flake check --no-build`) では写されないまま読もうとして「path … is not valid」で落ちる)
privateNix:
let
  root = if builtins.isAttrs privateNix then privateNix.outPath else privateNix;
  sub = name: if builtins.isPath root then root + "/${name}" else "${root}/${name}";
  # dir の .nix のファイル (ファイル名 → path)。dir が無ければ { }。
  # 名前が . で始まるもの (エディタのロック `.#<名前>.nix`・一時ファイル) は拾わない (setup.sh の *.nix の glob とも揃う)
  nixFilesIn =
    dir:
    let
      entries = if builtins.pathExists dir then builtins.readDir dir else { };
      files = lib.filterAttrs (
        file: type: type != "directory" && lib.hasSuffix ".nix" file && !(lib.hasPrefix "." file)
      ) entries;
    in
    lib.mapAttrs (file: _: if builtins.isPath dir then dir + "/${file}" else "${dir}/${file}") files;
  # 登録した全ホストに足す module (attrValues はファイル名の順)
  sharedModules = builtins.attrValues (nixFilesIn (sub "shared"));
  mkHomeShared = args: mkHome (args // { modules = sharedModules ++ (args.modules or [ ]); });
in
lib.mapAttrs' (
  file: path:
  lib.nameValuePair (lib.removeSuffix ".nix" file) (import path { mkHome = mkHomeShared; })
) (nixFilesIn (sub "hosts"))
