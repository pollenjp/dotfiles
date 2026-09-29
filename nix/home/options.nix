# このリポジトリ独自のオプション定義。
#
# 有効な組み合わせが構造に出るよう、WSL 固有の設定は dotfiles.wsl 配下へ入れ子にしている。
#
#   dotfiles.wsl.enable                          WSL か
#   dotfiles.wsl.onePassword.enable              ホスト側 Windows の 1Password を使うか
#   dotfiles.wsl.onePassword.windowsUserName     その 1Password のパスに要る Windows ユーザー名
#   dotfiles.claude.devTracker.enable            Notion Dev Tracker (pjp-dev-tracker) を使うマシンか
#   dotfiles.claude.notion.profile               Notion へ書く skill の宛先のプロファイル名
#   dotfiles.claude.notion.override              そのプロファイルの値をこのマシンだけ差し替える
#
# 親が false なら子は意味を持たない、という関係がそのまま階層になっている。
# 平坦に並べていたときの「どの組み合わせが有効なのか判らない」を避けるため。
{ lib, pkgs, ... }:

let
  # JSON にそのまま書き出せる値 (dotfiles.claude.notion.override 用)
  jsonValue = (pkgs.formats.json { }).type;
in
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

    notion = {
      profile = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[a-z0-9][a-z0-9_-]*");
        default = null;
        example = "personal";
        description = ''
          Notion へ書く skill (claude-skills の pjp-dev-tracker・pjp-notion-authoring・
          pjp-docs-to-notion・pjp-scan-to-notion) が使う宛先のプロファイル名。

          中身 (workspace の id・Dev Tracker の場所・新しいページの既定の親・Scan Data DB)
          は private の claude-skills (skills/pjp-notion-profile/profiles.toml) が持ち、
          ここでは名前だけを選ぶ。ページ名入りの URL を public なこのリポジトリに
          出さないため。

          null (既定) で override も空なら、skill は宛先が決まらないとして止まる
          (黙って別の workspace へ書かないため)。ローカル flake の雛形も null を書く。

          home/modules/claude.nix が ~/.local/state/dotfiles/claude-notion.json に
          書き出し、claude-skills の resolver がそれを読む。反映は home-manager switch
          (~/dotfiles/setup --update でもよい)。
        '';
      };

      override = lib.mkOption {
        type = lib.types.attrsOf jsonValue;
        default = { };
        example = lib.literalExpression ''
          {
            scanData = "https://app.notion.com/p/…";
            devTracker = null;
          }
        '';
        description = ''
          profile の値を、このマシンだけ差し替える。キーは profiles.toml と同じ
          (workspace.id / defaultParent / scanData / devTracker.hub など)。
          入れ子は profile の値へ重ね、同じキーはこちらが勝ち、null はそのキーを消す。

          キーの綴りはここでは検査しない (キーの形は claude-skills が持つ)。
          skill が使うときに resolver が知らないキーとして止める。
        '';
      };
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
        default = null;
        example = "polle";
        description = ''
          ホスト側 Windows のユーザー名。`/mnt/c/Users/<名前>/...` の組み立てに使う。
          `wsl.onePassword.enable = true` のときだけ必要 (未設定なら評価時に止まる)。

          Linux 側のユーザー名 (home.username) とは別物なので、マシンごとに
          hosts/default.nix で指定する。値は WSL 上で次を実行すると判る:

              pwsh.exe -NoProfile -Command '$env:USERNAME'

          Nix の評価は純粋なのでこのコマンドを評価時に実行して自動取得すること
          はできない (getEnv や --impure は nix flake check を壊す)。
        '';
      };
    };
  };
}
