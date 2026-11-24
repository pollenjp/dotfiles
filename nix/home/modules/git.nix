# git の設定。
#
# 複製元: .gitconfig / .gitconfig.pollenjp-sub.github.com / .gitignore_global
#
# どの OS でも同じにする値 (名前とメール・pollenjp-sub の名前とメール・alias・core など・ignore) は、隣の git.toml に書く。
# Windows の runner の git-config の手順も同じ git.toml を読み、Windows の %USERPROFILE%\.config\git\config・ignore に書く
# (dotfiles-private の docs/adr/066_win_git_config_*)。ここに残すのは OS で違うもの (1Password の署名・delta・lfs・
# includeIf の条件) だけ。
#
# ここはファイル配置ではなく programs.git を採用している。
# 目的は .gitconfig:11-17 の 1Password op-ssh-sign のパスで、
# 従来は WSL 用と Windows 用がコメントアウトで並んでおり手で切り替える運用だった
# (切り替えたまま誤ってコミットする事故の温床)。
# Windows を対象外にしたので、これをマシンごとの指定による分岐に置き換えられる。
#
# 署名まわりは dotfiles.onePassword.enable で丸ごと切り替わる。
# 1Password の無いマシンに commit.gpgSign だけが残ると、署名鍵が見つからず
# git commit そのものが失敗するため、片方だけを残さない。
#
# 署名のプログラムは WSL とそれ以外で分かれる (ADR 022)。
#   - WSL: Windows 側の op-ssh-sign-wsl.exe (1Password はホスト側 Windows にいる)
#   - それ以外: home-manager の既定 (openssh の ssh-keygen)。SSH_AUTH_SOCK のエージェントで
#     署名するので、手元では 1Password、ssh 先では転送されてきたエージェントの鍵で署名する。
#     1Password の op-ssh-sign は SSH_TTY を見て手元の 1Password を選ぶので、herdr の固定名
#     (~/.ssh/agent.sock、ADR 008) に従わない。パスも NixOS だと system 側の固有の場所になる
#
# NOTE: home-manager 26.11 で programs.git のオプションが改名された。
#       userName / userEmail / aliases / extraConfig は programs.git.settings
#       配下へ統合されている。旧名でも動くが warnings が出るので新名を使う。
{ config, lib, ... }:

let
  wsl = config.dotfiles.wsl;

  # 署名を 1Password 経由にするか。マシンごとに hosts/default.nix で選ぶ。
  # false のマシンでは署名関連の設定を一切書き出さない (下の signing / gpg 参照)。
  useOnePassword = config.dotfiles.onePassword.enable;

  # WSL では、署名をホスト側 Windows の op-ssh-sign-wsl.exe に任せる。
  useWindowsSigner = wsl.enable && useOnePassword;

  # 1Password の署名プログラム。Windows 側の実体を呼ぶので、パスにホスト側の
  # Windows ユーザー名が要る。useWindowsSigner が false のときは参照されない
  # (mkIf の中身は条件が false なら評価されないので null 補間にならない)。
  opSshSignPath = "/mnt/c/Users/${wsl.onePassword.windowsUserName}/AppData/Local/Microsoft/WindowsApps/op-ssh-sign-wsl.exe";

  # git の名前とメールを個人のアカウント (pollenjp・pollenjp-sub) にするか (既定は設定グループの ③ 個人の道具)。
  # false のホスト (自社・客先) には名前もメールも書かない。そのホストで使うものをホストの modules に
  # programs.git.settings.user で書く (書かなければ git が commit の前に止まる。個人の名前で commit してしまわない)。
  useIdentity = config.dotfiles.git.identity.enable;

  # どの OS でも同じにする値 (Windows の runner も読む)。書き方は git.toml の冒頭
  shared = lib.importTOML ./git.toml;

  # git.toml の [settings] に書かない節 (名前とメールは [identity]・useIdentity で、署名は useOnePassword で、include は
  # includes で切り替えるので、[settings] にあると切り替えの外で書き出される)
  reservedSections = builtins.filter (s: shared.settings ? ${s}) [
    "user"
    "gpg"
    "include"
    "includeIf"
  ];
in

{
  assertions = [
    # windowsUserName を書き忘れると op-ssh-sign が黙って無効のまま
    # commit.gpgSign だけが残り、「署名しようとするが署名できない」状態になる。
    {
      assertion = useWindowsSigner -> wsl.onePassword.windowsUserName != null;
      message = ''
        WSL で dotfiles.onePassword.enable が true ですが windowsUserName が未設定です。
        Windows 側の op-ssh-sign-wsl.exe のパスを組み立てられません。
        hosts/default.nix の wsl.windowsUserName を指定するか、
        1Password を使わないマシンなら onePassword.enable を外してください。
      '';
    }
    {
      assertion = reservedSections == [ ];
      message = ''
        home/modules/git.toml の [settings] に ${lib.concatStringsSep "・" reservedSections} があります。
        名前とメールは [identity] に書きます (署名と include は git.nix が持つ)。
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
      # WSL は 1Password の署名プログラム。パス中の Windows ユーザー名は
      # マシンごとに異なるので hosts/default.nix から渡す。
      # それ以外は書かず、home-manager の既定 (openssh の ssh-keygen) に任せる。
      signer = lib.mkIf useWindowsSigner opSshSignPath;
    };

    # [filter "lfs"] の 4 項目を生成し git-lfs も入れる
    lfs.enable = true;

    # ~/.config/git/ignore。中身と、.envrc を無視しないわけは git.toml の ignores
    # (main.bash は .gitignore_global を ~/.config/git/ignore へ symlink していた)。
    # .direnv/ (nix-direnv の cache と GC root) は modules/direnv.nix の enableGitIntegration が足す。
    inherit (shared) ignores;

    # ghq の owner ごとの名前とメール (git.toml の [[identity.owners]]。複製元: .gitconfig.pollenjp-sub.github.com)。
    # contents を使うと include 先のファイルも home-manager が生成するので、
    # 別途 files/ に置く必要がない。個人のアカウントの名前とメールなので、上の useIdentity のホストだけ。
    #
    # NOTE: 条件は旧い .gitconfig (ghq の root が ~/workdir だったころ) の写しのまま変えていない。末尾に / が無いので、
    #       git はこのディレクトリの下の repo に当てない (末尾が / のときだけ ** を足す)。Windows の runner は ghq の root
    #       (%USERPROFILE%\ghq) の下に末尾の / を付けて書く (dotfiles-private の docs/adr/066_win_git_config_*)。
    includes = lib.optionals useIdentity (
      map (o: {
        condition = "gitdir:~/workdir/github.com/${o.owner}";
        contents.user = {
          inherit (o) email name;
        };
      }) shared.identity.owners
    );

    # どのホストにも書く設定は git.toml の [settings]。ここで足すのは OS やホストで切り替えるものだけ
    settings = shared.settings // {
      user = lib.mkIf useIdentity {
        inherit (shared.identity) name email;
      };

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
