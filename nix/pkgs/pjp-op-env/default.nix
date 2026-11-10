# .env の op:// の参照を 1 回の op で解き、値を環境変数に入れて program を起こす pjp-op-env。動きは pjp-op-env.sh の先頭の
# コメント、使い方は nix/README.md「シークレットを .env の参照から渡す (pjp-op-env)」。
#
# script は bash の組み込みだけで書いてあり、外のコマンドを起こさない (値を argv に載せないため)。runtimeInputs を持たないので、
# writeShellApplication は PATH を足さず、起こす program の PATH は呼び手のまま。op は呼ぶ側の PATH から引く (WSL では
# pkgs/pjp-op の wrapper、ほかのマシンでは 1Password CLI)。home/modules/op-env.nix が dotfiles.onePassword.enable のマシンの
# PATH に入れる。
#
# errexit を付けずに書いてある (落ちうるコマンドは自分で受ける) ので、bashOptions から外す。
{ writeShellApplication }:

writeShellApplication {
  name = "pjp-op-env";
  bashOptions = [
    "nounset"
    "pipefail"
  ];
  text = builtins.readFile ./pjp-op-env.sh;
}
