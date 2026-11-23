# dotfiles-private の win/hosts/<Windows のユーザー名>@<PC の名前>.toml (Windows の runner が読むホストの値。書き方は
# win/README.md の「ホストの値」) を読む。ホストの要約 (lib/host-summary/ の files と winData) が、Windows のホストのページを
# 作るのに使う (dotfiles-private の docs/adr/093_host_summary_html_*)。
#
#   dir   dotfiles-private の win/hosts/。path か、outPath を持つ attrset (flake = false の input)。無ければ { }
#
# 名前 (ファイル名から .toml を除いたもの) → builtins.fromTOML の結果。読むのは .toml で名前が . で始まらないファイルだけ
# (lib/private-hosts.nix の hosts/*.nix と同じ。README.md などは拾わない)。値を確かめるのは winData (知らないグループ・道具・
# bool でない道具の値で止める。runner と同じ見方)。
{ lib }:

dir:
let
  root = if builtins.isAttrs dir then dir.outPath else dir;
  entries = if builtins.pathExists root then builtins.readDir root else { };
  files = lib.filterAttrs (
    file: type: type != "directory" && lib.hasSuffix ".toml" file && !(lib.hasPrefix "." file)
  ) entries;
  pathOf = file: if builtins.isPath root then root + "/${file}" else "${root}/${file}";
in
lib.mapAttrs' (
  file: _:
  lib.nameValuePair (lib.removeSuffix ".toml" file) (
    builtins.fromTOML (builtins.readFile (pathOf file))
  )
) files
