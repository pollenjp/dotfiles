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
    fish

    # starship は programs.starship (modules/starship.nix) が入れるので
    # ここには書かない。
    # delta / git-lfs も同様に programs.git (modules/git.nix) が入れる。
    # .gitconfig が pager = delta を要求しているのに git-delta が
    # どの管理下にも無かった問題は、そちらで解消している。

    ##########################################
    # これまでどの管理下にも無かった依存
    ##########################################
    tmux
    vim
    neovim

    # 言語ランタイム (node/go) の管理は引き続き mise が担うので、
    # mise 自体は Nix で入れる
    mise
  ];
}
