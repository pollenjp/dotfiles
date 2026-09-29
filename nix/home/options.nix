# このリポジトリ独自のオプション定義。
#
# 有効な組み合わせが構造に出るよう、WSL 固有の設定は dotfiles.wsl 配下へ入れ子にしている。
#
#   dotfiles.wsl.enable                          WSL か
#   dotfiles.wsl.onePassword.enable              ホスト側 Windows の 1Password を使うか
#   dotfiles.wsl.onePassword.windowsUserName     その 1Password のパスに要る Windows ユーザー名
#   dotfiles.claude.devTracker.enable            Notion Dev Tracker (pjp-dev-tracker) を使うマシンか
#   dotfiles.claude.gitViaGh.enable              Claude の git を gh の資格情報 (HTTPS) で GitHub へ通すか
#
# 親が false なら子は意味を持たない、という関係がそのまま階層になっている。
# 平坦に並べていたときの「どの組み合わせが有効なのか判らない」を避けるため。
{ lib, ... }:

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

    gitViaGh.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = false;
      description = ''
        Claude Code のセッションの git が GitHub と通信するとき、gh の資格情報で
        HTTPS を使うか。false なら今までどおり ssh (WSL では 1Password の agent) を通る。

        true のとき、Claude のセッション (Bash tool) にだけ次の git の設定を env で渡す。
        自分のターミナルの git は変わらない:

        - `url.https://github.com/.insteadOf` に `git@github.com:` と `ssh://git@github.com/`。
          fetch と push の両方で、GitHub の ssh の URL を https に読み替える
        - `credential.https://github.com.helper = !gh auth git-credential`。
          資格情報は gh の token から取る

        ssh は WSL の ssh.exe を通るので、interop が外れると Exec format error で落ち、
        通っても 1Password の承認ダイアログで止まる。gh は HTTPS の API なので
        どちらにも依らない。

        gh は home/modules/packages.nix が入れる。前提は `gh auth login` 済みであること
        (gh が無い・未ログインなら bootstrap が警告し、setup の最後のまとめにも出す)。
        token に workflow scope が無いと、`.github/workflows/` を変える push を
        GitHub が拒否する (`gh auth refresh -h github.com -s workflow` で足す)。

        値は `~/.local/state/dotfiles/claude-env.json` (home/modules/claude.nix) に落ち、
        nix/scripts/bootstrap-claude-env.sh が `~/.claude/settings.json` の env へ写す。
        devTracker.enable と同じく反映は 2 段で、`home-manager switch` だけでは
        settings.json に届かない。`~/dotfiles/setup --update` で揃える。
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
