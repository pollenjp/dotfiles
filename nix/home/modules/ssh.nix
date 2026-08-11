# ssh まわり。次の 2 つを持つ。
#
#   1. ~/.ssh/config を生成する (Include の骨組みだけ)
#   2. WSL + 1Password のマシンに ~/.local/bin/{ssh,ssh-add} ラッパーを置く
#
# # 1. ~/.ssh/config
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
# `scripts/setup-ssh-config.sh` が `~/.ssh/config.d/` へ symlink する。
# 骨組みが Nix 管理なので「Include 行が入っているか」を気にしなくてよくなる
# (従来は main.bash の追記が済んでいるかどうかがマシンごとに曖昧だった)。
#
# # 2. ssh ラッパー
#
# 複製元: リポジトリ直下の bin/ssh-wsl.sh / bin/ssh-add-wsl.sh
#   main.bash setup が uname と ssh.exe の有無を見て ~/.local/bin/ へ symlink して
#   いた。Nix 経路では登録簿の指定 (dotfiles.wsl.onePassword.enable) で分岐する。
#   詳細は下の home.file のコメントを参照。
{ config, lib, ... }:

let
  wsl = config.dotfiles.wsl;

  # git.nix と同じ判定。入れ子の親も見るのは、wsl.enable = false のまま
  # onePassword.enable だけ true になった登録を「有効」と誤認しないため
  # (その組み合わせは git.nix の assertion で評価時に止まる)。
  useOnePassword = wsl.enable && wsl.onePassword.enable;
in

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
    #   - .ssh submodule の *.ssh_config (setup-ssh-config.sh が symlink)
    #   - マシン固有の設定 (手で置く。git 管理外)
    #
    # ssh は同じキーワードについて **最初に得た値**を採るので、
    # config.d が Nix 生成分より優先される。マシン固有の上書きができる。
    includes = [ "config.d/*.ssh_config" ];
  };

  # WSL から Windows 側の ssh.exe / ssh-add.exe を呼ぶラッパー。
  #
  # ## なぜ ssh 自体を差し替えるのか
  #
  # 1Password の ssh-agent は **ホスト側 Windows** にいる。この dotfiles は
  # npiperelay / socat による SSH_AUTH_SOCK の橋渡しをしていないので、WSL 側の
  # Linux ssh からは agent が見えない。そこで ssh / ssh-add そのものを Windows
  # 側の実体へ exec するラッパーに差し替えて使う。
  #
  # ## git の署名もこれに依存している
  #
  # git.nix の gpg.ssh.defaultKeyCommand は `ssh-add -L` の出力から "Signing" を
  # 含む鍵を選ぶ。この ssh-add が Linux 側だと 1Password の鍵が並ばないので、
  # 鍵が見つからないまま commit.gpgSign = true だけが残り git commit が失敗する。
  # つまりラッパーは署名経路の一部でもある (op-ssh-sign のパス指定だけでは足りない)。
  #
  # ## 逃げ道
  #
  # USE_LINUX_SSH=1 を渡すと Linux 側 (/usr/bin/ssh) に落ちる。ラッパー側の
  # 分岐なのでここでは何もしない。
  #
  # ## 移行時の注意
  #
  # main.bash 経路が張った同じパスの symlink は scripts/preflight-unlink.sh が外す。
  # 複製は verbatim なので外し忘れても中身が一致し、警告
  # ("will be skipped since they are the same") だけ出て store のリンクに
  # 置き換わる。ただし**どちらかを編集していた場合は "would be clobbered" で
  # switch が止まり、symlink は -b <拡張子> の退避対象外なので手で外すしかない**
  # (home-manager の check-link-targets.sh で実測)。先に外しておく方が安全。
  home.file = lib.mkIf useOnePassword {
    ".local/bin/ssh" = {
      source = ../../files/bin/ssh-wsl.sh;

      # 実行ビットは複製元 (git の mode 100755) から引き継がれるが、落ちていても
      # 壊れないよう明示する。exec できないと ssh が丸ごと使えなくなるため。
      executable = true;
    };

    ".local/bin/ssh-add" = {
      source = ../../files/bin/ssh-add-wsl.sh;
      executable = true;
    };
  };
}
