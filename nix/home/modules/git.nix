# git の設定。
#
# 複製元: .gitconfig / .gitconfig.pollenjp-sub.github.com / .gitignore_global
#
# ここはファイル配置ではなく programs.git を採用している。
# 目的は .gitconfig:11-17 の 1Password op-ssh-sign のパスで、
# 従来は WSL 用と Windows 用がコメントアウトで並んでおり手で切り替える運用だった
# (切り替えたまま誤ってコミットする事故の温床)。
# Windows を対象外にしたので、これをマシンごとの指定による分岐に置き換えられる。
#
# 署名まわりは dotfiles.wsl.onePassword.enable で丸ごと切り替わる。
# 1Password の無いマシンに commit.gpgSign だけが残ると、署名鍵が見つからず
# git commit そのものが失敗するため、片方だけを残さない。
#
# NOTE: home-manager 26.11 で programs.git のオプションが改名された。
#       userName / userEmail / aliases / extraConfig は programs.git.settings
#       配下へ統合されている。旧名でも動くが warnings が出るので新名を使う。
{ config, lib, ... }:

let
  wsl = config.dotfiles.wsl;

  # 署名を 1Password 経由にするか。マシンごとに hosts/default.nix で選ぶ。
  # false のマシンでは署名関連の設定を一切書き出さない (下の signing / gpg 参照)。
  #
  # 入れ子の親も見ているのは、wsl.enable = false のまま onePassword.enable だけを
  # true にした登録を「有効」と誤認しないため (その組み合わせは下の assertion で止まる)。
  useOnePassword = wsl.enable && wsl.onePassword.enable;

  # 1Password の署名プログラム。Windows 側の実体を呼ぶので、パスにホスト側の
  # Windows ユーザー名が要る。useOnePassword が false のときは参照されない
  # (mkIf の中身は条件が false なら評価されないので null 補間にならない)。
  opSshSignPath = "/mnt/c/Users/${wsl.onePassword.windowsUserName}/AppData/Local/Microsoft/WindowsApps/op-ssh-sign-wsl.exe";
in

{
  # 階層で表現しきれない「親が false なのに子が true」を評価時に止める。
  assertions = [
    {
      assertion = wsl.onePassword.enable -> wsl.enable;
      message = ''
        dotfiles.wsl.onePassword.enable が true ですが dotfiles.wsl.enable が false です。
        1Password 連携はホスト側 Windows の op-ssh-sign-wsl.exe を呼ぶ WSL 専用の設定です。
      '';
    }
    # windowsUserName を書き忘れると op-ssh-sign が黙って無効のまま
    # commit.gpgSign だけが残り、「署名しようとするが署名できない」状態になる。
    {
      assertion = wsl.onePassword.enable -> wsl.onePassword.windowsUserName != null;
      message = ''
        dotfiles.wsl.onePassword.enable が true ですが windowsUserName が未設定です。
        Windows 側の op-ssh-sign-wsl.exe のパスを組み立てられません。
        hosts/default.nix の wsl.onePassword.windowsUserName を指定するか、
        1Password を使わないマシンなら wsl.onePassword.enable を外してください。
      '';
    }
  ];

  # git-delta。pager / interactive.diffFilter / delta.* を設定し、
  # delta 本体も home.packages に入れてくれる。
  # .gitconfig が pager = delta を指定しているのに git-delta が
  # どの管理下にも無かった問題がこれで解消する。
  #
  # NOTE: programs.git.delta 経由の指定は非推奨
  #       ("automatic enablement is deprecated")。programs.delta 側で明示する。
  programs.delta = {
    enable = true;
    enableGitIntegration = true;
    options = {
      navigate = true;
    };
  };

  programs.git = {
    enable = true;

    # 署名の設定は 1Password を使うマシンにだけ書き出す。
    # 1Password の無いマシンに signByDefault だけ残すと、署名鍵が見つからず
    # commit そのものが失敗する。「署名しない」も正当な構成として扱う。
    signing = lib.mkIf useOnePassword {
      format = "ssh";
      signByDefault = true;
      # 鍵は defaultKeyCommand (下の settings) が ssh-agent から解決するので
      # 固定値は持たせない。
      key = null;
      # 1Password の署名プログラム。パス中の Windows ユーザー名は
      # マシンごとに異なるので hosts/default.nix から渡す。
      signer = opSshSignPath;
    };

    # [filter "lfs"] の 4 項目を生成し git-lfs も入れる
    lfs.enable = true;

    # 複製元: .gitignore_global (main.bash は ~/.config/git/ignore へ symlink していた)
    #
    # NOTE: .envrc を無視している。将来 direnv を導入する場合は、
    #       リポジトリ側の .gitignore に "!.envrc" を書かないと Git から見えず、
    #       flake からも見えなくなる。
    ignores = [
      ".DS_Store"
      ".env"
      ".env.*"
      "!.env.*.txt"
      ".envrc"
      ".python-version"
      ".ruby-version"
      ".secrets/"
      "*.code-workspace"
      ".tmp"
      "node_modules/"
      ".vscode/"
      ".claude/settings.local.json"
      # used by like asdf
      ".tool-version"
    ];

    # 複製元: .gitconfig.pollenjp-sub.github.com
    # contents を使うと include 先のファイルも home-manager が生成するので、
    # 別途 files/ に置く必要がない。
    includes = [
      {
        condition = "gitdir:~/workdir/github.com/pollenjp-sub";
        contents.user = {
          email = "polleninjp+github_sub@gmail.com";
          name = "pollenjp-sub";
        };
      }
    ];

    settings = {
      user = {
        name = "pollenjp";
        email = "polleninjp@gmail.com";
      };

      alias = {
        co = "checkout";
        br = "branch";
        ci = "commit";
        st = "status";
        w = "switch";
        push-f = "push --force-with-lease";
      };

      core = {
        editor = "vim";
        quotepath = false;
        autocrlf = false;
      };
      pager.branch = false;
      push.default = "simple";
      init.defaultBranch = "main";
      merge.conflictstyle = "diff3";
      diff.colorMoved = "default";
      pull.rebase = false;

      # [gpg "ssh"] — HM に対応オプションが無いので直接書く。
      # 1Password の ssh-agent が持つ鍵から "Signing" を含むものを署名鍵として選ぶ。
      # 鍵名で引く前提なので 1Password 以外では当たらない。上の signing と揃えて、
      # 1Password を使うマシンにだけ書き出す (セクションごと消す)。
      gpg = lib.mkIf useOnePassword {
        ssh.defaultKeyCommand = "sh -c 'echo key::$(ssh-add -L | grep \"Signing\" | awk NR=1)'";
      };
    };
  };
}
