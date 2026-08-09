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

    windowsUserName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "polle";
      description = ''
        WSL のホスト側 Windows ユーザー名。`/mnt/c/Users/<名前>/...` の組み立てに使う。

        Linux 側のユーザー名 (home.username) とは別物なので、マシンごとに
        hosts/default.nix で指定する。値は WSL 上で次を実行すると判る:

            pwsh.exe -NoProfile -Command '$env:USERNAME'

        Nix の評価は純粋なのでこのコマンドを評価時に実行して自動取得すること
        はできない (getEnv や --impure は nix flake check を壊す)。

        null のままだと 1Password の op-ssh-sign は設定されず、git の署名は
        通常の ssh-keygen で行われる。これも正当な構成なので、単に
        1Password を使わないマシンでは指定しなくてよい。
      '';
    };
  };
}
