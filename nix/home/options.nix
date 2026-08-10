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

        今の用途は `dotfiles.onePassword.enable = true` かつ WSL のときの
        op-ssh-sign-wsl.exe のパスだけなので、1Password を使わないマシンでは
        指定しなくてよい。
      '';
    };

    onePassword.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        このマシンで 1Password の SSH agent を使うか。マシンごとに
        hosts/default.nix で指定する (`onePassword = true;`)。

        true のとき、git の署名を 1Password 経由に設定する:

        - `gpg.ssh.defaultKeyCommand` で ssh-agent の鍵から署名鍵を選ぶ
        - `commit.gpgSign = true` (署名を既定にする)
        - WSL なら さらに `windowsUserName` から Windows 側の
          op-ssh-sign-wsl.exe のパスを組み立てて signer に設定する
          (Linux / macOS ネイティブの 1Password では signer の指定は不要)

        false のときは署名関連の設定を一切書き出さない。1Password の無い
        マシンで `commit.gpgSign = true` だけが残ると、署名鍵が見つからず
        `git commit` そのものが失敗するため。

        WSL の場合、この 2 通りを hosts/default.nix で選び分ける:

        - WSL + Windows 側 1Password ... `isWSL = true; onePassword = true; windowsUserName = "...";`
        - WSL で 1Password 無し       ... `isWSL = true;` (onePassword は既定の false)
      '';
    };
  };
}
