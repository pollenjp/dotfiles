# herdr-core (hc) を Linux のホストに入れる (dotfiles.herdrCore.enable。既定は Linux なら true)。
#
# herdr-app が SSH でつなぐ machine は、その machine の herdr-core が terminal を持つ。手元の core は SSH で remote の
# `herdr-core connect` を起動し、remote は非対話の sh で `p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core` を
# 探す (herdr-core の machines.rs)。無いか古いと、herdr-app・`hc machine add --install`・`hc machine update` が
# ~/.local/bin/herdr-core に写す (hc が無ければ hc の symlink も)。
#
# - 版は Windows の herdr-core と同じ (nix/pkgs/herdr-core/releases.json)。同じ版なら写し直しを聞かれずにつながる
# - home.packages に入れる (対話のシェルの herdr-core と hc)
# - ~/.local/bin/herdr-core と hc も、同じ binary へのリンクにする。非対話の SSH の PATH に nix の profile が入らない形のホスト
#   (single-user の Nix は ~/.profile にしか足さず、home-manager の ~/.bashrc は先頭で非対話を返す) でも、remote の探し先の
#   2 つ目で見つかるように。multi-user の Nix の Ubuntu (この形の WSL) は、installer が /etc/bash.bashrc の先頭に足した行を
#   SSH の bash が読むので、1 つ目 (command -v) で profile のものが見つかる
# - 前に `hc machine add --install` などで写した ~/.local/bin/herdr-core・hc は、リンクに置き換える (force)。古い写しが残ると、
#   PATH で ~/.local/bin が nix の profile より先に来て (home.sessionPath)、対話の hc が古い版になる
# - store の core は `hc update` が「nix のもの」として断る (実行ファイルの実体が /nix/store/ の下)。dotfiles が入れたホストへは
#   `hc machine update` を打たない (~/.local/bin/herdr-core を落とした binary に置き換え、次の switch でリンクに戻る)。版は
#   releases.json を上げる PR で、Windows と一緒に上げる
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.herdrCore;
  herdrCore = pkgs.callPackage ../../pkgs/herdr-core { };
  bin = "${herdrCore}/bin/herdr-core";
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux;
        message = "dotfiles.herdrCore.enable は Linux のホストだけ (herdr-core の公式の Linux 版を入れる。macOS は herdr-app が入れる)";
      }
    ];

    home.packages = [ herdrCore ];

    home.file.".local/bin/herdr-core" = {
      source = bin;
      force = true;
    };
    home.file.".local/bin/hc" = {
      source = bin;
      force = true;
    };
  };
}
