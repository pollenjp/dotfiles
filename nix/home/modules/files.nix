# 静的な設定ファイルの配置。
#
# ここで配置するのは「Nix 側で書き換えず、そのまま置くだけ」のファイル。
# 実体は nix/files/ にある (レガシーツリーからの複製)。
#
# ネイティブモジュール (programs.tmux / programs.neovim / programs.zellij) を
# あえて使っていない理由は ADR の「対象外にしたもの」を参照。
{ config, lib, ... }:

{
  home.file = {
    ".screenrc".source = ../../files/screenrc;

    # tmux 本体の設定
    ".tmux.conf".source = ../../files/tmux/home.tmux.conf;

    # vim / neovim で共有する設定断片。
    # 複製元は旧経路の vim_common/ (ADR 013 で削除) で、参照元は ~/dotfiles/vim_common/... を
    # 見ていたが、store 管理では成立しないので ~/.vim/ 配下に置き直している。
    ".vimrc".source = ../../files/vim/vimrc;
    ".vim/common.vim".source = ../../files/vim/common.vim;
    ".vim/clipboard.vim".source = ../../files/vim/clipboard.vim;
  };

  xdg.configFile = {
    # Windows にも同じファイルを win/manifest.toml (base = "nix") で %USERPROFILE%\.config\starship.toml に配る
    # (win/README.md の「starship」。Windows で使えない custom module は os = 'unix' で外す)
    "starship.toml".source = ../../files/starship.toml;
    "zellij/config.kdl".source = ../../files/zellij/config.kdl;

    # init.vim は ~/.vim/common.vim を source する (複製時に書き換え済み)
    "nvim/init.vim".source = ../../files/nvim/init.vim;

    # tss() から `tmux -f` で指定される設定。
    # 元は ~/dotfiles/tmux/home.tmux.conf を source-file していたが
    # ~/.tmux.conf を見るように書き換えてある。
    # これを参照する tss() 自体は Stage 5 (shell) で移行する。
    "tmux/interactive_shell.tmux.conf".source = ../../files/tmux/interactive_shell.tmux.conf;
  }
  # herdr を入れるホスト (dotfiles.herdr.enable。既定はグループ all だけ on) だけに置く
  // lib.optionalAttrs config.dotfiles.herdr.enable {
    # herdr。zellij / tmux と指の動きを揃えたキーバインドを入れてある。
    #
    # herdr は設定画面 (prefix+s) の一部トグルを config.toml へ**書き戻す**
    # (theme / ui.sound / ui.toast.delivery / experimental.pane_history など)。
    # store 管理の read-only な symlink なのでそれらは永続化されず、herdr 側は
    # 5 秒ほど診断メッセージを出して黙って続行する。恒久的に変えたいものは
    # files/herdr/config.toml を編集して switch すること。
    #
    # 初回のオンボーディング完了時の書き込みだけは、設定ファイル側に
    # `onboarding = false` を先に書いて避けている。
    "herdr/config.toml".source = ../../files/herdr/config.toml;
  };
}
