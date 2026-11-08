# WSL で 1Password を使うマシンの PATH に、理由 (--reason) が必須の op と、その記録を見る pjp-op-log を入れる (pkgs/pjp-op)。
#
# WSL から直に op.exe を打つと、1Password の承認がどの pane にも共通の wsl.exe に付き、1 回の許可が後の呼び出しとほかの pane に
# 効く。op は呼び出しごとに powershell.exe を挟んで承認を閉じ、承認の画面と一緒に呼び手と理由の窓を出して記録する。
# 動きは pkgs/pjp-op/op.sh の先頭のコメント、使い方と守る決まりは nix/README.md「WSL の op を理由つきで呼ぶ」。
#
# 入る条件は ssh.nix の ssh・ssh-add の wrapper と同じ (dotfiles.wsl.enable と dotfiles.onePassword.enable が両方 true)。
# option は持たない。Claude の hook (files/claude/hooks/op-reason-guard.sh) はどのマシンにも置くので (claude.nix)、
# この op があるかを ~/.local/state/dotfiles/claude-op-reason.json ({"enable": <bool>}) で知らせる。false でも必ず書く。
{
  config,
  lib,
  pkgs,
  ...
}:

let
  enable = config.dotfiles.wsl.enable && config.dotfiles.onePassword.enable;
in
{
  home.packages = lib.optional enable (pkgs.callPackage ../../pkgs/pjp-op { });

  home.file.".local/state/dotfiles/claude-op-reason.json".text =
    builtins.toJSON { inherit enable; } + "\n";
}
