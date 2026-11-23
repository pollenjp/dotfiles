# bash / fish のどちらからも使う、シェル非依存の設定。
#
# 複製元: shell/000_constant.sh / shell/050_common.sh / shell/260_env_vars.sh
#         (および .fish/ 側の同名ファイル)
{ config, lib, ... }:

{
  home.sessionVariables = {
    SUDO_EDITOR = "vim";
    BASE_PATH_TO_WORK = "${config.home.homeDirectory}/workdir";
    BASE_PATH_TO_GITHUB_COM = "${config.home.homeDirectory}/workdir/github.com";
  };

  # 複製元: 050_common の PATH 前置
  # (bash 版は case 文での重複チェック、fish 版は fish_add_path --prepend)
  #
  # ~/.cargo/bin は、claude-skills の clone を持つホスト (dotfiles.claude.privateSkills.enable) だけ前に足す。そこへ
  # bootstrap-pjp.sh が cargo install で shim の pjp を入れ、bootstrap-mise.sh が mise の rust で rustup (cargo・rustc の
  # proxy) を入れる。対話の bash は ~/.cargo/env (bash.nix の initExtra) でも足すが、~/.bashrc は対話でないと先頭で返るので、
  # login のシェル (hc の core が読む login の環境。下の mise の shim の節) には入らなかった。
  home.sessionPath = [
    "$HOME/bin"
    "$HOME/.local/bin"
  ]
  ++ lib.optional config.dotfiles.claude.privateSkills.enable "$HOME/.cargo/bin";

  # mise の shim (~/.local/share/mise/shims) を、herdr-core を入れるホスト (dotfiles.herdrCore.enable) の login の環境の
  # PATH の最後に足す。
  #
  # hc 0.1.21 は、SSH で立った Linux の core に、アカウントの shell の非対話の login 環境を 1 回読ませ、hc の子 (端末と hc exec の
  # コマンド) をその env で起こす (hc --skill の「A new Linux core started over SSH loads the account shell's non-interactive login
  # environment once」)。--via の machine は、--via のコマンドが login のシェルなら同じになる (Windows の hc が
  # wsl.exe -d example-wsl --cd ~ -e bash -lc でつなぐ example-wsl の形。hc の手引きの例の `-e sh -c` で足した machine は login の環境を読まない)。
  # 下の mise activate は対話のシェルだけで効く (home-manager は ~/.bashrc の対話の部分と config.fish の is-interactive に置く) ので、
  # mise で入れる claude (bootstrap-mise.sh) が hc の子から名前で引けなかった。shim なら、版を上げても dir が変わらず、cwd の
  # mise.toml の版も選ぶ。
  #
  # 前ではなく最後に足すのは、project で mise に入れた道具の shim が、Nix の同じ名前の道具を隠さないため (mise の shim は、
  # cwd に版の無い道具だと「No version is set for shim」で落ち、PATH の後ろへは落ちない)。対話のシェルでは mise activate が
  # install の場所を前に足すので、今までどおり mise の版が先に来る。
  #
  # sessionPath ではなく sessionVariablesExtra に書くのは、sessionPath が前に足す形しか持たないため。hm-session-vars.sh の
  # 最後に置かれ、fish には home-manager が babelfish で写す (tests/login-path.nix が bash と fish で読んで確かめる)。
  home.sessionVariablesExtra = lib.mkIf config.dotfiles.herdrCore.enable ''
    export PATH="$PATH''${PATH:+:}''${MISE_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
  '';

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
