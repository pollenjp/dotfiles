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
    # GitHub CLI (mise では github-cli)。Claude の git の credential helper
    # (dotfiles.claude.gitViaGh.enable、modules/claude.nix)・下の git gh・pjp-dev-tracker が使う。
    # programs.gh は使わない。~/.config/gh/config.yml を store に置くと gh 自身が
    # 書けなくなり、gitCredentialHelper は自分のターミナルの素の git まで gh に向けるため
    # (gh に向けるのは fetch 系の abbr / alias だけで、それは git gh が受け持つ)。
    gh
    ghq
    jq
    watchexec
    zellij

    # リソースモニタ。btop・htop・bottom (コマンド名は btm) を使い比べる。
    # programs.btop / programs.htop の settings は使わない。どちらも TUI の設定画面で
    # 変えた値を設定ファイルへ書き戻すが、settings を書くとそのファイルが store への
    # 読み取り専用の symlink になり、TUI での変更が残らなくなるため。
    btop
    htop
    bottom
    # htop の l (開いているファイルの一覧) が呼ぶ
    lsof

    # coding agent 向けの multiplexer の herdr は modules/agent-link.nix が入れる (server に session ごとの
    # 固定名の SSH_AUTH_SOCK を渡す実行ファイルで包んだもの。ADR 025)。設定は modules/files.nix ->
    # files/herdr/config.toml

    # PR 全体の差分から変更ファイルを fzf で選び、選んだファイルだけの git diff を出す。
    # 実体は nix/pkgs/pjp-pr-diff/。fish の abbr と bash の alias の gdp で呼ぶ
    (callPackage ../../pkgs/pjp-pr-diff { })

    # GitHub との通信だけを gh の資格情報 (HTTPS) に向けて git を呼ぶ (git gh <コマンド>)。
    # 実体は nix/pkgs/git-gh/。fish の abbr と bash の alias の gfp-gh と、gitViaGh.enable のマシンの
    # fetch 系 (gf・gfp・gpul・gpull・gcl と git_* の関数) と setup の取得 (nix/scripts/ の git_github) が
    # 使う。option によらず入れる
    (callPackage ../../pkgs/git-gh { })

    # 以下は対応する programs.* モジュールが入れるのでここには書かない:
    #   starship -> modules/starship.nix
    #   delta / git-lfs -> modules/git.nix
    #   fish -> modules/fish.nix
    #   mise -> modules/fish.nix (programs.mise)
    #   direnv / nix-direnv -> modules/direnv.nix
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
