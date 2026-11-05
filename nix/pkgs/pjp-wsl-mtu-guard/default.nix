# WSL の eth0 の MTU を上限まで下げ続ける見張り (dotfiles.wsl.mtuGuard)。動きは pjp-wsl-mtu-guard.sh の先頭のコメント。
#
# MTU を変えるには root が要る。常時動かすのは systemd の system の unit
# (home/modules/wsl-mtu-guard.nix が生成し、setup の手順 wsl-mtu-guard が入れる)。PATH には置かない。
{
  writeShellApplication,
  iproute2,
}:

writeShellApplication {
  name = "pjp-wsl-mtu-guard";
  runtimeInputs = [ iproute2 ];
  text = builtins.readFile ./pjp-wsl-mtu-guard.sh;
}
