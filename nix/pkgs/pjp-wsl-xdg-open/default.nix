# WSL の xdg-open (URL とファイルを Windows の既定のアプリで開く)。動きは pjp-wsl-xdg-open.sh の先頭のコメント。
#
# wslpath と rundll32.exe は nixpkgs に無く WSL が持つものなので、runtimeInputs に入れない
# (wslpath は呼ぶ側の PATH から引く。rundll32.exe は固定のパス)。
#
# home/modules/wsl-xdg-open.nix が dotfiles.wsl.enable のマシンの PATH に入れる。
{
  writeShellApplication,
  coreutils,
}:

writeShellApplication {
  name = "xdg-open";
  runtimeInputs = [ coreutils ];
  text = builtins.readFile ./pjp-wsl-xdg-open.sh;
}
