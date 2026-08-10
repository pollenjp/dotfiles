# ~/.ssh/config を生成する。
#
# 複製元: リポジトリ直下の ssh_config
#   main.bash setup が ~/.ssh/config へ `Include ~/dotfiles/ssh_config` を追記し、
#   その ssh_config が次の 2 つを Include していた。
#
#     Include ~/dotfiles/.ssh/*.ssh_config     <- .ssh submodule (private repo)
#     Include ~/.ssh/config.d/*.ssh_config     <- マシン固有
#
# ## 中身を Nix 管理下に置かない理由
#
# 1. **`/nix/store` は誰でも読める。** ssh の接続先ホスト名・ユーザー名・踏み台の
#    構成は他ユーザーに見せたくないので、store に入れてはいけない。
#    パーミッションで隠すこともできない (store のファイルは 444)。
# 2. 実体は `.ssh` submodule にあり、**flake root (`nix/`) の外**なので
#    そもそも flake から読めない。
#
# そこでここでは **Include の骨組みだけ**を生成し、中身は
# `scripts/bootstrap-ssh-config.sh` が `~/.ssh/config.d/` へ symlink する。
# 骨組みが Nix 管理なので「Include 行が入っているか」を気にしなくてよくなる
# (従来は main.bash の追記が済んでいるかどうかがマシンごとに曖昧だった)。
{ ... }:

{
  programs.ssh = {
    enable = true;

    # home-manager 既定の `Host *` ブロックを出さない。
    #
    # 従来の ~/.ssh/config には Include 行しか無く、ForwardAgent や
    # ControlMaster などの既定値は入っていなかった。挙動を変えないために切る。
    #
    # NOTE: このオプションを明示しないと deprecation の warning が出る。
    #       CI は sandbox の warnings が空であることを確認しているので、
    #       未指定のままだと落ちる。
    enableDefaultConfig = false;

    # ssh は相対パスの Include を ~/.ssh/ 基準で解決する。
    # つまりこれは ~/.ssh/config.d/*.ssh_config を読む。
    #
    # ここに置かれるもの:
    #   - .ssh submodule の *.ssh_config (bootstrap-ssh-config.sh が symlink)
    #   - マシン固有の設定 (手で置く。git 管理外)
    #
    # ssh は同じキーワードについて **最初に得た値**を採るので、
    # config.d が Nix 生成分より優先される。マシン固有の上書きができる。
    includes = [ "config.d/*.ssh_config" ];
  };
}
