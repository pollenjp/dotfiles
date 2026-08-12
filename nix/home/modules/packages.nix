# グローバルに使う CLI ツール。
#
# 役割分担:
#   - グローバルな CLI ツール   -> Nix (このファイル)
#   - プロジェクト毎のツール固定 -> mise (mise.toml)
#   - 言語ランタイム (node/go)  -> mise (プロジェクト毎の切替が必要なため)
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    ##########################################
    # mise から移管した CLI ツール
    ##########################################
    # cargo-binstall 経由でソースビルドされていたもの。
    # nixpkgs ではバイナリキャッシュから入るのでビルドが不要になる。
    bat
    eza
    fd # mise では cargo:fd-find
    procs
    ripgrep

    fzf
    ghq
    jq
    watchexec
    zellij

    # coding agent 向けの multiplexer。
    # 設定は modules/files.nix -> files/herdr/config.toml
    herdr

    # 以下は対応する programs.* モジュールが入れるのでここには書かない:
    #   starship -> modules/starship.nix
    #   delta / git-lfs -> modules/git.nix
    #   fish -> modules/fish.nix
    #   mise -> modules/fish.nix (programs.mise)
    #
    # .gitconfig が pager = delta を要求しているのに git-delta が
    # どの管理下にも無かった問題は modules/git.nix で解消している。

    ##########################################
    # これまでどの管理下にも無かった依存
    ##########################################
    tmux
    vim
    neovim
  ];
}
