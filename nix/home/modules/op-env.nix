# 1Password を使うマシン (dotfiles.onePassword.enable) の PATH に、.env の op:// の参照を 1 回の op で解いて program を起こす
# pjp-op-env (pkgs/pjp-op-env) を入れる。WSL では op が pjp-op の wrapper (home/modules/op-reason.nix) になり、pjp-op-env は
# ~/.local/state/dotfiles/claude-op-reason.json を見て --reason を付ける。WSL でないマシンでは素の op (1Password CLI。NixOS では
# system の側で入れる) を使う。
#
# 動きは pkgs/pjp-op-env/pjp-op-env.sh の先頭のコメント、使い方と安全である理由は nix/README.md「シークレットを .env の参照から
# 渡す (pjp-op-env)」。Claude に使い方を決める skill は files/claude/skills/pjp-secrets。
{
  config,
  lib,
  pkgs,
  ...
}:

{
  home.packages = lib.optional config.dotfiles.onePassword.enable (
    pkgs.callPackage ../../pkgs/pjp-op-env { }
  );
}
