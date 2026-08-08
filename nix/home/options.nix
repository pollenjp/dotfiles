# このリポジトリ独自のオプション定義。
{ lib, ... }:

{
  options.dotfiles = {
    isWSL = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        WSL 上で動作しているか。
        1Password の op-ssh-sign のパスなど、WSL 固有の分岐に使う。
      '';
    };
  };
}
