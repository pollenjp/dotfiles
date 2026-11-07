# WSL のマシンの PATH に xdg-open を置く (pkgs/pjp-wsl-xdg-open。URL とファイルを Windows の既定のアプリで開く)。
#
# Linux 版の herdr は pane のリンクの Ctrl+クリックで xdg-open を呼ぶが、WSL には無いので開けない。
# dotfiles.wsl.enable のマシンの PATH に置く。root は要らないので option は設けない。
# 動きは pjp-wsl-xdg-open.sh の先頭のコメント、使い方は nix/README.md「WSL の xdg-open」。
{
  config,
  lib,
  pkgs,
  ...
}:

{
  home.packages = lib.optional config.dotfiles.wsl.enable (
    pkgs.callPackage ../../pkgs/pjp-wsl-xdg-open { }
  );
}
