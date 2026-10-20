# dotfiles-private (private な repo) の nix/ から、登録した PC のホストを組み立てる (ADR 025)。
#
# ローカル flake (~/dotfiles/flake.nix) の雛形が、dotfiles-private の clone の nix/ を path: の入力
# (flake = false) に取り、`dotfiles.lib.privateHosts dotfiles-private` で呼ぶ。public な本体の input には
# しない (ADR 015 / 016) ので、本体の flake はこれを自分では呼ばない。
#
#   nix/hosts/<user>@<hostname>.nix   1 実機 1 ファイル。ホストの名前はファイル名から .nix を除いたもの
#
# 各ファイルは、登録簿 (hosts/default.nix) の 1 エントリと同じく mkHome を受け取って呼ぶ関数:
#
#   { mkHome, ... }:
#   mkHome {
#     username = "…";
#     system = "x86_64-linux";
#     claude.notion.profile = "…";
#     modules = [ { dotfiles.ccPages.port = …; } ];
#   }
#
# ファイルがその PC の値の全部を持つので、ローカル flake の local は当てない (素の mkHome を渡す)。
# hosts/ が無い・空なら { } (clone の無いマシンは本体の空の stub (nix/private-stub) を指す)。
# 読むのは hosts/ の .nix だけで、ほかのファイル (README.md など) は拾わない。
{ lib, mkHome }:

# privateNix: dotfiles-private の nix/。path か、outPath を持つ attrset (flake = false の input)。
# path は文字列にせず path のまま辿る (文字列にすると store へ写すことになり、store に書かない評価
# (`nix flake check --no-build`) では写されないまま読もうとして「path … is not valid」で落ちる)
privateNix:
let
  root = if builtins.isAttrs privateNix then privateNix.outPath else privateNix;
  dir = if builtins.isPath root then root + "/hosts" else "${root}/hosts";
  entries = if builtins.pathExists dir then builtins.readDir dir else { };
  files = lib.filterAttrs (file: type: type != "directory" && lib.hasSuffix ".nix" file) entries;
  fileOf = file: if builtins.isPath dir then dir + "/${file}" else "${dir}/${file}";
in
lib.mapAttrs' (
  file: _: lib.nameValuePair (lib.removeSuffix ".nix" file) (import (fileOf file) { inherit mkHome; })
) files
