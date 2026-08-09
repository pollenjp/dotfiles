# git の設定。
#
# 複製元: .gitconfig / .gitconfig.pollenjp-sub.github.com / .gitignore_global
#
# ここはファイル配置ではなく programs.git を採用している。
# 目的は .gitconfig:11-17 の 1Password op-ssh-sign のパスで、
# 従来は WSL 用と Windows 用がコメントアウトで並んでおり手で切り替える運用だった
# (切り替えたまま誤ってコミットする事故の温床)。
# Windows を対象外にしたので、これを isWSL による自動分岐に置き換えられる。
#
# NOTE: home-manager 26.11 で programs.git のオプションが改名された。
#       userName / userEmail / aliases / extraConfig は programs.git.settings
#       配下へ統合されている。旧名でも動くが warnings が出るので新名を使う。
{ config, lib, ... }:

let
  cfg = config.dotfiles;

  # 1Password の署名プログラム。
  # WSL であることに加え、ホスト側 Windows のユーザー名が判っている場合にのみ設定する。
  # windowsUserName が null のマシンでは signer を設定せず、
  # home-manager 既定の ssh-keygen で署名する (これも正当な構成)。
  useOpSshSign = cfg.isWSL && cfg.windowsUserName != null;
  opSshSignPath = "/mnt/c/Users/${cfg.windowsUserName}/AppData/Local/Microsoft/WindowsApps/op-ssh-sign-wsl.exe";
in

{
  # WSL なのに windowsUserName が未設定だと 1Password 連携が黙って無効になり、
  # 「署名はできているが 1Password を経由していない」状態に気付きにくい。
  warnings = lib.optional (cfg.isWSL && cfg.windowsUserName == null) ''
    dotfiles.isWSL = true ですが dotfiles.windowsUserName が未設定です。
    1Password の op-ssh-sign は設定されず、git の署名は通常の ssh-keygen で行われます。
    1Password を使う場合は hosts/default.nix で windowsUserName を指定してください。
  '';

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

    signing = {
      format = "ssh";
      signByDefault = true;
      # 鍵は defaultKeyCommand (下の settings) が ssh-agent から解決するので
      # 固定値は持たせない。
      key = null;
      # 1Password の署名プログラム。パス中の Windows ユーザー名は
      # マシンごとに異なるので hosts/default.nix から渡す。
      signer = lib.mkIf useOpSshSign opSshSignPath;
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
      # ssh-agent が持つ鍵から "Signing" を含むものを署名鍵として選ぶ。
      gpg.ssh.defaultKeyCommand = "sh -c 'echo key::$(ssh-add -L | grep \"Signing\" | awk NR=1)'";
    };
  };
}
