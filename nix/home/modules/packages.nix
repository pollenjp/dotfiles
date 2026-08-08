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
    starship
    watchexec
    zellij
    fish

    ##########################################
    # これまでどの管理下にも無かった依存
    ##########################################
    # .gitconfig の `pager = delta` が要求しているが未インストールだった
    delta

    tmux
    vim
    neovim

    # 言語ランタイム (node/go) の管理は引き続き mise が担うので、
    # mise 自体は Nix で入れる
    mise
  ];
}
