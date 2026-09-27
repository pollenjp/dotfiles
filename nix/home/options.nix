# このリポジトリ独自のオプション定義。
#
# 有効な組み合わせが構造に出るよう、WSL 固有の設定は dotfiles.wsl 配下へ入れ子にしている。
#
#   dotfiles.wsl.enable                          WSL か
#   dotfiles.wsl.windowsUserName                 ホスト側 Windows のユーザー名 (/mnt/c/Users/<名前>)
#   dotfiles.wsl.windowsFiles.enable             repo 直下の win/ を Windows 側へ配るか
#   dotfiles.wsl.onePassword.enable              ホスト側 Windows の 1Password を使うか
#   dotfiles.wsl.onePassword.windowsUserName     その 1Password のパスに要る Windows ユーザー名 (既定は上の windowsUserName)
#   dotfiles.claude.devTracker.enable            Notion Dev Tracker (pjp-dev-tracker) を使うマシンか
#
# 親が false なら子は意味を持たない、という関係がそのまま階層になっている。
# 平坦に並べていたときの「どの組み合わせが有効なのか判らない」を避けるため。
{ config, lib, ... }:

{
  options.dotfiles.claude = {
    devTracker.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        このマシンで Notion Dev Tracker (pjp-dev-tracker skill) を使うか。

        1 つの値から 2 つが決まる (home/modules/claude.nix):

        - `~/.claude/CLAUDE.md` の「タスク管理」の節 (files/claude/CLAUDE.dev-tracker.md)。
          false なら連結しない。節だけが残ると Claude が無い skill を探しに行くため
        - `~/.local/state/dotfiles/claude-skill-overrides.json` の値 ("on" / "off")。
          nix/scripts/bootstrap-claude-skill-overrides.sh がこれを
          `~/.claude/settings.json` の skillOverrides へ写し、false なら skill が
          Claude の一覧からも `/` メニューからも消える

        settings.json は Claude Code 自身が書き換えるので Nix では置けない。
        そのため反映は 2 段で、`home-manager switch` だけでは skillOverrides に
        届かない。`~/dotfiles/setup --update` (bootstrap まで走る) で揃える。

        ローカル flake の雛形 (scripts/setup-local-flake.sh) は false を書いて
        いるので、`~/dotfiles` 経由のマシンは使うところだけ true にする。
        登録簿 (hosts/default.nix) のホストを直接指すときはこの既定 (true)。
      '';
    };
  };

  options.dotfiles.wsl = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        WSL 上で動作しているか。WSL 固有の分岐に使う。

        hosts/default.nix では `wsl.enable = true;` のように指定する。
      '';
    };

    windowsUserName = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "polle";
      description = ''
        ホスト側 Windows のユーザー名。`/mnt/c/Users/<名前>/...` の組み立てに使う。
        `wsl.enable = true` のときだけ意味を持つ。

        使うところは 2 つ:

        - `windowsFiles.enable` の配り先 (`/mnt/c/Users/<名前>`)。未設定なら評価時に止まる
        - `onePassword.windowsUserName` の既定値 (1Password の op-ssh-sign のパス)

        Linux 側のユーザー名 (home.username) とは別物なので、マシンごとに
        hosts/default.nix で指定する。値は WSL 上で次を実行すると判る:

            pwsh.exe -NoProfile -Command '$env:USERNAME'

        Nix の評価は純粋なのでこのコマンドを評価時に実行して自動取得すること
        はできない (getEnv や --impure は nix flake check を壊す)。
      '';
    };

    windowsFiles.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        repo 直下の `win/` を Windows 側 (`/mnt/c/Users/<windowsUserName>`) へ配るマシンか。
        `wsl.enable = true` と `windowsUserName` が要る (欠けていれば評価時に止まる)。

        switch は Windows 側に触らない。home-manager は配り先を
        `~/.local/state/dotfiles/windows-files.json` に置くだけで
        (home/modules/windows-files.nix)、`win/` を読んで /mnt/c へコピーするのは
        nix/scripts/bootstrap-windows-files.sh。`~/dotfiles/setup --update`
        (bootstrap まで走る) で揃う。

        `win/` を home-manager で読まないのは、ローカル flake が本体を
        `path:<repo>/nix` で読むので、その評価から repo 直下が見えないため
        (docs/adr/010_win_files_from_wsl_*)。
      '';
    };

    onePassword = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        example = true;
        description = ''
          ホスト側 Windows の 1Password を使うか。`wsl.enable = true` のときだけ有効。

          true のとき、git の署名を 1Password 経由に設定する:

          - `gpg.ssh.program` に Windows 側の op-ssh-sign-wsl.exe を指定する
            (パスは windowsUserName から組み立てる)
          - `gpg.ssh.defaultKeyCommand` で ssh-agent の鍵から署名鍵を選ぶ
          - `commit.gpgSign = true` (署名を既定にする)

          false のときは署名関連の設定を一切書き出さない。1Password の無いマシンで
          `commit.gpgSign = true` だけが残ると、署名鍵が見つからず `git commit`
          そのものが失敗するため。

          NOTE: 1Password 連携を WSL 以外 (Linux / macOS ネイティブ) でも使いたく
                なったら、このオプションを dotfiles.wsl の外へ出すこと。今は
                「1Password を使うのは WSL のときだけ」という前提で入れ子にしている。
        '';
      };

      windowsUserName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = config.dotfiles.wsl.windowsUserName;
        defaultText = lib.literalExpression "config.dotfiles.wsl.windowsUserName";
        example = "polle";
        description = ''
          1Password の op-ssh-sign のパス (`/mnt/c/Users/<名前>/AppData/...`) に使う
          Windows ユーザー名。`wsl.onePassword.enable = true` のときだけ必要
          (未設定なら評価時に止まる)。

          既定は `dotfiles.wsl.windowsUserName`。ふつうはそちらに書けばよく、
          ここに書くのは 1Password だけ別の名前を指したいときに限る
          (書けばこちらが勝つ)。
        '';
      };
    };
  };
}
