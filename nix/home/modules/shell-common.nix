# bash / fish のどちらからも使う、シェル非依存の設定。
#
# 複製元: shell/000_constant.sh / shell/050_common.sh / shell/260_env_vars.sh
#         (および .fish/ 側の同名ファイル)
{ config, ... }:

{
  home.sessionVariables = {
    SUDO_EDITOR = "vim";
    BASE_PATH_TO_WORK = "${config.home.homeDirectory}/workdir";
    BASE_PATH_TO_GITHUB_COM = "${config.home.homeDirectory}/workdir/github.com";
  };

  # 複製元: 050_common の PATH 前置
  # (bash 版は case 文での重複チェック、fish 版は fish_add_path --prepend)
  home.sessionPath = [
    "$HOME/bin"
    "$HOME/.local/bin"
  ];

  # 複製元: .bash/03_mise.sh の `mise activate bash` と
  #         .fish/060_mise.fish の `mise activate fish`
  #
  # NOTE: globalConfig を設定しないので ~/.config/mise/config.toml は
  #       home-manager が生成しない。言語ランタイムの管理は mise 自身に任せる。
  #
  # NOTE: .bash/03_mise.sh は起動のたびに
  #       ~/.local/share/bash-completion/completions/mise を書き出していたが、
  #       補完は mise パッケージ同梱のものが使われるので不要になった。
  programs.mise = {
    enable = true;
    enableBashIntegration = true;
    enableFishIntegration = true;
  };
}
