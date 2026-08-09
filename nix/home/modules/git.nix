# git の設定。
#
# 複製元: .gitconfig / .gitconfig.pollenjp-sub.github.com / .gitignore_global
#
# ここはファイル配置ではなく programs.git を採用している。
# 目的は .gitconfig:11-17 の 1Password op-ssh-sign のパスで、
# 従来は WSL 用と Windows 用がコメントアウトで並んでおり手で切り替える運用だった
# (切り替えたまま誤ってコミットする事故の温床)。
# Windows を対象外にしたので、これを isWSL による自動分岐に置き換えられる。
{ config, lib, ... }:

{
  programs.git = {
    enable = true;

    userName = "pollenjp";
    userEmail = "polleninjp@gmail.com";

    signing = {
      format = "ssh";
      signByDefault = true;
      # 鍵は defaultKeyCommand (下の extraConfig) が ssh-agent から解決するので
      # 固定値は持たせない。
      key = null;
      # 1Password の署名プログラム。WSL のときだけ設定する。
      signer = lib.mkIf config.dotfiles.isWSL "/mnt/c/Users/polle/AppData/Local/Microsoft/WindowsApps/op-ssh-sign-wsl.exe";
    };

    # core.pager / interactive.diffFilter / delta.* をまとめて設定し、
    # delta 本体も home.packages に入れてくれる。
    # .gitconfig が pager = delta を指定しているのに git-delta が
    # どの管理下にも無かった問題がこれで解消する。
    delta = {
      enable = true;
      options = {
        navigate = true;
      };
    };

    # [filter "lfs"] の 4 項目を生成し git-lfs も入れる
    lfs.enable = true;

    aliases = {
      co = "checkout";
      br = "branch";
      ci = "commit";
      st = "status";
      w = "switch";
      push-f = "push --force-with-lease";
    };

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

    extraConfig = {
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
